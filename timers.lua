-- Daseeki Nexus — timers.lua  (WAVE N2b: world-buff & Felwood-node engine)
--
-- The timer engine: five trust-ranked detector classes, NWB/DBM ingest,
-- cooldown derivation with false-positive rejection, capped pop logs,
-- weekly reset integration, a CD-warning scheduler, Felwood songflower/
-- tuber node timers with pick detection, guild-broadcaster election, and
-- login data requests. Builds only on the N1 public surface (Core/Store/
-- Protocol) and hands network transport to the mesh layer through a
-- soft-guarded handoff namespace (ns.Mesh / ns.Timers).
--
-- Clean-room: every constant, table, and algorithm here is Daseeki's own.
-- NWB (NovaWorldBuffs) and D5 (DBM) are OTHER addons' public message
-- identifiers; we DECODE them receive-only for interoperability and never
-- transmit on their prefixes. No third-party source or private identifier
-- appears in this file.
--
-- API discipline (Interface 11509): C_Timer, C_Map, C_ChatInfo, and the
-- CombatLog / chat events only; every game call is guarded so this file
-- also loads under a bare Lua VM for the self-test harness.

local ADDON, ns = ...

local Timers = {}
ns.Timers = Timers

----------------------------------------------------------------------
-- Time helpers (server epoch via Store; frame clock via GetTime)
----------------------------------------------------------------------

local function now()
    if ns and ns.Store and ns.Store.Now then return ns.Store.Now() end
    if GetServerTime then return GetServerTime() end
    return (os and os.time and os.time()) or 0
end
Timers._now = now   -- overridable in self-tests for deterministic clocks

local function frameClock()
    return (GetTime and GetTime()) or 0
end

----------------------------------------------------------------------
-- Buff model
--
-- Timer-tracked buff keys. rend + ony(H/A) are the CD-logged buffs that
-- match the store's rendLog/onyLogH/onyLogA. nef(H/A) + zg are detected
-- and announced and carry in-memory state, but only the three store-backed
-- keys persist capped pop logs (spec §2b). battleShout ("Fallen Hero") is
-- carried as a callback key for the UI/alert matrix only — no server CD.
----------------------------------------------------------------------

Timers.BUFF_KEYS = { "rend", "onyH", "onyA", "nefH", "nefA", "zg" }

-- Raw cooldowns (seconds). Rend 3h, Ony 6h per faction; nef mirrors ony;
-- zg (Spirit of Zandalar) cycles on the shorter 3h window.
local CD = {
    rend = 3 * 3600,
    onyH = 6 * 3600,
    onyA = 6 * 3600,
    nefH = 6 * 3600,
    nefA = 6 * 3600,
    zg   = 3 * 3600,
}
Timers.CD = CD

-- +5s display grace: bars linger this long past the raw CD. Excluded from
-- the dedup / false-positive gate (that uses the raw CD), per spec.
local DISPLAY_GRACE = 5
Timers.DISPLAY_GRACE = DISPLAY_GRACE

-- Pull-bar freshness gate. A PULL_DETECTED event raises the HUD pull bar and the
-- "X incoming!" alert ONLY while the underlying pop/kill is recent enough to
-- still be genuinely "incoming". This is the reload-safety gate: after a /reload
-- the in-memory timer state is empty, so the first network re-sync (mesh
-- snapshot / SN / NWB / any Record caller) re-applies HOURS-OLD anchors as if
-- new; without this gate each re-apply raised a false pull bar for a long-past
-- event. DEFAULT_PULL_WINDOW mirrors hud.lua's fallback of the same name (hud
-- owns the display default; we own the fire gate — keep the two in sync).
-- PULL_FRESH_SLACK tolerates minor clock skew / relay lag at the window edge.
local DEFAULT_PULL_WINDOW = 40
Timers.DEFAULT_PULL_WINDOW = DEFAULT_PULL_WINDOW
local PULL_FRESH_SLACK = 5
Timers.PULL_FRESH_SLACK = PULL_FRESH_SLACK

----------------------------------------------------------------------
-- Per-buff, per-yell-stage pull windows  (AUTHORITATIVE CONSTANTS)
--
-- A world-buff drop announces in two yell stages. Stage 1 is the announce/
-- "head turned in" yell and is the ONLY stage that records a pop; stage 2 is
-- the follow-up flourish. The seconds below are the MEASURED yell -> buff-lands
-- delays (behaviour spec §10.7) and they are now authoritative: they are short
-- (6-50s), not the minutes-scale guesses the old PROVISIONAL seeds used.
--
-- `false` means that (buff, stage) raises NO bar at all — stage 2 is a complete
-- no-op for Rend / Onyxia / Nefarian. Zandalar is the documented exception: its
-- stage 2 does carry a real 29s bar (spec §10.7), it just never records a pop.
--
-- Rend's stage-1 entry is the BARRENS landing; a Rend yell actually raises TWO
-- bars (Orgrimmar + Barrens) — see REND_BARS in the yell detector below.
--
-- AUTO-CALIBRATION: the observation machinery (RecordPullObservation /
-- NotePullGain / pullObservations / `/dsn debug pulls`) is DELIBERATELY KEPT so
-- the owner can measure real drift against these constants, but it no longer
-- feeds bar length — the spec constants win. Only an explicit manual override
-- (timerSettings.pullWindows) can still displace a constant.
local PULL_WINDOWS = {
    rend = { [1] = 17,   [2] = false },  -- Barrens landing; see REND_BARS
    onyH = { [1] = 14.5, [2] = false },
    onyA = { [1] = 15,   [2] = false },
    nefH = { [1] = 15,   [2] = false },
    nefA = { [1] = 12,   [2] = false },
    zg   = { [1] = 50.5, [2] = 29    },  -- ZG stage 2 DOES bar (spec §10.7)
}
Timers.PULL_WINDOWS = PULL_WINDOWS

-- Rend stage 1 raises two bars: the Orgrimmar landing and the Barrens landing.
-- A Herald-of-Thrall-sourced yell lands in the Barrens on the SHORT 6s variant.
local REND_BARS = {
    thrall = { { zone = "Orgrimmar", seconds = 6 }, { zone = "Barrens", seconds = 17 } },
    herald = { { zone = "Orgrimmar", seconds = 6 }, { zone = "Barrens", seconds = 6  } },
}
Timers.REND_BARS = REND_BARS

-- Keep the newest N observations per (buffKey, yellNum) pair.
local PULL_OBS_CAP = 10
Timers.PULL_OBS_CAP = PULL_OBS_CAP
-- Sanity bound (seconds) on a plausible announce/yell -> land delay. Anything
-- outside [0, PULL_OBS_MAX] is discarded (bad clock / unrelated late gain) and
-- also bounds how long a pending pull can wait for its buff to land.
local PULL_OBS_MAX = 900
Timers.PULL_OBS_MAX = PULL_OBS_MAX

-- Normalize yell stage to 1 or 2. An UNKNOWN stage normalizes to 1: stage 1 is
-- the announce stage every remote/bulk ingest path actually means, and stage 2
-- is a no-op for most buffs, so defaulting to 2 (the old behaviour) silently
-- swallowed relayed pulls.
local function normYell(yellNum)
    return (yellNum == 2) and 2 or 1
end

-- Median of a numeric list (pure). Even counts average the two middle values.
local function median(list)
    local n = list and #list or 0
    if n == 0 then return nil end
    local copy = {}
    for i = 1, n do copy[i] = list[i] end
    table.sort(copy)
    if n % 2 == 1 then return copy[(n + 1) / 2] end
    return (copy[n / 2] + copy[n / 2 + 1]) / 2
end
Timers._median = median

-- Lazily-created capped observation store (ADDITIVE key on the timers store):
--   timers.pullObservations[buffKey][yellNum] = { observedSeconds, ... }
-- newest last, capped at PULL_OBS_CAP. Created on first write so it appears on
-- existing SavedVariables without a migration; nil when no store is present
-- (bare-VM path before Store loads).
local function pullObsStore(create)
    if not (ns.Store and ns.Store.GetTimers) then return nil end
    local t = ns.Store.GetTimers()
    if not t then return nil end
    if not t.pullObservations and create then t.pullObservations = {} end
    return t.pullObservations
end

-- Read a manual override for (buffKey, yellNum) from settings, or nil. A NUMBER
-- pins both stages; a TABLE {[1]=,[2]=} pins per stage. Only positive values win.
local function pullWindowOverride(buffKey, yellNum)
    local s = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
    local pw = s and s.timerSettings and s.timerSettings.pullWindows
    local ov = pw and pw[buffKey]
    if ov == nil then return nil end
    if type(ov) == "table" then
        local v = tonumber(ov[normYell(yellNum)])
        if v and v > 0 then return v end
        return nil
    end
    local v = tonumber(ov)
    if v and v > 0 then return v end
    return nil
end

-- Effective pull window (seconds) + source label for (buffKey, yellNum).
-- Precedence: manual override > SPEC CONSTANT > global fallback.
-- Returns nil, "none" when the spec says this stage raises no bar at all.
-- (The observed median is NO LONGER in this chain — see the PULL_WINDOWS note:
-- calibration measures drift, it does not set bar length.)
function Timers.EffectivePullWindow(buffKey, yellNum)
    yellNum = normYell(yellNum)
    local override = pullWindowOverride(buffKey, yellNum)
    if override then return override, "override" end
    local spec = PULL_WINDOWS[buffKey]
    if spec then
        local v = spec[yellNum]
        if v == false then return nil, "none" end
        if v then return v, "spec" end
    end
    return DEFAULT_PULL_WINDOW, "fallback"
end

-- The median of observed (yell -> land) delays for a stage, or nil. Reporting
-- only: this is the DRIFT measurement against the spec constant, never the
-- window the bar uses.
function Timers.ObservedPullMedian(buffKey, yellNum)
    local store = pullObsStore(false)
    local list = store and store[buffKey] and store[buffKey][normYell(yellNum)]
    if not (list and #list >= 1) then return nil, 0 end
    return median(list), #list
end

-- Append one observed announce/yell -> land delay (seconds) for (buffKey,
-- yellNum). Capped newest at PULL_OBS_CAP; oldest evicted. Returns true if
-- stored. Sanity-bounded and gated to known pull buffs.
function Timers.RecordPullObservation(buffKey, yellNum, observed)
    if not PULL_WINDOWS[buffKey] then return false end
    yellNum = normYell(yellNum)
    observed = tonumber(observed)
    if not observed or observed < 0 or observed > PULL_OBS_MAX then return false end
    local store = pullObsStore(true)
    if not store then return false end
    store[buffKey] = store[buffKey] or {}
    local list = store[buffKey][yellNum]
    if not list then list = {}; store[buffKey][yellNum] = list end
    list[#list + 1] = observed
    while #list > PULL_OBS_CAP do table.remove(list, 1) end   -- evict oldest
    return true
end

-- Pending pull per buff, seeded when a FRESH local yell raises the pull bar and
-- consumed when the buff actually lands on the player (Timers.NotePullGain).
-- Shape: _pendingPull[buffKey] = { [1] = yellTime, [2] = yellTime } so ONE
-- witnessed drop can calibrate BOTH stages that preceded it.
Timers._pendingPull = {}

local function setPendingPull(buffKey, yellTime, yellNum)
    local t = Timers._pendingPull[buffKey]
    if not t then t = {}; Timers._pendingPull[buffKey] = t end
    t[normYell(yellNum)] = yellTime
end
Timers._setPendingPull = setPendingPull

-- Called when the world buff for buffKey lands on the player. For each pending
-- yell stage still within PULL_OBS_MAX, records observed = landTime - yellTime,
-- then clears ALL pending stages for that buff (the drop happened once). Returns
-- the number of observations recorded (0 when no pull was active for this buff).
function Timers.NotePullGain(buffKey, landTime)
    local t = Timers._pendingPull[buffKey]
    if not t then return 0 end
    landTime = landTime or now()
    local recorded = 0
    for yn = 1, 2 do
        local yt = t[yn]
        if yt then
            local observed = landTime - yt
            if observed >= 0 and observed <= PULL_OBS_MAX then
                if Timers.RecordPullObservation(buffKey, yn, observed) then
                    recorded = recorded + 1
                end
            end
        end
    end
    Timers._pendingPull[buffKey] = nil   -- consume all stages for this buff
    return recorded
end

-- Which buff keys own a persisted store log, and the store log key.
local STORE_LOG_KEY = { rend = "rend", onyH = "onyH", onyA = "onyA" }

-- Buffs that feed the CD-warning scheduler (spec: Rend + Ony only).
local WARNED_BUFFS = { "rend", "onyH", "onyA" }

-- Trust ladder. Higher wins; equal-or-higher upgrades an existing entry.
-- Order (spec, N2 round 2): local > mesh > sn > nwb > dbm. "sn" is the
-- passively-ingested ShadowNetwork broadcast source (snbridge.lua): trusted
-- above NWB/DBM (it is another player's merged, human-confirmed feed) but
-- below our own mesh peers (shared-token, first-party) and local detection.
local TRUST_RANK = { ["local"] = 5, mesh = 4, sn = 3, nwb = 2, dbm = 1 }
Timers.TRUST_RANK = TRUST_RANK

local function trustRank(t) return TRUST_RANK[t or ""] or 0 end

----------------------------------------------------------------------
-- Source freshness
--
-- Last time (server epoch) we ingested timer data from each of the three
-- pull/push sources the UI's refresh controls care about:
--   nexus     = mesh peer snapshot (RequestNexusData reply / broadcaster relay)
--   nwb       = NovaWorldBuffs traffic (passive + our data-request reply)
--   snPassive = ShadowNetwork broadcast, passively decoded (snbridge.lua)
-- Updated on RECEIPT regardless of whether the datum changed state, so the UI
-- can show "heard from X, Ns ago" even when the payload was a dedup no-op.
----------------------------------------------------------------------

Timers._freshness = { nexus = 0, nwb = 0, snPassive = 0 }

local function noteFreshness(source)
    if Timers._freshness[source] ~= nil then
        Timers._freshness[source] = now()
    end
end
Timers._noteFreshness = noteFreshness

----------------------------------------------------------------------
-- Per-buff runtime state
--
-- state[buffKey] = {
--   lastPop    = epoch of the last confirmed buff drop (the ONLY CD anchor),
--   killedAt   = epoch of the last ANNOUNCER DEATH — a 360s respawn, NOT a CD,
--   trust      = trust tag of the anchoring event,
--   who        = reporter label,
--   confirmed  = true once a higher-or-equal-trust source agreed,
-- }
--
-- FIELD RENAME (A3.1): the kill epoch used to live in `lastKilled` and every
-- reader folded it into `max(lastPop, lastKilled)` as a cooldown anchor — which
-- inverted the meaning (killing the Onyxia announcer showed a SIX HOUR cooldown
-- when the truth is "6 minute respawn, then available"). It is now `killedAt`,
-- so anchor arithmetic anywhere — here or in a UI consumer — sees pops only.
-- The wire/snapshot key stays `lastKilled` for peer compatibility. Read kill
-- state through Timers.BuffStatus.
----------------------------------------------------------------------

Timers.state = {}

-- Announcer respawn after a kill (spec §10.2). Not a cooldown.
local ANNOUNCER_RESPAWN = 360
Timers.ANNOUNCER_RESPAWN = ANNOUNCER_RESPAWN

local function stateOf(buffKey)
    local s = Timers.state[buffKey]
    if not s then
        s = { lastPop = 0, killedAt = 0, trust = nil, who = nil, confirmed = false }
        Timers.state[buffKey] = s
    end
    return s
end

-- Faction-resolved key for the buffs that split H/A. `base` is "ony"/"nef".
local function factionKey(base, faction)
    faction = faction or (UnitFactionGroup and UnitFactionGroup("player")) or "Horde"
    local suffix = (faction == "Alliance") and "A" or "H"
    return base .. suffix
end

----------------------------------------------------------------------
-- CD derivation (pure)
--
-- The CD anchor is the last POP and nothing else. An announcer death is a
-- respawn event, not a cooldown start (A3.1) — see Timers.BuffStatus.
----------------------------------------------------------------------

-- Return the effective anchor epoch for a buff's cooldown.
local function anchorEpoch(s)
    return s.lastPop or 0
end

-- Compute {onCD, ready, remaining, nextAt} for a buff at time `t`.
-- Pure helper (no globals) so the self-tests can drive it directly.
function Timers.ComputeCD(buffKey, anchor, t)
    local cd = CD[buffKey]
    if not cd or not anchor or anchor <= 0 then
        return { onCD = false, ready = true, remaining = 0, nextAt = 0 }
    end
    local nextAt = anchor + cd
    local remaining = nextAt - t
    if remaining < 0 then remaining = 0 end
    local onCD = (t < nextAt)
    -- Display grace keeps a bar visible slightly past ready; not a gate.
    return { onCD = onCD, ready = (not onCD), remaining = remaining, nextAt = nextAt }
end

-- Public buff readout (spec §10.2). This — not raw ComputeCD — is the correct
-- source for "what should the UI say about this buff":
--   nodata  : nothing observed
--   killed  : the announcer died and is still respawning (remaining <= 360s)
--   canpop  : off cooldown / respawn elapsed
--   cd      : on cooldown, `remaining` seconds left
-- A kill NEWER than the newest pop wins and models a 360s RESPAWN; once that
-- elapses the buff is immediately can-pop (A3.1). Kills never start a cooldown.
function Timers.BuffStatus(buffKey, t)
    t = t or now()
    local s = Timers.state[buffKey]
    local pop    = (s and s.lastPop) or 0
    local killed = (s and s.killedAt) or 0
    if killed > 0 and killed >= pop then
        local remaining = ANNOUNCER_RESPAWN - (t - killed)
        if remaining > 0 then
            return { state = "killed", remaining = remaining,
                     nextAt = killed + ANNOUNCER_RESPAWN }
        end
        return { state = "canpop", remaining = 0, nextAt = killed + ANNOUNCER_RESPAWN }
    end
    if pop <= 0 then return { state = "nodata", remaining = 0, nextAt = 0 } end
    local info = Timers.ComputeCD(buffKey, pop, t)
    if info.onCD then
        return { state = "cd", remaining = info.remaining, nextAt = info.nextAt }
    end
    return { state = "canpop", remaining = 0, nextAt = info.nextAt }
end

-- False-positive gate (pure). A fresh POP within a full CD of the current
-- anchor is a duplicate report and is rejected. A KILL is a reset and is
-- always allowed to re-anchor. Grace is intentionally NOT applied here.
function Timers.IsFalsePositive(buffKey, anchor, newEpoch, isKill)
    if isKill then return false end
    local cd = CD[buffKey]
    if not cd or not anchor or anchor <= 0 then return false end
    -- Within a full CD after the anchor => false positive.
    if newEpoch >= anchor and (newEpoch - anchor) < cd then
        return true
    end
    return false
end

----------------------------------------------------------------------
-- Core record path
--
-- kind ∈ "pop" | "killed" | "quest". Applies trust arbitration, the
-- false-positive gate, store-log persistence, callback fan-out, and
-- (re)seeds the CD-warning scheduler. Returns applied:boolean, reason.
----------------------------------------------------------------------

-- forward declarations
local scheduleWarnings
local maybeBroadcast

-- Raise ONE pull bar for `buffKey`, `window` seconds long, measured from
-- `epoch`. Recency-gated: an event older than its own window (plus slack) is a
-- historical anchor and raises nothing — this is the /reload safety gate, since
-- re-syncing hours-old anchors must not resurrect a bar for a past event. The
-- REMAINING window is what ships, so a pull heard 4s late shows a 4s-shorter bar.
local function raisePull(buffKey, epoch, window, trust, zone, yellNum)
    if not window or window <= 0 then return false end
    epoch = epoch or now()
    local elapsed = now() - epoch
    if elapsed > window + PULL_FRESH_SLACK then return false end
    local remaining = window - elapsed
    if remaining > window then remaining = window end   -- future/clock-skew clamp
    if remaining < 1 then remaining = 1 end             -- visible sliver at the edge
    -- Drift measurement seed: a stage-resolved pull arms a pending observation so
    -- the eventual buff-land can measure the real yell->drop delay for
    -- `/dsn debug pulls`. Purely diagnostic; it does not feed bar length.
    if yellNum ~= nil then setPendingPull(buffKey, epoch, yellNum) end
    ns:Fire("PULL_DETECTED", buffKey, remaining, trust, zone)
    return true
end
Timers._raisePull = raisePull

-- Public: raise a pull bar directly, bypassing the log/anchor path. Used by the
-- detectors that must bar WITHOUT recording a pop (Rend's second bar, the ZG
-- stage-2 bar, and the ZG quest hand-in).
function Timers.RaisePull(buffKey, seconds, trust, zone, epoch, yellNum)
    return raisePull(buffKey, epoch or now(), seconds, trust or "local", zone, yellNum)
end

-- Soft-guarded alert emit. hud.lua owns the four-channel dispatcher and loads
-- AFTER us, so this resolves at call time and degrades to a chat line.
-- `category` is an alerts-matrix event type: questHandin / pullTimer / npcDied /
-- npcRespawned / cdWarning / cdExpired / buffGain.
Timers._lastNotice = nil
local function notify(buffKey, category, message)
    Timers._lastNotice = { buff = buffKey, category = category, message = message }
    if ns.HUD and ns.HUD.Alert then
        ns:SafeCall(ns.HUD.Alert, buffKey, category, message)
    else
        ns:Print(message)
    end
end
Timers._notify = notify

-- Display label for a buff key; borrows the HUD's table when it is loaded.
local function buffLabelOf(buffKey)
    local meta = ns.HUD and ns.HUD.BUFF_META and ns.HUD.BUFF_META[buffKey]
    return (meta and meta.label) or tostring(buffKey)
end

-- `yellNum` (optional, 1|2) is the yell stage a LOCAL detector resolved (1 =
-- kill/announce, 2 = come-get-buffed); it selects the per-stage pull window and
-- seeds auto-calibration. Non-local ingest paths (mesh/SN/NWB/DBM/quest) pass
-- nil and rely on their own pullDuration or the stage-2 default.
-- `opts` (optional): { noPull = true } records/logs WITHOUT raising a pull bar.
-- The local yell detector uses it because bars are yell-driven and must show
-- even when the pop itself is rejected by the cooldown/dedup gate.
function Timers.Record(buffKey, epoch, trust, who, kind, zone, pullDuration, yellNum, opts)
    if not CD[buffKey] and buffKey ~= "battleShout" then
        return false, "unknown buff " .. tostring(buffKey)
    end
    epoch = epoch or now()
    trust = trust or "local"
    kind  = kind or "pop"
    local isKill = (kind == "killed")

    local s = stateOf(buffKey)
    local prevAnchor = anchorEpoch(s)
    local prevTrust  = s.trust

    -- False-positive rejection (raw CD window). A pop/quest inside the
    -- current CD is a duplicate. Exception: a strictly higher-trust source
    -- may still upgrade the confirmation without moving the anchor.
    if Timers.IsFalsePositive(buffKey, prevAnchor, epoch, isKill) then
        if trustRank(trust) > trustRank(prevTrust) then
            -- Confirmation upgrade: keep the anchor, raise the trust tag.
            s.trust = trust
            s.confirmed = true
            ns:Fire("TIMER_UPDATED", buffKey)
            return false, "confirmed (upgrade)"
        end
        return false, "false positive (within CD)"
    end

    -- Trust arbitration for concurrent/near-simultaneous reports of the
    -- SAME event: a lower-trust source cannot overwrite a higher-trust
    -- anchor that is essentially the same moment (within 30s).
    if prevAnchor > 0 and math.abs(epoch - prevAnchor) <= 30 then
        if trustRank(trust) < trustRank(prevTrust) then
            return false, "lower trust than existing anchor"
        end
        if trustRank(trust) >= trustRank(prevTrust) and trust ~= prevTrust then
            s.confirmed = true
        end
    end

    -- Apply the anchor. A kill stamps the RESPAWN clock (killedAt), never the
    -- cooldown anchor — see Timers.BuffStatus (A3.1).
    if isKill then
        s.killedAt = epoch
    else
        s.lastPop = epoch
    end
    s.trust = trust
    s.who = who

    -- Persist to the store's capped/deduped log for the three logged buffs.
    local logKey = STORE_LOG_KEY[buffKey]
    if logKey and ns.Store and ns.Store.AddTimerLog then
        local entry = { epoch = epoch, who = who or "?", trust = trust }
        if isKill then entry.killed = true end
        if kind == "quest" then entry.quest = true end
        ns.Store.AddTimerLog(logKey, entry)
    end

    -- Fan out to the UI wave. TIMER_UPDATED always fires (historical anchors
    -- still repopulate the Timers tab and CD countdowns after a reload).
    ns:Fire("TIMER_UPDATED", buffKey)

    -- Pull bar. Only a POP means "a buff is incoming"; an announcer KILL is a
    -- respawn event and raises no bar (A3.1). Window precedence: an explicit
    -- trusted-source remaining (a mesh/SN pull relay carries a real countdown)
    -- wins, else the per-stage spec constant.
    if kind == "pop" and not (opts and opts.noPull) then
        local window
        if pullDuration and pullDuration > 0 then
            window = pullDuration
        else
            window = Timers.EffectivePullWindow(buffKey, yellNum)
        end
        raisePull(buffKey, epoch, window, trust, zone, yellNum)
    end

    -- (Re)seed warnings for the CD-scheduled buffs.
    if scheduleWarnings then scheduleWarnings(buffKey) end

    -- If we are the elected guild broadcaster, relay the merged change.
    if maybeBroadcast then maybeBroadcast() end

    return true, "applied"
end

----------------------------------------------------------------------
-- Detector 1 — local yell / say table  (spec §10.3)
--
-- MONSTER_YELL / MONSTER_SAY carry (text, monsterName, ...). Detection is an
-- EXPLICIT (npcName, textSubstring) -> (buffKey, yellStage) table. The text
-- substring IS the stage discriminator; there is no keyword heuristic and no
-- default stage, so an unrecognised line from a known announcer is simply
-- ignored rather than guessed at (the old heuristic defaulted to stage 2 and
-- manufactured a pop out of any unreadable line).
--
-- Stage rules:
--   stage 1 = the ONLY stage that records a pop and starts bars
--   stage 2 = a complete no-op, EXCEPT Zandalar, whose stage 2 carries a real
--             29s bar but still records nothing (spec §10.7)
-- `kind="killed"` is reserved exclusively for CLEU announcer deaths — a yell is
-- never a kill, however much its text talks about slaying things.
----------------------------------------------------------------------

-- npc name (lowercased) -> ordered list of { text, buff, yell }.
local YELL_NPC_ROWS = {}

local function defineYells(npcNames, rows)
    for i = 1, #npcNames do YELL_NPC_ROWS[npcNames[i]] = rows end
end

defineYells({ "thrall", "herald of thrall" }, {
    { text = "rend blackhand, has fallen",     buff = "rend", yell = 1 },
    { text = "be bathed in my power",          buff = "rend", yell = 2 },
})
defineYells({ "overlord runthak" }, {
    { text = "onyxia, has been slain",         buff = "onyH", yell = 1 },
    { text = "be lifted by the rallying cry",  buff = "onyH", yell = 2 },
})
defineYells({ "major mattingly" }, {
    { text = "history has been made",          buff = "onyA", yell = 1 },
    { text = "hangs from the arches",          buff = "onyA", yell = 2 },
})
defineYells({ "high overlord saurfang" }, {
    { text = "nefarian is slain",              buff = "nefH", yell = 1 },
    { text = "revel in his rallying cry",      buff = "nefH", yell = 2 },
})
-- Field Marshal Stonebridge is the second Alliance Nef announcer; without it
-- every Stonebridge-sourced Nef drop was invisible to Alliance players (A2.5).
defineYells({ "field marshal afrasiabi", "field marshal stonebridge" }, {
    { text = "the lord of blackrock is slain", buff = "nefA", yell = 1 },
    { text = "revel in the rallying cry",      buff = "nefA", yell = 2 },
})
defineYells({ "molthor" }, {
    { text = "now, only one step",             buff = "zg", yell = 1 },   -- MONSTER_SAY
    { text = "begin the ritual",               buff = "zg", yell = 2 },
})
defineYells({ "zandalarian emissary" }, {
    { text = "the blood god",                  buff = "zg", yell = 1 },
})
-- Alert-only (no bar, no pop, no broadcast) and zone-gated to Swamp of Sorrows.
defineYells({ "fallen hero of the horde" }, {
    { text = "my fury is released", buff = "battleShout", yell = 1,
      alertOnly = true, requireZone = "swamp of sorrows" },
})
Timers._yellRows = YELL_NPC_ROWS

-- Sunken Temple reuses the ZG announcer NPCs; those lines mention the Temple of
-- Atal'ai and must never fire a Zandalar pull (A2.6).
local ZG_EXCLUDE = "temple of atal"

-- Rend announcers, and which Barrens bar variant each implies.
local REND_NPC_VARIANT = { ["thrall"] = "thrall", ["herald of thrall"] = "herald" }

-- Resolve a monster name to its canonical table key. Exact match first, then a
-- loose contains-match so a localized/realm prefix still resolves.
local function npcKeyOf(monsterName)
    local key = (monsterName or ""):lower()
    if key == "" then return nil end
    if YELL_NPC_ROWS[key] then return key end
    for npc in pairs(YELL_NPC_ROWS) do
        if key:find(npc, 1, true) then return npc end
    end
    return nil
end
Timers._npcKeyOf = npcKeyOf

-- Resolve an inbound yell to (buffKey, yellNum, npcKey, row).
-- Returns nil when the announcer is unknown OR the line is not one of that
-- announcer's two known yells — no guessing, no default stage.
function Timers.MatchYell(text, monsterName)
    local key = npcKeyOf(monsterName)
    if not key then return nil end
    local rows = YELL_NPC_ROWS[key]
    local body = (text or ""):lower()
    for i = 1, #rows do
        local row = rows[i]
        if body:find(row.text, 1, true) then
            if row.buff == "zg" and body:find(ZG_EXCLUDE, 1, true) then
                return nil   -- Sunken Temple false positive
            end
            return row.buff, row.yell, key, row
        end
    end
    return nil
end

-- Alliance cannot read Horde yell text, so cross-faction Rend is detected by
-- announcer NAME ALONE. It logs the pop and shows a deliberately vague notice
-- (the yell was unreadable; it LOOKED like a Rend pop) and deliberately gets NO
-- pull bar, because we have no idea which stage we just saw. Deduped at 60s.
local ALLY_REND_DEDUP = 60
Timers._lastAllyRendAt = 0

local function playerFaction()
    return (UnitFactionGroup and UnitFactionGroup("player")) or "Horde"
end
Timers._playerFaction = playerFaction

-- Hand-in attribution stash (A4.1): a Rend quest hand-in parks the handing-in
-- player's name here for HANDIN_STASH_TTL seconds so the FOLLOWING yell — the
-- only thing that actually anchors — can attribute the pop to them.
local HANDIN_STASH_TTL = 20
Timers.HANDIN_STASH_TTL = HANDIN_STASH_TTL
Timers._handinStash = {}

local function stashHandin(buffKey, who, at)
    Timers._handinStash[buffKey] = { who = who, at = at or now() }
end
Timers._stashHandin = stashHandin

local function consumeHandinStash(buffKey, t)
    local st = Timers._handinStash[buffKey]
    if not st then return nil end
    Timers._handinStash[buffKey] = nil
    if ((t or now()) - (st.at or 0)) > HANDIN_STASH_TTL then return nil end
    return st.who
end
Timers._consumeHandinStash = consumeHandinStash

-- Raise Rend's TWO stage-1 bars (Orgrimmar + Barrens). hud.lua now keys bars by
-- buff + landing zone, so both bars live concurrently and emit ORDER carries no
-- meaning — the old fire-the-player's-own-zone-LAST reorder (which existed only
-- to pick a winner out of a single-bar collapse) is gone. Fixed order: the
-- REND_BARS row order, Orgrimmar then Barrens.
local function raiseRendBars(npcKey, epoch, trust)
    local bars = REND_BARS[REND_NPC_VARIANT[npcKey] or "thrall"]
    raisePull("rend", epoch, bars[1].seconds, trust, bars[1].zone, 1)
    raisePull("rend", epoch, bars[2].seconds, trust, bars[2].zone, 1)
end
Timers._raiseRendBars = raiseRendBars

function Timers.OnAllianceRendYell(monsterName, t)
    t = t or now()
    if (t - (Timers._lastAllyRendAt or 0)) < ALLY_REND_DEDUP then return false end
    Timers._lastAllyRendAt = t
    local who = consumeHandinStash("rend", t) or monsterName
    Timers.Record("rend", t, "local", who, "pop",
                  GetRealZoneText and GetRealZoneText() or nil, nil, 1, { noPull = true })
    notify("rend", "pullTimer",
        "an unreadable Horde yell just went up — that usually means Rend dropped."
        .. " No pull timer: cross-faction yell text cannot be read.")
    return true
end

local function onMonsterYell(event, text, monsterName)
    local t = now()
    local zone = GetRealZoneText and GetRealZoneText() or nil

    -- Alliance-side Rend: name-only, before any text matching (A2.7).
    local key = npcKeyOf(monsterName)
    if key and REND_NPC_VARIANT[key] and playerFaction() == "Alliance" then
        Timers.OnAllianceRendYell(monsterName, t)
        return
    end

    local buffKey, yellNum, npcKey, row = Timers.MatchYell(text, monsterName)
    if not buffKey then return end

    -- Alert-only rows (Fallen Hero / Battle Shout): no bar, no pop, no
    -- broadcast, and only inside the row's required zone.
    if row and row.alertOnly then
        if row.requireZone and (zone or ""):lower() ~= row.requireZone then return end
        notify(buffKey, "pullTimer", buffLabelOf(buffKey) .. " is up nearby.")
        return
    end

    if yellNum == 2 then
        -- Stage 2 records nothing. Zandalar is the one buff whose stage 2 still
        -- carries a real bar (spec §10.7); every other buff no-ops entirely.
        if buffKey == "zg" then
            raisePull("zg", t, PULL_WINDOWS.zg[2], "local", zone, 2)
        end
        return
    end

    -- Stage 1: the pop. Bars are raised explicitly (and unconditionally) here
    -- because a yell always means a buff is inbound, even when the pop itself is
    -- rejected as a duplicate by the cooldown gate inside Record.
    local who = consumeHandinStash(buffKey, t) or monsterName
    Timers.Record(buffKey, t, "local", who, "pop", zone, nil, 1, { noPull = true })
    if buffKey == "rend" then
        raiseRendBars(npcKey, t, "local")
    else
        raisePull(buffKey, t, PULL_WINDOWS[buffKey] and PULL_WINDOWS[buffKey][1],
                  "local", zone, 1)
    end
end

----------------------------------------------------------------------
-- Detector 2 — CLEU NPC-death, capital-gated, announcer-ID table
--
-- Death of a capital announcer NPC is treated as a died/respawn signal.
-- Gated to the capital zones so unrelated same-name mobs elsewhere do not
-- trip it. The NPC id is parsed from the destGUID; a name fallback keeps
-- the detector working even where the numeric id is uncertain.
----------------------------------------------------------------------

-- Capital zones where announcer events are valid. ONLY the two capitals that
-- actually host announcers (A3.2) — the four extra capitals we used to accept
-- could trip on same-named mobs elsewhere.
local CAPITAL_ZONES = {
    ["orgrimmar"]      = true,
    ["stormwind city"] = true,
    ["stormwind"]      = true,
}
Timers._capitalZones = CAPITAL_ZONES

-- Announcer NPC-id table -> buffKey (spec §10.3). Matched alongside destName so
-- a mislabelled id never blocks a valid name hit.
local ANNOUNCER_ID = {
    [14392] = "onyH",   -- Overlord Runthak (Orgrimmar)
    [14394] = "onyA",   -- Major Mattingly (Stormwind City)
    [14720] = "nefH",   -- High Overlord Saurfang (Orgrimmar)
    [14721] = "nefA",   -- Field Marshal Afrasiabi (Stormwind City)
}
Timers._announcerID = ANNOUNCER_ID

-- Name fallback. Deliberately its OWN table, not the yell table: Thrall and the
-- Zandalar NPCs yell but are not announcers whose death means anything.
local ANNOUNCER_NAME = {
    ["overlord runthak"]         = "onyH",
    ["major mattingly"]          = "onyA",
    ["high overlord saurfang"]   = "nefH",
    ["field marshal afrasiabi"]  = "nefA",
    ["field marshal stonebridge"]= "nefA",
}
Timers._announcerName = ANNOUNCER_NAME

local function announcerBuffFor(npcID, destName)
    if npcID and ANNOUNCER_ID[npcID] then return ANNOUNCER_ID[npcID] end
    if destName then return ANNOUNCER_NAME[destName:lower()] end
    return nil
end
Timers._announcerBuffFor = announcerBuffFor

-- Parse the numeric NPC id out of a Creature/Vehicle GUID.
local function npcIDFromGUID(guid)
    if type(guid) ~= "string" then return nil end
    -- Creature-0-<server>-<instance>-<zoneUID>-<npcID>-<spawnUID>
    local id = guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    return id and tonumber(id) or nil
end
Timers._npcIDFromGUID = npcIDFromGUID

local function inCapital()
    local zone = GetRealZoneText and GetRealZoneText() or ""
    return CAPITAL_ZONES[zone:lower()] == true
end

local function onCombatLog()
    if not CombatLogGetCurrentEventInfo then return end
    if not inCapital() then return end
    local _, subevent, _, _, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
    if subevent ~= "UNIT_DIED" and subevent ~= "PARTY_KILL" then return end
    local npcID = npcIDFromGUID(destGUID)
    local buffKey = announcerBuffFor(npcID, destName)
    if not buffKey then return end
    Timers.OnAnnouncerDeath(buffKey, destName)
end

-- An announcer death is a RESPAWN event, not a cooldown start: it logs a
-- `killed` entry, alerts, and broadcasts, and the readout becomes
-- "NPC killed — respawns in <t>" for 360s and then plain can-pop (A3.1).
-- It raises no pull bar (Record only bars on a pop).
function Timers.OnAnnouncerDeath(buffKey, destName, t)
    t = t or now()
    Timers.Record(buffKey, t, "local", destName, "killed",
                  GetRealZoneText and GetRealZoneText() or nil)
    notify(buffKey, "npcDied",
        (destName or buffLabelOf(buffKey)) .. " was killed — respawns in about 6 minutes.")
    return true
end

----------------------------------------------------------------------
-- Detector 3 — QUEST_TURNED_IN hand-in ids
----------------------------------------------------------------------

-- questID -> buffKey (H/A resolved for ony/nef where the id is faction-fixed).
-- FACTION FIX: 7491/7496 and 7782/7784 were mapped to the WRONG factions here.
-- Per spec §10.3 the hand-ins are 7491 Ony(A) · 7496 Ony(H) · 7782 Nef(A) ·
-- 7784 Nef(H); we had each pair reversed, so an Ony hand-in was credited to the
-- opposing faction's timer. (The gap analysis only checked the id SET.)
local HANDIN_QUEST = {
    [4974] = "rend",
    [7491] = "onyA",  [7496] = "onyH",
    [7782] = "nefA",  [7784] = "nefH",
    [8183] = "zg",
}
Timers._handinQuest = HANDIN_QUEST

-- Hand-ins whose processing is SUPPRESSED while the buff is already on
-- cooldown (A4.2). Nefarian and Zandalar carry no server cooldown (spec §10.2 —
-- Nef CD tracking was removed; ZG keeps no pop log) and are never suppressed.
-- Note this is a detection-side list only; Timers.CD keeps nef/zg entries
-- because the false-positive gate still uses them to dedup relayed reports.
local HANDIN_CD_GATED = { rend = true, onyH = true, onyA = true }
Timers._handinCDGated = HANDIN_CD_GATED

-- QUEST_TURNED_IN(questID, xpReward, moneyReward).
function Timers.OnQuestHandin(questID, t)
    local buffKey = HANDIN_QUEST[questID]
    if not buffKey then return false, "not a buff hand-in" end
    t = t or now()

    -- A4.2: a hand-in for a buff already on cooldown is ignored ENTIRELY —
    -- no anchor, no stash, no alert. (The server would have refused it too.)
    if HANDIN_CD_GATED[buffKey] and Timers.BuffStatus(buffKey, t).state == "cd" then
        return false, "on cooldown"
    end

    local who  = (UnitName and UnitName("player")) or "handin"
    local zone = GetRealZoneText and GetRealZoneText() or nil

    if buffKey == "rend" then
        -- A4.1: NON-ANCHORING. A Rend hand-in that never produces a buff (wipe,
        -- or already popped server-side) must not put us on a phantom 3h CD.
        -- Park the name; only the following yell anchors, and it claims this
        -- attribution.
        stashHandin("rend", who, t)
    elseif buffKey == "zg" then
        -- A4.3: the Zandalar hand-in itself starts the 50s stage-1 pull.
        raisePull("zg", t, PULL_WINDOWS.zg[1], "local", zone, 1)
    else
        Timers.Record(buffKey, t, "local", who, "quest", zone, nil, nil, { noPull = true })
    end

    notify(buffKey, "questHandin", buffLabelOf(buffKey) .. " quest handed in by " .. who .. ".")
    return true, "handled"
end

local function onQuestTurnedIn(event, questID)
    Timers.OnQuestHandin(questID)
end

----------------------------------------------------------------------
-- Buff-land detector (pull auto-calibration)
--
-- When the world buff that a pending pull was for actually LANDS on the player,
-- measure the real announce/yell -> drop delay. We reuse the same aura surface
-- tracker.lua proved in-game (C_UnitAuras.GetBuffDataByIndex on "player") rather
-- than editing tracker. One world-buff aura can come from more than one pull buff
-- — Onyxia AND Nefarian head turn-ins both grant "Rallying Cry of the
-- Dragonslayer" — so an aura maps to a CANDIDATE set and we credit only the
-- candidate that actually had a pull active (the pending gate), picking the most
-- recent when more than one is somehow pending.
----------------------------------------------------------------------

-- Landed world-buff aura name (lowercased prefix) -> candidate pull buff keys.
local PULL_AURA_CANDIDATES = {
    ["rallying cry of the dragonslayer"] = { "onyH", "onyA", "nefH", "nefA" },
    ["warchief's blessing"]              = { "rend" },
    ["spirit of zandalar"]               = { "zg" },
}

-- Fold a typographic apostrophe (U+2019) to ASCII so "Warchief's Blessing"
-- rendered by the live client still matches the ASCII-apostrophe prefix above.
local function auraNorm(s)
    s = (s or ""):lower()
    return (s:gsub("\226\128\153", "'"))
end

-- Resolve the single best pending candidate for a landed aura prefix and, if one
-- is pending, book the observation. Pure over its inputs (candidates + pending +
-- landTime); the game-side scanner supplies the live aura names. Returns the
-- credited buffKey or nil.
local function creditPullLand(prefix, landTime)
    local candidates = PULL_AURA_CANDIDATES[prefix]
    if not candidates then return nil end
    local bestKey, bestYell
    for c = 1, #candidates do
        local pend = Timers._pendingPull[candidates[c]]
        if pend then
            local yt = pend[2] or pend[1] or 0
            if not bestYell or yt > bestYell then
                bestYell, bestKey = yt, candidates[c]
            end
        end
    end
    if not bestKey then return nil end
    Timers.NotePullGain(bestKey, landTime)
    return bestKey
end
Timers._creditPullLand = creditPullLand

-- UNIT_AURA handler: on a player aura change, if any pull is pending, scan the
-- player's buffs for a landed pull aura and credit its calibration. Cheap no-op
-- when nothing is pending. Uses the proven C_UnitAuras surface.
local function onPlayerAura(event, unit)
    if unit and unit ~= "player" then return end
    if next(Timers._pendingPull) == nil then return end
    if not (C_UnitAuras and C_UnitAuras.GetBuffDataByIndex) then return end
    local landTime = now()
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if not aura then break end
        local nm = auraNorm(aura.name)
        for prefix in pairs(PULL_AURA_CANDIDATES) do
            if nm:find(prefix, 1, true) == 1 then
                creditPullLand(prefix, landTime)
            end
        end
    end
end

----------------------------------------------------------------------
-- NWB type-string mapping (shared by the NWB ingest opcodes)
----------------------------------------------------------------------

local function nwbTypeToBuff(t)
    if t == "rend" then return "rend" end
    if t == "ony"  then return factionKey("ony") end
    if t == "nef"  then return factionKey("nef") end
    if t == "zan"  then return "zg" end
    return nil
end
Timers._nwbTypeToBuff = nwbTypeToBuff

----------------------------------------------------------------------
-- Detector 4 — NWB (NovaWorldBuffs) ingest  [RECEIVE-ONLY]
--
-- NWB sends AceComm messages on prefix "NWB" over GUILD, pipeline:
--   Serialize -> CompressDeflate -> EncodeForWoWAddonChannel.
-- We reverse it (Decode -> Decompress -> Deserialize). AceComm-3.0 handles
-- the chunk reassembly for us when we register through the shared LibStub
-- instance NWB itself loaded; if the libs are absent (NWB not installed),
-- ingest disables gracefully. We NEVER transmit on the NWB prefix.
--
-- The deserialized top value is a space-delimited string:
--   args = { cmd, remoteVersion, time-layer, elapsed, payload }
-- For timer opcodes the payload is a second serialized table whose keys are
-- single/double-char short codes (n=rendTimer, s=onyTimer, y=nefTimer,
-- f1..f10=flower, t1..t6=tuber). For event opcodes (yell/drop/flower/
-- npcKilled) the payload is a plain "<type> <layer>" string.
----------------------------------------------------------------------

local NWB_MIN_VERSION = 2.75

-- Felwood node respawn (songflower AND tuber): 1500s / 25min, matching the
-- authoritative NWB reference.
local NODE_RESPAWN = 1500
Timers.NODE_RESPAWN = NODE_RESPAWN

Timers._nwb = { serializer = nil, libSerialize = nil, deflate = nil, comm = nil, obj = nil, ready = false }

-- NWB diagnostics (item 40): every stage counted so `/nexus debug nwb` can
-- self-diagnose the owner's next request press. No silent skips in the counters
-- (the ingest itself stays silent in chat).
Timers._nwbStats = {
    requestsSent = 0, lastRequestAt = 0, lastRequestBytes = 0,
    heard = 0, lastHeardAt = 0, byChannel = {},
    -- per-stage drop counts (each with a reason label)
    drop = {
        notReady = 0, channelDecode = 0, decompress = 0, deserialize = 0,
        notString = 0, versionGate = 0, emptyData = 0, payloadNotTable = 0,
    },
    serializerPath = { libSerialize = 0, aceSerializer = 0 },
    ingested = 0, lastCmd = nil, lastCmdAt = 0, lastApplied = nil,
}

local function nwbBump(path, key)
    local t = Timers._nwbStats[path]
    if type(t) == "table" then t[key] = (t[key] or 0) + 1 end
end

-- NWB 3.39 serializes with LibSerialize; older builds used AceSerializer. Try
-- LibSerialize first, fall back to AceSerializer, so both inbound formats
-- decode. Returns ok, value (mirrors both libs' Deserialize signature).
local function nwbDeserialize(str)
    local nwb = Timers._nwb
    if type(str) ~= "string" then return false end
    if nwb.libSerialize and nwb.libSerialize.Deserialize then
        local ok, v = nwb.libSerialize:Deserialize(str)
        if ok then nwbBump("serializerPath", "libSerialize"); return true, v end
    end
    if nwb.serializer and nwb.serializer.Deserialize then
        local ok, v = nwb.serializer:Deserialize(str)
        if ok then nwbBump("serializerPath", "aceSerializer"); return true, v end
    end
    return false
end
Timers._nwbDeserialize = nwbDeserialize

-- Split helper mirroring NWB's space-explode with a field cap.
local function explodeSpace(str, maxFields)
    local out, count = {}, 0
    local start = 1
    while true do
        count = count + 1
        if count >= maxFields then
            out[count] = str:sub(start)
            break
        end
        local sp = str:find(" ", start, true)
        if not sp then
            out[count] = str:sub(start)
            break
        end
        out[count] = str:sub(start, sp - 1)
        start = sp + 1
    end
    return out
end
Timers._explodeSpace = explodeSpace

-- Read a numeric epoch from a payload short-key, tolerating string values.
local function nwbEpoch(v)
    local n = tonumber(v)
    if n and n > 1000000000 then return n end   -- sane epoch guard
    return nil
end

-- Read the world-buff + node timer fields out of ONE NWB data table. Verified
-- against NWB 3.39 source (Modules\Data.lua shortKeys): wire SHORT keys are
-- n=rendTimer, s=onyTimer, y=nefTimer, f1..f10=flower1..10, t1..t6=tuber1..6.
-- We also tolerate the WORD keys (rendTimer/onyTimer/nefTimer/flowerN/tuberN) in
-- case a layer sub-table was not key-compacted. ZG/Zandalar is NOT transmitted
-- by NWB at all, so there is no zan field to read. `applied` accumulates counts.
local function readNWBTimerFields(tbl, applied)
    if type(tbl) ~= "table" then return end
    local r = nwbEpoch(tbl.n) or nwbEpoch(tbl.rendTimer)
    if r then Timers.Record("rend", r, "nwb", "NWB", "pop"); applied.rend = true end
    local o = nwbEpoch(tbl.s) or nwbEpoch(tbl.onyTimer)
    if o then Timers.Record(factionKey("ony"), o, "nwb", "NWB", "pop"); applied.ony = true end
    local nf = nwbEpoch(tbl.y) or nwbEpoch(tbl.nefTimer)
    if nf then Timers.Record(factionKey("nef"), nf, "nwb", "NWB", "pop"); applied.nef = true end
    for i = 1, 10 do
        local e = nwbEpoch(tbl["f" .. i]) or nwbEpoch(tbl["flower" .. i])
        if e then Timers.MarkNode("flower", i, e, "nwb"); applied.flower = (applied.flower or 0) + 1 end
    end
    for i = 1, 6 do
        local e = nwbEpoch(tbl["t" .. i]) or nwbEpoch(tbl["tuber" .. i])
        if e then Timers.MarkNode("tuber", i, e, "nwb"); applied.tuber = (applied.tuber or 0) + 1 end
    end
end
Timers._readNWBTimerFields = readNWBTimerFields

-- Ingest a decoded NWB timer payload table. Handles BOTH flat (non-layered) and
-- LAYERED realms (item 40): on layered realms NWB nests per-layer timer tables
-- one level down under a "layers" map. The short key for "layers" is not a
-- clean-room fact, so we scan defensively — any sub-table whose values are
-- themselves tables is treated as a layer map and each layer is read. Reading is
-- idempotent (Record's CD gate dedups), so scanning is safe.
function Timers.IngestNWBTimers(payload)
    if type(payload) ~= "table" then return end
    local applied = {}
    readNWBTimerFields(payload, applied)
    for _, v in pairs(payload) do
        if type(v) == "table" then
            local looksLayerMap = false
            for _, lv in pairs(v) do
                if type(lv) == "table" then looksLayerMap = true break end
            end
            if looksLayerMap then
                for _, layer in pairs(v) do readNWBTimerFields(layer, applied) end
            end
        end
    end
    Timers._nwbStats.lastApplied = applied
    return applied
end

-- Handle one fully-reassembled NWB message (called by AceComm — AceComm owns the
-- multi-part reassembly via the shared LibStub instance; both NWB's and our
-- RegisterComm("NWB") callbacks fire, so `message` is already whole). Every
-- drop path is counted for `/nexus debug nwb` (item 40).
function Timers.OnNWBMessage(prefix, message, channel, sender)
    local stats = Timers._nwbStats
    stats.heard = stats.heard + 1
    stats.lastHeardAt = now()
    stats.byChannel[channel or "?"] = (stats.byChannel[channel or "?"] or 0) + 1

    local nwb = Timers._nwb
    -- Require the receiver wired + deflate + at least one deserializer
    -- (AceSerializer is optional; LibSerialize is the primary path).
    if not nwb.ready or not nwb.deflate or not (nwb.libSerialize or nwb.serializer) then
        nwbBump("drop", "notReady"); return
    end
    -- World-buff timer data rides GUILD (also YELL/SAY world broadcast).
    local decoded
    if channel == "YELL" or channel == "SAY" then
        decoded = nwb.deflate.DecodeForWoWChatChannel and nwb.deflate:DecodeForWoWChatChannel(message)
    else
        decoded = nwb.deflate.DecodeForWoWAddonChannel and nwb.deflate:DecodeForWoWAddonChannel(message)
    end
    if not decoded then nwbBump("drop", "channelDecode"); return end
    local decompressed = nwb.deflate:DecompressDeflate(decoded)
    if not decompressed then nwbBump("drop", "decompress"); return end
    local ok, top = nwbDeserialize(decompressed)
    if not ok then nwbBump("drop", "deserialize"); return end
    if type(top) ~= "string" then nwbBump("drop", "notString"); return end

    local args = explodeSpace(top, 5)
    local cmd = args[1]
    local remoteVersion = tonumber(args[2]) or 0
    if remoteVersion < NWB_MIN_VERSION then nwbBump("drop", "versionGate"); return end
    noteFreshness("nwb")   -- valid, version-gated NWB traffic seen
    stats.lastCmd = cmd
    stats.lastCmdAt = now()
    local dataStr = args[5]

    if cmd == "data" or cmd == "settings" or cmd == "requestData" then
        if type(dataStr) == "string" and #dataStr > 0 then
            local ok2, payload = nwbDeserialize(dataStr)
            if not ok2 or type(payload) ~= "table" then
                nwbBump("drop", "payloadNotTable")
            else
                local applied = Timers.IngestNWBTimers(payload)
                if applied and next(applied) ~= nil then stats.ingested = stats.ingested + 1 end
            end
        else
            nwbBump("drop", "emptyData")
        end
        Timers._sawNWB = true
    elseif cmd == "yell" or cmd == "yell2" then
        -- Carry the yell STAGE through so the relayed bar uses the same spec
        -- window a local yell would (and so a stage-2 relay for a buff whose
        -- stage 2 has no bar correctly raises none).
        local t = dataStr and dataStr:match("^(%S+)")
        local buffKey = t and nwbTypeToBuff(t)
        if buffKey then
            Timers.Record(buffKey, now(), "nwb", "NWB", "pop", nil, nil,
                          (cmd == "yell") and 1 or 2)
        end
        Timers._sawNWB = true
    elseif cmd == "npcKilled" or cmd == "npcKilled2" or cmd == "drop" then
        local t = dataStr and dataStr:match("^(%S+)")
        local buffKey = t and nwbTypeToBuff(t)
        if buffKey then
            local kind = (cmd == "drop") and "pop" or "killed"
            Timers.Record(buffKey, now(), "nwb", "NWB", kind)
        end
        Timers._sawNWB = true
    elseif cmd == "flower" or cmd == "flower2" then
        -- Node pick relayed from another NWB client; index unknown here,
        -- so it is folded in via the periodic full-data sync above.
        Timers._sawNWB = true
    end
end

local function setupNWB()
    local nwb = Timers._nwb
    if nwb.ready then return end
    -- LibStub is a TABLE with a __call metamethod (not a function) — the old
    -- `type(LibStub) ~= "function"` guard ALWAYS returned here, so the NWB
    -- receiver was never wired and no NWB data ever ingested (item 40 root
    -- cause). Presence is all we need: LibStub("X", true) is guarded per-lib.
    if not LibStub then return end
    local serializer = LibStub("AceSerializer-3.0", true)
    local deflate    = LibStub("LibDeflate", true)
    local comm       = LibStub("AceComm-3.0", true)
    -- LibSerialize is vendored (used to BUILD the requestData wire and to decode
    -- modern NWB 3.39 traffic). AceSerializer is only the LEGACY decode fallback,
    -- so it is OPTIONAL: require deflate + comm + at least one deserializer. This
    -- degrades gracefully if a future NWB drops AceSerializer (LibSerialize-first
    -- already handles decode).
    nwb.libSerialize = LibStub("LibSerialize", true)
    if not (deflate and comm and (nwb.libSerialize or serializer)) then return end
    nwb.serializer, nwb.deflate, nwb.comm = serializer, deflate, comm
    -- Embed a private object and register the NWB prefix; AceComm's shared
    -- registry reassembles chunks and dispatches to us AND to NWB.
    nwb.obj = nwb.obj or {}
    comm:Embed(nwb.obj)
    nwb.obj:RegisterComm("NWB", function(prefix, msg, chan, sender)
        ns:SafeCall(Timers.OnNWBMessage, prefix, msg, chan, sender)
    end)
    nwb.ready = true
end

----------------------------------------------------------------------
-- Detector 5 — DBM (D5) ingest  [RECEIVE-ONLY]
--
-- DBM broadcasts tab-delimited messages on prefix "D5":
--   <sender-realm>\t<protocol>\t<opcode>\t<args...>   (protocol == 1).
-- Pull timers in current DBM are boss-agnostic Blizzard countdowns, so
-- buff identity comes from the combat-start ("C", carrying modId) and
-- boss-kill ("K", carrying creature id) syncs. We map the four world-boss
-- creature ids to buff keys and treat a DBM hit as the lowest-trust
-- pull/kill signal. Break ("BT") and pizza ("U") timers carry no boss id
-- and are ignored for attribution.
----------------------------------------------------------------------

local DBM_PROTOCOL_MIN = 1

-- Creature id (from D5 "K"/"C") -> buff key. Stable Classic ids.
local DBM_CREATURE = {
    [10184] = "ony",   -- Onyxia
    [11583] = "nef",   -- Nefarian
    [14834] = "zg",    -- Hakkar (Zul'Gurub)
    [10429] = "rend",  -- Warchief Rend Blackhand (UBRS)
}
Timers._dbmCreature = DBM_CREATURE

local function dbmCreatureToBuff(cId)
    local base = DBM_CREATURE[cId]
    if not base then return nil end
    if base == "ony" then return factionKey("ony") end
    if base == "nef" then return factionKey("nef") end
    return base
end
Timers._dbmCreatureToBuff = dbmCreatureToBuff

-- Parse a raw D5 body into { protocol, opcode, args={...} }. Pure helper.
function Timers.ParseDBM(body)
    if type(body) ~= "string" then return nil end
    local fields = {}
    local start = 1
    while true do
        local tab = body:find("\t", start, true)
        if not tab then
            fields[#fields + 1] = body:sub(start)
            break
        end
        fields[#fields + 1] = body:sub(start, tab - 1)
        start = tab + 1
    end
    -- fields: [1]=sender-realm [2]=protocol [3]=opcode [4..]=args
    local protocol = tonumber(fields[2])
    if not protocol or protocol < DBM_PROTOCOL_MIN then return nil end
    local args = {}
    for i = 4, #fields do args[#args + 1] = fields[i] end
    return { protocol = protocol, opcode = fields[3], args = args, sender = fields[1] }
end

function Timers.OnDBMMessage(body)
    local m = Timers.ParseDBM(body)
    if not m then return end
    local op = m.opcode
    if op == "K" then
        -- "K": <creatureId>\t<difficulty>
        local cId = tonumber(m.args[1])
        local buffKey = cId and dbmCreatureToBuff(cId)
        if buffKey then
            Timers.Record(buffKey, now(), "dbm", "DBM", "killed")
        end
    elseif op == "C" then
        -- "C": <delay>\t<modId>\t... — modId is a string boss-mod id; map by
        -- the creature id when it is numeric (Classic mods key on cId).
        local modId = tonumber(m.args[2])
        local buffKey = modId and dbmCreatureToBuff(modId)
        if buffKey then
            Timers.Record(buffKey, now(), "dbm", "DBM", "pop")
        end
    end
end

----------------------------------------------------------------------
-- Felwood node engine
--
-- 10 songflowers + 6 tubers, normalized (0-1) Felwood coordinates
-- (uiMapID 1448). Pick detection: a successful gather/cleanse cast by the
-- player, matched to the nearest node within a small radius, OR a
-- songflower-serenade aura gain. Respawn = NODE_RESPAWN (1500s). State:
--   "unknown" (UP?)  — no observation this cycle
--   "down"    — picked, counting down (minus-timer = remaining)
--   "up"      — respawned / freshly seen available
----------------------------------------------------------------------

Timers.FELWOOD_MAP = 1448

-- { x, y } normalized 0-1; index is the node number. Ordered north->south.
Timers.NODES = {
    flower = {
        { x = 0.639, y = 0.061, label = "North Felpaw Village" },
        { x = 0.558, y = 0.104, label = "West Felpaw Village" },
        { x = 0.506, y = 0.139, label = "North of Irontree Woods" },
        { x = 0.633, y = 0.226, label = "Talonbranch Glade" },
        { x = 0.401, y = 0.444, label = "Shatter Scar Vale" },
        { x = 0.343, y = 0.522, label = "Bloodvenom Post" },
        { x = 0.401, y = 0.565, label = "East of Jaedenar" },
        { x = 0.483, y = 0.757, label = "North of Emerald Sanctuary" },
        { x = 0.459, y = 0.852, label = "West of Emerald Sanctuary" },
        { x = 0.529, y = 0.878, label = "South of Emerald Sanctuary" },
    },
    tuber = {
        { x = 0.495, y = 0.122, label = "North of Irontree Woods" },
        { x = 0.506, y = 0.182, label = "Irontree Woods" },
        { x = 0.407, y = 0.192, label = "West of Irontree Woods" },
        { x = 0.430, y = 0.469, label = "Bloodvenom Falls" },
        { x = 0.341, y = 0.603, label = "Jaedenar" },
        { x = 0.402, y = 0.852, label = "West of Emerald Sanctuary" },
    },
}

-- Store key for a node kind: flower -> timers.flower, tuber -> timers.tuber.
local function nodePopTable(kind)
    local t = ns.Store and ns.Store.GetTimers and ns.Store.GetTimers()
    if not t then return nil end
    if kind == "flower" then return t.flower end
    if kind == "tuber"  then return t.tuber end
    return nil
end

-- Nearest node of `kind` to (x,y). Returns index, distance. Pure helper.
function Timers.NearestNode(kind, x, y)
    local list = Timers.NODES[kind]
    if not list or not x or not y then return nil end
    local bestIdx, bestDist
    for i = 1, #list do
        local n = list[i]
        local dx, dy = n.x - x, n.y - y
        local d = dx * dx + dy * dy
        if not bestDist or d < bestDist then
            bestIdx, bestDist = i, d
        end
    end
    if not bestIdx then return nil end
    return bestIdx, math.sqrt(bestDist)
end

-- Compute a node's state at time `t` from its pop epoch. Pure helper.
-- `respawn` = minus-timer duration (the down-count); `upDuration` = how long
-- the post-respawn "up" (UP?) window is shown before reverting to "unknown".
-- upDuration nil/<=0 means the up window is indefinite (default; reproduces the
-- prior always-up-after-respawn behavior).
function Timers.NodeState(popEpoch, t, respawn, upDuration)
    respawn = respawn or NODE_RESPAWN
    if not popEpoch or popEpoch <= 0 then
        return { state = "unknown", remaining = 0, since = 0 }
    end
    local elapsed = t - popEpoch
    if elapsed < respawn then
        return { state = "down", remaining = respawn - elapsed, since = elapsed }
    end
    local sinceUp = elapsed - respawn
    if not upDuration or upDuration <= 0 or sinceUp < upDuration then
        return { state = "up", remaining = 0, since = sinceUp }
    end
    return { state = "unknown", remaining = 0, since = sinceUp }
end

-- Record a node pick. kind ∈ "flower"/"tuber", index 1-based. Applies a
-- simple freshness gate (ignore a stale duplicate of the same pop) and
-- fires NODE_UPDATED.
function Timers.MarkNode(kind, index, epoch, trust)
    local pops = nodePopTable(kind)
    if not pops then return false end
    epoch = epoch or now()
    local prev = pops[index] or 0
    -- Ignore an older or identical epoch (dup relay); accept fresher picks.
    if epoch <= prev then return false end
    pops[index] = epoch
    ns:Fire("NODE_UPDATED", kind .. index)
    if maybeBroadcast then maybeBroadcast() end
    -- Songflower picked chat alert (round-12 restore 3b — item 28). The options toggle
    -- felwood.pickedChatAlerts wrote a key nothing consumed; emit one chat line when a
    -- LOCAL flower pick is recorded (proximity detection / manual mark). Local-only so
    -- mesh-relayed and bulk-import picks don't spam. Off by default (nil reads as off).
    if kind == "flower" and trust == "local" then
        local s = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
        local fw = s and s.timerSettings and s.timerSettings.felwood
        if fw and fw.pickedChatAlerts then
            local node = Timers.NODES and Timers.NODES.flower and Timers.NODES.flower[index]
            ns:Print(("songflower picked: %s"):format((node and node.label) or ("Songflower " .. index)))
        end
    end
    return true
end

-- Felwood display settings (songflower durations). Soft-guarded so the engine
-- still resolves before the store applies defaults.
local function felwoodSettings()
    local s = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
    return (s and s.timerSettings and s.timerSettings.felwood) or {}
end

-- Public: current state for a node key like "flower3".
function Timers.GetNodeState(nodeKey)
    local kind, idxStr = nodeKey:match("^(%a+)(%d+)$")
    local index = tonumber(idxStr)
    if not kind or not index then return nil end
    local pops = nodePopTable(kind)
    local popEpoch = pops and pops[index] or 0
    -- Songflowers honor the configurable display durations; tubers keep the
    -- fixed respawn with an indefinite up window (unchanged).
    local respawn, upDur = NODE_RESPAWN, 0
    if kind == "flower" then
        local fw = felwoodSettings()
        respawn = fw.flowerMinusDuration or NODE_RESPAWN
        upDur   = fw.flowerUpDuration or 0
    end
    return Timers.NodeState(popEpoch, now(), respawn, upDur)
end

-- The ONE cast that means "a node was picked": Cleansed Songflower. Both
-- songflowers and Whipper Root Tubers are gathered through it.
local SONGFLOWER_SPELL = 6478
Timers.SONGFLOWER_SPELL = SONGFLOWER_SPELL

-- Node match radius in normalized map units (spec §10.3: 6% of map distance).
-- The old 0.015 was 4x tighter than the reference and missed genuine picks made
-- a few yards off the stored coordinate (A5.2).
local NODE_MATCH_RADIUS = 0.06
Timers.NODE_MATCH_RADIUS = NODE_MATCH_RADIUS

-- Resolve a pick position to (kind, index, distance), or nil when nothing is in
-- range. The two co-located flower/tuber sites are separated by the NEAREST-
-- distance tie-break rather than by a tighter radius, so widening the radius
-- cannot make a flower pick land on its neighbouring tuber.
function Timers.MatchNodePick(x, y, radius)
    if not x or not y then return nil end
    radius = radius or NODE_MATCH_RADIUS
    local fIdx, fDist = Timers.NearestNode("flower", x, y)
    local tIdx, tDist = Timers.NearestNode("tuber", x, y)
    local kind, index, dist
    if fDist and (not tDist or fDist <= tDist) then
        kind, index, dist = "flower", fIdx, fDist
    elseif tDist then
        kind, index, dist = "tuber", tIdx, tDist
    end
    if not kind or dist > radius then return nil end
    return kind, index, dist
end

-- Pick detection from a successful player cast in Felwood.
-- UNIT_SPELLCAST_SUCCEEDED(unitTarget, castGUID, spellID) — the spell id was
-- always in the payload and always discarded, so ANY cast near a node (a mount,
-- a heal, a profession cast) started a 25-minute countdown (A5.1).
local function onSpellSucceeded(event, unit, castGUID, spellID)
    if unit ~= "player" then return end
    if spellID ~= SONGFLOWER_SPELL then return end
    if not (C_Map and C_Map.GetBestMapForUnit) then return end
    local mapID = C_Map.GetBestMapForUnit("player")
    if mapID ~= Timers.FELWOOD_MAP then return end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    local kind, index = Timers.MatchNodePick(x, y)
    if not kind then return end
    Timers.MarkNode(kind, index, now(), "local")
end

----------------------------------------------------------------------
-- CD-warning scheduler
--
-- For each warned buff (Rend + Ony H/A) schedule 5-min, 1-min, and off-CD
-- (ready) callbacks. Seeded so warnings that already elapsed offline do NOT
-- backfire: only strictly-future thresholds are armed. Re-seeding cancels
-- prior arms for that buff by bumping a per-buff generation token.
----------------------------------------------------------------------

Timers._warnGen = {}   -- buffKey -> generation counter

local WARN_THRESHOLDS = {
    { key = "5min", lead = 300 },
    { key = "1min", lead = 60  },
    { key = "ready", lead = 0  },
}

scheduleWarnings = function(buffKey)
    if not CD[buffKey] then return end
    -- Only the warned buffs get scheduler arms.
    local warned = false
    for i = 1, #WARNED_BUFFS do if WARNED_BUFFS[i] == buffKey then warned = true break end end
    if not warned then return end

    local s = stateOf(buffKey)
    local anchor = anchorEpoch(s)
    -- A3.3: while the newest event is a KILL the buff is respawning, not on
    -- cooldown, so every scheduled CD warning is suppressed. Kill/respawn timing
    -- carries ~2 minutes of server jitter; warning off a kill-derived clock is
    -- worse than saying nothing. Also bump the generation so any arm from a
    -- previous pop is cancelled.
    if (s.killedAt or 0) >= math.max(anchor, 1) then
        Timers._warnGen[buffKey] = (Timers._warnGen[buffKey] or 0) + 1
        return
    end
    if anchor <= 0 then return end
    if not (C_Timer and C_Timer.After) then return end
    local nextAt = anchor + CD[buffKey]

    local gen = (Timers._warnGen[buffKey] or 0) + 1
    Timers._warnGen[buffKey] = gen

    local t = now()
    for i = 1, #WARN_THRESHOLDS do
        local th = WARN_THRESHOLDS[i]
        local fireAt = nextAt - th.lead
        local delay = fireAt - t
        if delay > 0 then
            C_Timer.After(delay, function()
                -- Stale arm guard: a newer pop re-seeded this buff.
                if Timers._warnGen[buffKey] ~= gen then return end
                ns:Fire("CD_WARNING", buffKey, th.key)
            end)
        end
    end
end
Timers.ScheduleWarnings = scheduleWarnings

-- Seed warnings for all warned buffs from persisted anchors (login path).
local function seedAllWarnings()
    -- Rebuild in-memory anchors from the persisted store logs first.
    Timers.RehydrateFromStore()
    for i = 1, #WARNED_BUFFS do
        scheduleWarnings(WARNED_BUFFS[i])
    end
end

-- Rebuild in-memory anchors from the store's newest-first pop logs so the
-- scheduler and false-positive gate survive a relog AND so a freshly-imported
-- account derives live CD state from its imported pop logs (item 39 — the owner
-- hit "no data" after /nexus import because live state was never seeded from the
-- logs). Entries older than a full CD are ignored (the buff is long-available =
-- no meaningful countdown). Fires TIMER_UPDATED per seeded buff so the UI repaints.
-- Returns the number of buffs seeded.
function Timers.RehydrateFromStore()
    if not (ns.Store and ns.Store.GetTimers) then return 0 end
    local logs = ns.Store.GetTimers().logs or {}
    local t = now()
    local seeded = 0
    for buffKey, logKey in pairs(STORE_LOG_KEY) do
        local list = logs[logKey]
        if list and list[1] then
            local newest = list[1]
            local epoch = newest.epoch or 0
            local cd = CD[buffKey]
            -- Ignore entries older than a full CD (no live countdown to show).
            if epoch > 0 and cd and (t - epoch) < cd then
                local s = stateOf(buffKey)
                if newest.killed then
                    s.killedAt = math.max(s.killedAt or 0, epoch)
                else
                    s.lastPop = math.max(s.lastPop or 0, epoch)
                end
                s.trust = s.trust or newest.trust or "local"
                seeded = seeded + 1
                ns:Fire("TIMER_UPDATED", buffKey)
            end
        end
    end
    return seeded
end

-- Re-seed live CD state + warnings after a bulk store refresh (e.g. /nexus
-- import fired STORE_REFRESHED). Without this, imported pop logs never populated
-- live timer state and the Timers tab showed "no data" (item 39).
function Timers.OnStoreRefreshed()
    Timers.RehydrateFromStore()
    for i = 1, #WARNED_BUFFS do
        if scheduleWarnings then scheduleWarnings(WARNED_BUFFS[i]) end
    end
end

----------------------------------------------------------------------
-- Weekly reset integration
----------------------------------------------------------------------

-- Run the store's weekly sweep; on a wipe, clear in-memory timer state and
-- notify the UI. Called at init and by the 5-min ticker.
function Timers.CheckWeeklyReset()
    if not (ns.Store and ns.Store.WeeklyResetSweep) then return false end
    local wiped = ns.Store.WeeklyResetSweep()
    if wiped then
        Timers.state = {}
        Timers._warnGen = {}
        for i = 1, #Timers.BUFF_KEYS do
            ns:Fire("TIMER_UPDATED", Timers.BUFF_KEYS[i])
        end
        for kind, list in pairs(Timers.NODES) do
            for i = 1, #list do ns:Fire("NODE_UPDATED", kind .. i) end
        end
    end
    return wiped
end

----------------------------------------------------------------------
-- Mesh handoff (soft-guarded). Transport lives in mesh.lua (parallel
-- wave); this module owns the election logic and calls documented entry
-- points. The mesh stubs/implements ns.Mesh.*; we implement ns.Timers.*
-- inbound entry points it invokes.
----------------------------------------------------------------------

-- Snapshot of merged timer data for the broadcaster / bulk sync.
function Timers.GetSnapshot()
    local snap = { buffs = {}, flower = {}, tuber = {}, at = now() }
    for i = 1, #Timers.BUFF_KEYS do
        local k = Timers.BUFF_KEYS[i]
        local s = Timers.state[k]
        if s then
            -- Wire key stays `lastKilled` for peer compatibility (see the state
            -- comment); it carries our `killedAt` respawn stamp.
            snap.buffs[k] = { lastPop = s.lastPop, lastKilled = s.killedAt, trust = s.trust }
        end
    end
    local flower = nodePopTable("flower")
    local tuber  = nodePopTable("tuber")
    if flower then for i = 1, 10 do snap.flower[i] = flower[i] end end
    if tuber  then for i = 1, 6  do snap.tuber[i]  = tuber[i]  end end
    return snap
end

-- Apply an inbound merged snapshot (from a peer / broadcaster). Everything
-- routes through Record/MarkNode so trust + false-positive gates still hold.
function Timers.ApplySnapshot(snap, trust)
    if type(snap) ~= "table" then return end
    trust = trust or "mesh"
    if trust == "mesh" then noteFreshness("nexus") end
    if snap.buffs then
        for k, b in pairs(snap.buffs) do
            if b.lastKilled and b.lastKilled > 0 then
                Timers.Record(k, b.lastKilled, trust, "mesh", "killed")
            end
            if b.lastPop and b.lastPop > 0 then
                Timers.Record(k, b.lastPop, trust, "mesh", "pop")
            end
        end
    end
    if snap.flower then for i, e in pairs(snap.flower) do Timers.MarkNode("flower", i, e, trust) end end
    if snap.tuber  then for i, e in pairs(snap.tuber)  do Timers.MarkNode("tuber",  i, e, trust) end end
end

-- Inbound single-timer event from the mesh (peer relay). trust "mesh".
function Timers.OnMeshTimer(buffKey, epoch, kind, meta)
    noteFreshness("nexus")
    Timers.Record(buffKey, epoch, "mesh", (meta and meta.who) or "mesh", kind or "pop",
                  meta and meta.zone)
end

-- Inbound pull event from the mesh with a 10s relay-age gate (spec).
function Timers.OnMeshPull(buffKey, epoch, duration, zone, meta)
    noteFreshness("nexus")
    local age = now() - (epoch or now())
    if age > 10 then return end   -- stale relayed pull, drop
    Timers.Record(buffKey, epoch or now(), "mesh", (meta and meta.who) or "mesh", "pop",
                  zone, duration)
end

----------------------------------------------------------------------
-- ShadowNetwork passive ingest entry points  [RECEIVE-ONLY]
--
-- snbridge.lua owns the decode chain; it hands us already-translated buff
-- events here. Trust tag "sn" sits below mesh and above nwb/dbm. These mirror
-- OnMeshTimer/OnMeshPull but stamp snPassive freshness and route through the
-- same Record/false-positive/dedup gates. We NEVER transmit on SN prefixes;
-- this is a one-way data intake only.
----------------------------------------------------------------------

function Timers.OnSNTimer(buffKey, epoch, kind, meta)
    noteFreshness("snPassive")
    if not CD[buffKey] then return end   -- unknown/untranslatable buff: skip
    Timers.Record(buffKey, epoch or now(), "sn", (meta and meta.who) or "SN",
                  kind or "pop", meta and meta.zone)
end

function Timers.OnSNPull(buffKey, epoch, duration, zone, meta)
    noteFreshness("snPassive")
    if not CD[buffKey] then return end
    local age = now() - (epoch or now())
    if age > 10 then return end   -- stale relayed pull, drop
    Timers.Record(buffKey, epoch or now(), "sn", (meta and meta.who) or "SN", "pop",
                  zone, duration)
end

-- Guild-broadcaster election: the lowest account id among online mesh
-- members in our guild broadcasts merged data (<=1/min). Election here;
-- transport via ns.Mesh.
function Timers.IsGuildBroadcaster()
    local myID = ns.GetAccountID and ns:GetAccountID() or ""
    if myID == "" then return false end
    local myNum = tonumber(myID)
    if not myNum then return false end
    -- Ask the mesh for the online roster; absent mesh => trivially us.
    if not (ns.Mesh and ns.Mesh.GetGuildRoster) then
        return true
    end
    local roster = ns.Mesh.GetGuildRoster()
    if type(roster) ~= "table" then return true end
    for i = 1, #roster do
        local otherID = tonumber(roster[i].accountID or roster[i])
        if otherID and otherID < myNum then
            return false   -- someone lower-id outranks us
        end
    end
    return true
end

Timers._lastBroadcast = 0

maybeBroadcast = function()
    if not (ns.Mesh and ns.Mesh.BroadcastTimers) then return end
    if not Timers.IsGuildBroadcaster() then return end
    local t = now()
    if (t - (Timers._lastBroadcast or 0)) < 60 then return end   -- <=1/min
    Timers._lastBroadcast = t
    ns:SafeCall(ns.Mesh.BroadcastTimers, Timers.GetSnapshot())
end
Timers.MaybeBroadcast = maybeBroadcast

----------------------------------------------------------------------
-- Login data requests (cooldown-gated)
--
-- On login we ask mesh peers for timer data (our own prefix, via the
-- handoff). NWB data arrives passively (we never transmit on the NWB
-- prefix); a periodic re-request re-arms the mesh ask if nothing has been
-- seen yet. All cooldown-gated to avoid storms.
----------------------------------------------------------------------

Timers._lastMeshRequest = 0
local MESH_REQUEST_CD = 30          -- seconds between login/auto mesh requests
local NWB_REREQUEST_INTERVAL = 120  -- seconds; re-ask if no NWB seen yet

-- Login / periodic auto-request (30s gate, separate from the button cooldown).
function Timers.RequestTimerData()
    local t = now()
    if (t - (Timers._lastMeshRequest or 0)) < MESH_REQUEST_CD then return end
    Timers._lastMeshRequest = t
    if ns.Mesh and ns.Mesh.RequestTimers then
        ns:SafeCall(ns.Mesh.RequestTimers)
    end
end

----------------------------------------------------------------------
-- Button-callable data requests (published surface for the UI wave)
--
--   ns.Timers.RequestNexusData()  -> ok, cooldownRemaining
--        Asks mesh peers for a merged timer snapshot (60s cooldown). Peers
--        reply via Mesh.SendTimers -> our Timers.ApplySnapshot. ok=false with
--        the seconds remaining while cooling down.
--   ns.Timers.RequestNWBData()    -> boolean
--        Sends the NovaWorldBuffs guild data request (60s cooldown). Returns
--        false (no-op) when not in a guild, when NWB is absent, or on cooldown.
--        The existing NWB ingest handles the reply.
--   ns.Timers.GetSourceFreshness() -> { nexus, nwb, snPassive }  (epochs)
----------------------------------------------------------------------

Timers._lastNexusRequest = 0
local NEXUS_REQUEST_CD = 60

function Timers.RequestNexusData()
    local t = now()
    local since = t - (Timers._lastNexusRequest or 0)
    if since < NEXUS_REQUEST_CD then
        return false, NEXUS_REQUEST_CD - since
    end
    Timers._lastNexusRequest = t
    if ns.Mesh and ns.Mesh.RequestTimers then
        ns:SafeCall(ns.Mesh.RequestTimers)
    end
    return true, 0
end

-- NWB protocol version we advertise. Must be >= 2.75 to clear NWB's classic-era
-- gate so peers reach the modern requestData handler and reply. This is the
-- documented community-interop protocol number, not an identity claim.
local NWB_REQ_VERSION = "2.75"
Timers._lastNWBRequest = 0
local NWB_REQUEST_CD = 60

-- Build the encoded NWB "requestData" wire exactly as NWB 3.39 does:
--   inner : LibSerialize:Serialize({})   (we share no NWB-format data; empty)
--   text  : "requestData <ver> <level> <ktoken> <innerData>"
--   outer : LibSerialize:Serialize(text)
--         -> LibDeflate:CompressDeflate(level 9)
--         -> LibDeflate:EncodeForWoWAddonChannel
-- Returns the encoded string, or nil when the libs are unavailable.
-- Build the plaintext NWB wire text (before serialize/deflate/encode). Pure
-- string assembly so self-tests can validate the field layout without touching
-- the deflate pipeline. `innerData` is the already-serialized field-5 payload.
function Timers.BuildNWBText(innerData)
    local level = (UnitLevel and UnitLevel("player")) or 60
    local st = (GetServerTime and GetServerTime()) or 0
    -- NWB's coarse server-time token: (serverTime+1998) stringified, last 3 chopped.
    local ktoken = tonumber(string.sub(tostring(st + 1998), 1, -4)) or 0
    return "requestData " .. NWB_REQ_VERSION .. " " .. tostring(level)
           .. " " .. tostring(ktoken) .. " " .. (innerData or "")
end

function Timers.BuildNWBRequest()
    local nwb = Timers._nwb
    local LS, LD = nwb.libSerialize, nwb.deflate
    if not (LS and LD) then return nil end
    local dataStr = LS:Serialize({})
    local text = Timers.BuildNWBText(dataStr)
    local outer = LS:Serialize(text)
    local comp = LD:CompressDeflate(outer, { level = 9 })
    if not comp then return nil end
    return LD:EncodeForWoWAddonChannel(comp)
end

function Timers.RequestNWBData()
    if not (IsInGuild and IsInGuild()) then return false end
    local nwb = Timers._nwb
    if not (nwb and nwb.ready and nwb.obj and nwb.obj.SendCommMessage) then return false end
    local t = now()
    if (t - (Timers._lastNWBRequest or 0)) < NWB_REQUEST_CD then return false end
    local enc = Timers.BuildNWBRequest()
    if not enc then return false end
    Timers._lastNWBRequest = t
    Timers._nwbStats.requestsSent = Timers._nwbStats.requestsSent + 1
    Timers._nwbStats.lastRequestAt = t
    Timers._nwbStats.lastRequestBytes = #enc
    -- Authorized NWB interop transmit (AceComm, GUILD). Never an SN prefix.
    ns:SafeCall(function() nwb.obj:SendCommMessage("NWB", enc, "GUILD") end)
    return true
end

function Timers.GetSourceFreshness()
    local f = Timers._freshness
    return { nexus = f.nexus, nwb = f.nwb, snPassive = f.snPassive }
end

local function startNWBRewatch()
    if not (C_Timer and C_Timer.NewTicker) then return end
    Timers._sawNWB = false
    C_Timer.NewTicker(NWB_REREQUEST_INTERVAL, function()
        if not Timers._sawNWB then
            Timers.RequestTimerData()
        end
    end)
end

----------------------------------------------------------------------
-- Debug dump: /dsn debug timers
----------------------------------------------------------------------

local function fmtRemaining(sec)
    sec = math.max(0, math.floor(sec or 0))
    local m = math.floor(sec / 60)
    local s = sec % 60
    return string.format("%d:%02d", m, s)
end

function Timers.DebugDump()
    ns:Print("timer states:")
    local t = now()
    for i = 1, #Timers.BUFF_KEYS do
        local k = Timers.BUFF_KEYS[i]
        local s = Timers.state[k]
        local st = Timers.BuffStatus(k, t)
        if s and st.state ~= "nodata" then
            local status =
                  (st.state == "cd")     and ("CD " .. fmtRemaining(st.remaining))
               or (st.state == "killed") and ("NPC KILLED, respawn " .. fmtRemaining(st.remaining))
               or "READY"
            ns:Print(string.format("  %-5s %s  trust=%s conf=%s",
                k, status, tostring(s.trust), tostring(s.confirmed)))
        else
            ns:Print(string.format("  %-5s (no data)", k))
        end
    end
    ns:Print("felwood nodes:")
    for _, kind in ipairs({ "flower", "tuber" }) do
        local pops = nodePopTable(kind)
        local count = (kind == "flower") and 10 or 6
        for i = 1, count do
            local st = Timers.NodeState(pops and pops[i] or 0, t, NODE_RESPAWN)
            if st.state ~= "unknown" then
                ns:Print(string.format("  %s%d %s %s", kind, i, st.state,
                    st.state == "down" and fmtRemaining(st.remaining) or ""))
            end
        end
    end
    ns:Print("broadcaster=" .. tostring(Timers.IsGuildBroadcaster()) ..
             " nwbIngest=" .. tostring(Timers._nwb and Timers._nwb.ready == true))
end

-- /nexus debug nwb — NWB ingest self-diagnosis (item 40). Prints the last
-- request, raw messages heard (by channel), per-stage drop counts + reasons,
-- decode serializer path, and the last successfully-ingested command + fields.
function Timers.NWBDebugDump()
    local s = Timers._nwbStats
    local nwb = Timers._nwb
    ns:Print("nwb ingest: ready=" .. tostring(nwb and nwb.ready == true)
        .. " | libSerialize=" .. tostring(nwb and nwb.libSerialize ~= nil)
        .. " aceSerializer=" .. tostring(nwb and nwb.serializer ~= nil)
        .. " deflate=" .. tostring(nwb and nwb.deflate ~= nil)
        .. " | inGuild=" .. tostring(IsInGuild and IsInGuild() == true))
    ns:Print(string.format("  request: sent=%d lastAt=%d lastBytes=%d",
        s.requestsSent, s.lastRequestAt, s.lastRequestBytes))
    local chans = {}
    for ch, n in pairs(s.byChannel) do chans[#chans + 1] = ch .. "=" .. n end
    ns:Print(string.format("  heard: total=%d lastAt=%d [%s]",
        s.heard, s.lastHeardAt, table.concat(chans, " ")))
    ns:Print(string.format("  drops: notReady=%d chanDecode=%d decompress=%d deserialize=%d notString=%d versionGate=%d emptyData=%d payloadNotTable=%d",
        s.drop.notReady, s.drop.channelDecode, s.drop.decompress, s.drop.deserialize,
        s.drop.notString, s.drop.versionGate, s.drop.emptyData, s.drop.payloadNotTable))
    ns:Print(string.format("  decode: libSerialize=%d aceSerializer=%d",
        s.serializerPath.libSerialize, s.serializerPath.aceSerializer))
    local applied = s.lastApplied or {}
    local af = {}
    for k, v in pairs(applied) do af[#af + 1] = k .. "=" .. tostring(v) end
    ns:Print(string.format("  ingested=%d lastCmd=%s (at %d) lastApplied=[%s]",
        s.ingested, tostring(s.lastCmd), s.lastCmdAt, table.concat(af, " ")))
    ns:Print("  NOTE: NWB never transmits ZG/Zandalar; layered realms nest timers"
        .. " under a layers map (handled). Reassembly is AceComm's, shared-instance.")
end

-- /nexus debug pulls — pull-window self-diagnosis. For each pull buff and yell
-- stage: the authoritative spec constant, the currently-effective window and its
-- source (override > spec), and the DRIFT between the spec constant and the
-- median of drops actually witnessed on this client. Also lists pending pulls.
function Timers.PullsDebugDump()
    ns:Print("pull windows (effective = override > spec constant; observations are drift only):")
    for i = 1, #Timers.BUFF_KEYS do
        local k = Timers.BUFF_KEYS[i]
        if PULL_WINDOWS[k] then
            for yn = 1, 2 do
                local window, source = Timers.EffectivePullWindow(k, yn)
                local obs, n = Timers.ObservedPullMedian(k, yn)
                local spec = PULL_WINDOWS[k][yn]
                local drift = (obs and type(spec) == "number")
                    and string.format("%+.1fs", obs - spec) or "-"
                ns:Print(string.format(
                    "  %-4s yell%d  window=%s (%s)  spec=%s  observed=%s n=%d  drift=%s",
                    k, yn,
                    window and tostring(window) or "no bar", source,
                    (spec == false) and "no bar" or tostring(spec),
                    obs and string.format("%.1f", obs) or "-", n, drift))
            end
        end
    end
    local pend = {}
    for k, t in pairs(Timers._pendingPull) do
        local stages = {}
        for yn = 1, 2 do if t[yn] then stages[#stages + 1] = "y" .. yn end end
        pend[#pend + 1] = k .. "(" .. table.concat(stages, "+") .. ")"
    end
    ns:Print("  pending pulls: " .. (next(Timers._pendingPull) and table.concat(pend, " ") or "(none)"))
    ns:Print("  NOTE: spec constants are AUTHORITATIVE — observations measure drift"
        .. " only. Set timerSettings.pullWindows[buff] to override a constant.")
end

----------------------------------------------------------------------
-- Detector handles exposed for the self-tests (and for `/dsn debug`).
-- These are the real event handlers, so the tests drive exactly the code the
-- game drives — no parallel test-only path.
----------------------------------------------------------------------

Timers._onMonsterYell    = onMonsterYell
Timers._onCombatLog      = onCombatLog
Timers._onSpellSucceeded = onSpellSucceeded
Timers._onQuestTurnedIn  = onQuestTurnedIn

----------------------------------------------------------------------
-- Self-tests (pure Lua; run via /dsn debug selftest)
----------------------------------------------------------------------

local function tcheck(cond, msg, fails)
    if not cond then fails[#fails + 1] = msg end
    return cond
end

-- CD derivation: anchor + CD boundary, ready flip, kill reset.
local function testCDDerivation(fails)
    local a = 1000000000
    local info = Timers.ComputeCD("rend", a, a + 1)
    tcheck(info.onCD == true, "rend should be on CD 1s after pop", fails)
    tcheck(info.nextAt == a + CD.rend, "rend nextAt = anchor + 3h", fails)
    local info2 = Timers.ComputeCD("rend", a, a + CD.rend)
    tcheck(info2.ready == true, "rend ready exactly at anchor+CD", fails)
    local info3 = Timers.ComputeCD("onyH", a, a + CD.onyH - 1)
    tcheck(info3.onCD == true and info3.ready == false, "onyH on CD just before ready", fails)
end

-- False-positive gate: within-CD pop rejected; a kill does NOT anchor the CD
-- (A3.1), so a pop after a kill is judged only against the last real pop.
local function testFalsePositive(fails)
    Timers.state = {}
    local a = 1500000000
    local ok1 = Timers.Record("rend", a, "local", "t1", "pop")
    tcheck(ok1 == true, "first rend pop applied", fails)
    local ok2 = Timers.Record("rend", a + 3600, "local", "t2", "pop")
    tcheck(ok2 == false, "rend pop within CD rejected as false positive", fails)
    -- A kill is always accepted (it is a respawn stamp, not a pop).
    local ok3 = Timers.Record("onyH", a + 1800, "local", "t3", "killed")
    tcheck(ok3 == true, "kill entry always applied", fails)
    tcheck((Timers.state.onyH.lastPop or 0) == 0, "kill does not set the pop anchor", fails)
    tcheck(Timers.state.onyH.killedAt == a + 1800, "kill stamps killedAt", fails)
    -- A pop right after a kill is NOT gated by the kill (a kill starts no CD).
    local ok4 = Timers.Record("onyH", a + 1801, "local", "t4", "pop")
    tcheck(ok4 == true, "a pop after a kill is accepted (kill starts no CD)", fails)
    -- A pop a full CD past the real pop anchor is accepted.
    local ok5 = Timers.Record("rend", a + CD.rend + 1, "local", "t5", "pop")
    tcheck(ok5 == true, "pop a full CD past the pop anchor accepted", fails)
    Timers.state = {}
end

-- A3: announcer death = 360s RESPAWN model, not a 6h cooldown anchor.
local function testAnnouncerKill(fails)
    Timers.state = {}
    local t = 1600000000

    -- (a) a fresh kill reads as "killed" with a shrinking respawn remaining.
    Timers.Record("onyH", t, "local", "Overlord Runthak", "killed")
    local st = Timers.BuffStatus("onyH", t + 60)
    tcheck(st.state == "killed", "fresh kill reads as killed, not cd", fails)
    tcheck(math.abs(st.remaining - 300) < 0.5,
        "killed remaining = 360 - elapsed (300s at t+60)", fails)

    -- (b) once the 360s respawn elapses the buff is immediately can-pop --
    -- emphatically NOT a 6h cooldown (the exact inversion A3.1 describes).
    local after = Timers.BuffStatus("onyH", t + Timers.ANNOUNCER_RESPAWN + 1)
    tcheck(after.state == "canpop", "kill -> canpop once the 360s respawn elapses", fails)
    tcheck(after.remaining == 0, "canpop has no remaining", fails)
    local wrong = Timers.ComputeCD("onyH", anchorEpoch(Timers.state.onyH), t + 600)
    tcheck(wrong.ready == true, "kill excluded from ComputeCD's anchor", fails)

    -- (c) a POP still yields a real cooldown.
    Timers.state = {}
    Timers.Record("onyH", t, "local", "yeller", "pop")
    local cdst = Timers.BuffStatus("onyH", t + 60)
    tcheck(cdst.state == "cd" and cdst.remaining > 0, "a pop still reads as cd", fails)

    -- (d) a kill NEWER than the newest pop wins the readout.
    Timers.Record("onyH", t + 120, "local", "Overlord Runthak", "killed")
    tcheck(Timers.BuffStatus("onyH", t + 180).state == "killed",
        "kill newer than the newest pop wins", fails)
    -- ...and a pop newer than the kill takes it back.
    Timers.state.onyH.lastPop = t + 300
    tcheck(Timers.BuffStatus("onyH", t + 360).state == "cd",
        "pop newer than the kill restores the cd readout", fails)

    -- (e) CD warnings are suppressed while the newest event is a kill (A3.3).
    Timers.state = {}
    local fired = {}
    ns:On("CD_WARNING", function(buffKey, kind) fired[#fired + 1] = buffKey .. ":" .. kind end)
    local realAfter = C_Timer and C_Timer.After
    local armed = 0
    if C_Timer then C_Timer.After = function() armed = armed + 1 end end
    Timers.state = {}
    Timers.Record("onyH", now() - (CD.onyH - 120), "local", "yeller", "pop")
    local armedAfterPop = armed
    tcheck(armedAfterPop > 0, "a pop near the CD edge arms warnings", fails)
    Timers.Record("onyH", now(), "local", "Overlord Runthak", "killed")
    tcheck(armed == armedAfterPop, "a kill arms NO further CD warnings (A3.3)", fails)
    if C_Timer then C_Timer.After = realAfter end

    -- (f) the snapshot wire key stays `lastKilled` for peer compatibility.
    Timers.state = {}
    Timers.Record("onyA", t, "local", "Major Mattingly", "killed")
    local snap = Timers.GetSnapshot()
    tcheck(snap.buffs.onyA and snap.buffs.onyA.lastKilled == t,
        "snapshot still exports the kill as lastKilled", fails)

    -- (g) capital gate narrowed to the two announcer capitals (A3.2).
    tcheck(Timers._capitalZones["orgrimmar"] and Timers._capitalZones["stormwind city"]
        and Timers._capitalZones["stormwind"], "announcer capitals accepted", fails)
    tcheck(not Timers._capitalZones["thunder bluff"] and not Timers._capitalZones["ironforge"]
        and not Timers._capitalZones["undercity"] and not Timers._capitalZones["darnassus"],
        "non-announcer capitals rejected", fails)
    -- Spec announcer ids resolve, including the two Nef announcers.
    tcheck(Timers._announcerBuffFor(14392) == "onyH", "14392 -> onyH", fails)
    tcheck(Timers._announcerBuffFor(14394) == "onyA", "14394 -> onyA", fails)
    tcheck(Timers._announcerBuffFor(14720) == "nefH", "14720 -> nefH", fails)
    tcheck(Timers._announcerBuffFor(14721) == "nefA", "14721 -> nefA", fails)
    tcheck(Timers._announcerBuffFor(nil, "Field Marshal Stonebridge") == "nefA",
        "Stonebridge resolves as a Nef-A announcer by name", fails)
    -- Thrall is a yeller, never an announcer whose death means anything.
    tcheck(Timers._announcerBuffFor(nil, "Thrall") == nil,
        "Thrall is not an announcer death target", fails)

    Timers.state = {}
end

-- Pull recency gate (reload false-positive fix). A fresh pop raises
-- PULL_DETECTED with ~full window; a late pop raises it with a reduced
-- remaining window; an hours-old anchor still APPLIES (TIMER_UPDATED fires,
-- anchor set) but raises NO pull bar. An explicit pullDuration is honored as
-- the window. Captures both events off the callback bus.
local function testPullRecencyGate(fails)
    local cap = { pull = nil, timerUpdated = {} }
    ns:On("PULL_DETECTED", function(buffKey, duration)
        cap.pull = { buff = buffKey, duration = duration }
    end)
    ns:On("TIMER_UPDATED", function(buffKey) cap.timerUpdated[buffKey] = true end)

    local t = now()

    -- (a) fresh pop (epoch == now) -> PULL_DETECTED with the ~full spec window
    -- for the stage (ZG stage 1 = 50.5s).
    Timers.state = {}; cap.pull = nil; cap.timerUpdated = {}
    Timers.Record("zg", t, "local", "live", "pop", nil, nil, 1)
    tcheck(cap.pull ~= nil and cap.pull.buff == "zg", "fresh pop raises PULL_DETECTED", fails)
    tcheck(cap.pull and math.abs(cap.pull.duration - 50.5) <= 1,
        "fresh pop shows the ~full spec window", fails)

    -- (b) pop heard 20s late -> PULL_DETECTED with reduced remaining window.
    Timers.state = {}; cap.pull = nil
    Timers.Record("zg", t - 20, "local", "late", "pop", nil, nil, 1)
    tcheck(cap.pull ~= nil, "late pop still raises PULL_DETECTED", fails)
    tcheck(cap.pull and math.abs(cap.pull.duration - (50.5 - 20)) <= 1,
        "late pop shows reduced remaining window (~window-20)", fails)

    -- (c) hours-old anchor -> applied + TIMER_UPDATED, but NO pull bar.
    Timers.state = {}; cap.pull = nil; cap.timerUpdated = {}
    local ok = Timers.Record("nefH", t - 3600, "mesh", "peer", "pop")
    tcheck(ok == true, "stale anchor still applied", fails)
    tcheck(cap.timerUpdated["nefH"] == true, "stale anchor fires TIMER_UPDATED", fails)
    tcheck(cap.pull == nil, "stale anchor does NOT raise PULL_DETECTED (reload fix)", fails)

    -- (d) explicit pullDuration is used as the fresh window (mesh/SN pull relay).
    Timers.state = {}; cap.pull = nil
    Timers.Record("zg", t, "sn", "SN", "pop", nil, 25)
    tcheck(cap.pull ~= nil and math.abs(cap.pull.duration - 25) <= 1,
        "explicit pullDuration used as the fresh window", fails)

    -- (e) an announcer KILL raises no bar at all (A3.1): it is a respawn event,
    -- not an incoming buff.
    Timers.state = {}; cap.pull = nil
    Timers.Record("onyH", t, "local", "Overlord Runthak", "killed")
    tcheck(cap.pull == nil, "a kill raises NO pull bar", fails)

    -- (f) opts.noPull records without barring (the local yell detector's path).
    Timers.state = {}; cap.pull = nil
    Timers.Record("onyH", t, "local", "yeller", "pop", nil, nil, 1, { noPull = true })
    tcheck(cap.pull == nil, "opts.noPull suppresses the bar", fails)
    tcheck((Timers.state.onyH.lastPop or 0) > 0, "opts.noPull still records the pop", fails)

    Timers.state = {}
end

-- A2: the explicit (npc, text) -> (buff, stage) yell table.
-- Drives the REAL CHAT_MSG_MONSTER_YELL handler end to end and asserts the
-- resulting bars, pop records and record KINDs.
local function testYellTable(fails)
    -- Capture every bar this suite raises.
    local bars = {}
    ns:On("PULL_DETECTED", function(buffKey, duration, trust, zone)
        bars[#bars + 1] = { buff = buffKey, dur = duration, trust = trust, zone = zone }
    end)
    local function yell(text, npc)
        bars = {}
        Timers.state = {}
        Timers._handinStash = {}
        Timers._onMonsterYell("CHAT_MSG_MONSTER_YELL", text, npc)
        return bars
    end
    local function barFor(list, zone)
        for i = 1, #list do
            if (not zone) or list[i].zone == zone then return list[i] end
        end
        return nil
    end

    local savedFaction = _G.UnitFactionGroup
    _G.UnitFactionGroup = function() return "Horde" end

    -- (1) Rend stage 1: ONE pop recorded as a POP (never a kill) plus the two
    -- hard bars, Orgrimmar 6s and Barrens 17s (A2.1).
    local b = yell("The mighty Rend Blackhand, has fallen!", "Thrall")
    tcheck(#b == 2, "Rend yell 1 raises exactly two bars", fails)
    local org, barrens = barFor(b, "Orgrimmar"), barFor(b, "Barrens")
    tcheck(org and math.abs(org.dur - 6) <= 1, "Rend -> Orgrimmar bar is 6s", fails)
    tcheck(barrens and math.abs(barrens.dur - 17) <= 1, "Rend -> Barrens bar is 17s", fails)
    tcheck((Timers.state.rend and Timers.state.rend.lastPop or 0) > 0,
        "Rend yell 1 records a POP anchor", fails)
    tcheck((Timers.state.rend and Timers.state.rend.killedAt or 0) == 0,
        "Rend yell 1 is NOT recorded as a kill (A2.1)", fails)

    -- Herald-only Rend takes the SHORT 6s Barrens variant (A2.9).
    b = yell("The mighty Rend Blackhand, has fallen!", "Herald of Thrall")
    local hb = barFor(b, "Barrens")
    tcheck(hb and math.abs(hb.dur - 6) <= 1, "Herald Rend -> Barrens bar is 6s", fails)

    -- (2) Onyxia Horde stage 1 -> pop + 14.5s bar (A2.2).
    b = yell("Onyxia, has been slain!", "Overlord Runthak")
    tcheck(#b == 1 and math.abs(b[1].dur - 14.5) <= 1, "Ony-H yell 1 bar is 14.5s", fails)
    tcheck((Timers.state.onyH and Timers.state.onyH.lastPop or 0) > 0, "Ony-H pop recorded", fails)
    tcheck((Timers.state.onyH and Timers.state.onyH.killedAt or 0) == 0,
        "Ony-H yell is not a kill", fails)

    -- (3) Onyxia Alliance stage 1 "history has been made" -> 15s (A2.3): the
    -- exact line the old keyword classifier matched nothing in and defaulted to
    -- stage 2 with a 40s bar.
    b = yell("Onyxia is dead! Today, history has been made!", "Major Mattingly")
    tcheck(#b == 1 and math.abs(b[1].dur - 15) <= 1,
        "Ally Ony 'history has been made' -> 15s bar", fails)
    tcheck((Timers.state.onyA and Timers.state.onyA.lastPop or 0) > 0, "Ony-A pop recorded", fails)

    -- (4) Nefarian, both factions and both Alliance announcers.
    b = yell("NEFARIAN IS SLAIN! The Horde is victorious!", "High Overlord Saurfang")
    tcheck(#b == 1 and math.abs(b[1].dur - 15) <= 1, "Nef-H yell 1 bar is 15s", fails)
    b = yell("People of Stormwind, the Lord of Blackrock is slain!", "Field Marshal Afrasiabi")
    tcheck(#b == 1 and math.abs(b[1].dur - 12) <= 1, "Nef-A yell 1 bar is 12s", fails)
    -- A2.5: Stonebridge was missing entirely, so Alliance lost every Nef drop
    -- he announced.
    b = yell("People of Stormwind, the Lord of Blackrock is slain!", "Field Marshal Stonebridge")
    tcheck(#b == 1 and math.abs(b[1].dur - 12) <= 1, "Stonebridge Nef-A bar is 12s", fails)
    tcheck((Timers.state.nefA and Timers.state.nefA.lastPop or 0) > 0,
        "Stonebridge records a Nef-A pop (A2.5)", fails)

    -- (5) Stage 2 is a COMPLETE no-op for Rend / Ony / Nef (A2.4): no bar and,
    -- critically, no second spurious pop.
    local y2 = {
        { "Be bathed in my power!",                   "Thrall" },
        { "Be lifted by the rallying cry!",           "Overlord Runthak" },
        { "Onyxia's head hangs from the arches!",     "Major Mattingly" },
        { "Revel in his rallying cry!",               "High Overlord Saurfang" },
        { "Revel in the rallying cry!",               "Field Marshal Afrasiabi" },
    }
    for i = 1, #y2 do
        b = yell(y2[i][1], y2[i][2])
        tcheck(#b == 0, "yell 2 raises no bar: " .. y2[i][2], fails)
        tcheck(next(Timers.state) == nil, "yell 2 records nothing: " .. y2[i][2], fails)
    end

    -- (6) Zandalar: stage 1 = 50.5s + a pop; stage 2 is the documented exception
    -- that DOES bar (29s) while still recording nothing (spec §10.7).
    b = yell("The Blood God Hakkar is no more!", "Zandalarian Emissary")
    tcheck(#b == 1 and math.abs(b[1].dur - 50.5) <= 1, "ZG yell 1 bar is 50.5s", fails)
    b = yell("Now, only one step remains!", "Molthor")
    tcheck(#b == 1 and math.abs(b[1].dur - 50.5) <= 1, "ZG Molthor say -> stage 1, 50.5s", fails)
    b = yell("Begin the ritual!", "Molthor")
    tcheck(#b == 1 and math.abs(b[1].dur - 29) <= 1, "ZG yell 2 DOES bar, at 29s", fails)
    tcheck(next(Timers.state) == nil, "ZG yell 2 records no pop", fails)

    -- (7) Sunken Temple reuses the ZG NPCs — those lines must not fire (A2.6).
    b = yell("Begin the ritual in the Temple of Atal'Hakkar!", "Molthor")
    tcheck(#b == 0, "ZG line mentioning Temple of Atal is excluded (A2.6)", fails)
    tcheck(Timers.MatchYell("The Blood God stirs in the Temple of Atal'Hakkar", "Zandalarian Emissary") == nil,
        "Atal exclusion applies to the Emissary line too", fails)

    -- (8) An unrecognised line from a KNOWN announcer is ignored outright --
    -- no default stage, no invented pop. This is the core A2.4 regression gate.
    b = yell("Some unrelated flavour text nobody parsed.", "Overlord Runthak")
    tcheck(#b == 0 and next(Timers.state) == nil,
        "unknown text from a known announcer is ignored (no default stage)", fails)
    tcheck(Timers.MatchYell("anything at all", "Some Random Mob") == nil,
        "unknown announcer never matches", fails)

    -- (9) Fallen Hero of the Horde: alert only, zone-gated, no bar, no record.
    local savedZone = _G.GetRealZoneText
    _G.GetRealZoneText = function() return "Swamp of Sorrows" end
    Timers._lastNotice = nil
    b = yell("My fury is released!", "Fallen Hero of the Horde")
    tcheck(#b == 0 and next(Timers.state) == nil, "Battle Shout say raises no bar / no pop", fails)
    tcheck(Timers._lastNotice and Timers._lastNotice.buff == "battleShout",
        "Battle Shout say alerts", fails)
    _G.GetRealZoneText = function() return "Orgrimmar" end
    Timers._lastNotice = nil
    yell("My fury is released!", "Fallen Hero of the Horde")
    tcheck(Timers._lastNotice == nil, "Battle Shout say is gated to Swamp of Sorrows", fails)
    _G.GetRealZoneText = savedZone

    -- (10) Alliance-side Rend: name-only detection, a pop, a vague notice, and
    -- deliberately NO bar; deduped at 60s (A2.7).
    _G.UnitFactionGroup = function() return "Alliance" end
    Timers._lastAllyRendAt = 0
    Timers._lastNotice = nil
    b = yell("Kek'lek Rend'aggro zug zug!", "Thrall")   -- scrambled cross-faction text
    tcheck(#b == 0, "Alliance Rend raises NO pull bar (A2.7)", fails)
    tcheck((Timers.state.rend and Timers.state.rend.lastPop or 0) > 0,
        "Alliance Rend still logs the pop", fails)
    tcheck(Timers._lastNotice ~= nil and Timers._lastNotice.buff == "rend",
        "Alliance Rend emits the vague notification", fails)
    -- Dedup: a second scrambled yell inside 60s is swallowed.
    local firstAt = Timers._lastAllyRendAt
    tcheck(Timers.OnAllianceRendYell("Thrall", firstAt + 30) == false,
        "second Alliance Rend yell within 60s deduped", fails)
    tcheck(Timers.OnAllianceRendYell("Thrall", firstAt + 61) == true,
        "Alliance Rend accepted again past the 60s dedup", fails)
    _G.UnitFactionGroup = savedFaction

    Timers.state = {}
    Timers._handinStash = {}
    Timers._lastAllyRendAt = 0
end

-- A4: quest hand-in is non-anchoring for Rend, CD-suppressed, and ZG pulls.
local function testQuestHandin(fails)
    local bars = {}
    ns:On("PULL_DETECTED", function(buffKey, duration) bars[#bars + 1] = { buff = buffKey, dur = duration } end)
    local function reset() bars = {}; Timers.state = {}; Timers._handinStash = {}; Timers._lastNotice = nil end

    local savedFaction = _G.UnitFactionGroup
    _G.UnitFactionGroup = function() return "Horde" end

    -- (a) A Rend hand-in does NOT anchor: it stashes the handing-in player so
    -- the FOLLOWING yell can attribute the pop (A4.1). A hand-in that never
    -- produces a buff therefore cannot fake a 3h cooldown.
    reset()
    local ok = Timers.OnQuestHandin(4974)
    tcheck(ok == true, "Rend hand-in handled", fails)
    tcheck((Timers.state.rend == nil) or (Timers.state.rend.lastPop or 0) == 0,
        "Rend hand-in does NOT anchor the cooldown (A4.1)", fails)
    tcheck(Timers._handinStash.rend ~= nil, "Rend hand-in stashes the handing-in player", fails)
    tcheck(Timers._lastNotice and Timers._lastNotice.category == "questHandin",
        "hand-in fires a questHandin alert", fails)

    -- ...and the following yell CONSUMES that attribution.
    local who = Timers._handinStash.rend.who
    Timers._onMonsterYell("CHAT_MSG_MONSTER_YELL", "Rend Blackhand, has fallen!", "Thrall")
    tcheck((Timers.state.rend and Timers.state.rend.lastPop or 0) > 0,
        "the yell after a hand-in anchors the pop", fails)
    tcheck(Timers.state.rend.who == who,
        "the yell attributes the pop to the handing-in player", fails)
    tcheck(Timers._handinStash.rend == nil, "the stash is consumed by the yell", fails)

    -- A stash older than 20s is NOT consumed (the yell falls back to the NPC).
    reset()
    Timers._stashHandin("rend", "Staleplayer", now() - 25)
    tcheck(Timers._consumeHandinStash("rend", now()) == nil,
        "a stash older than 20s expires unconsumed", fails)

    -- (b) A hand-in whose buff is already on cooldown is ignored ENTIRELY --
    -- no anchor, no stash, no alert (A4.2).
    reset()
    Timers.Record("onyH", now(), "local", "yeller", "pop")
    Timers._lastNotice = nil
    local ok2, why = Timers.OnQuestHandin(7496)
    tcheck(ok2 == false and why == "on cooldown", "on-CD hand-in is ignored", fails)
    tcheck(Timers._lastNotice == nil, "on-CD hand-in emits no alert (A4.2)", fails)
    -- Rend likewise.
    reset()
    Timers.Record("rend", now(), "local", "yeller", "pop")
    tcheck(Timers.OnQuestHandin(4974) == false, "on-CD Rend hand-in ignored", fails)
    tcheck(Timers._handinStash.rend == nil, "on-CD Rend hand-in does not even stash", fails)

    -- (c) Nef and ZG carry no cooldown and are NEVER suppressed.
    reset()
    Timers.Record("nefH", now(), "local", "yeller", "pop")
    tcheck(Timers.OnQuestHandin(7784) == true, "Nef hand-in never suppressed", fails)

    -- (d) The ZG hand-in starts the 50s stage-1 pull (A4.3).
    reset()
    tcheck(Timers.OnQuestHandin(8183) == true, "ZG hand-in handled", fails)
    tcheck(#bars == 1 and bars[1].buff == "zg" and math.abs(bars[1].dur - 50.5) <= 1,
        "ZG hand-in starts the 50.5s stage-1 pull (A4.3)", fails)

    -- (e) A non-buff quest is not our business.
    reset()
    local okN = Timers.OnQuestHandin(12345)
    tcheck(okN == false, "an unrelated quest hand-in is ignored", fails)

    -- (f) Hand-in ids map to the right FACTION (spec §10.3). These were reversed.
    tcheck(Timers._handinQuest[7491] == "onyA" and Timers._handinQuest[7496] == "onyH",
        "7491 -> Ony Alliance, 7496 -> Ony Horde", fails)
    tcheck(Timers._handinQuest[7782] == "nefA" and Timers._handinQuest[7784] == "nefH",
        "7782 -> Nef Alliance, 7784 -> Nef Horde", fails)
    tcheck(Timers._handinQuest[4974] == "rend" and Timers._handinQuest[8183] == "zg",
        "4974 -> Rend, 8183 -> Zandalar", fails)

    _G.UnitFactionGroup = savedFaction
    reset()
end

-- A5.1 / A5.2: the songflower pick gate.
local function testSongflowerPick(fails)
    if not (ns.Store and ns.Store.GetTimers) then
        fails[#fails + 1] = "store absent for songflower test"; return
    end
    local timers = ns.Store.GetTimers()
    timers.flower, timers.tuber = {}, {}

    -- Stand up a minimal C_Map so the real handler runs unmodified.
    local savedMap = _G.C_Map
    local pos = { x = 0, y = 0 }
    _G.C_Map = {
        GetBestMapForUnit = function() return Timers.FELWOOD_MAP end,
        GetPlayerMapPosition = function()
            return { GetXY = function() return pos.x, pos.y end }
        end,
    }
    local function standOn(node, dx, dy)
        pos.x, pos.y = node.x + (dx or 0), node.y + (dy or 0)
    end

    local f4 = Timers.NODES.flower[4]

    -- (a) THE bug: any old cast next to a node used to mark it picked. A mount /
    -- heal / profession cast must now do nothing at all (A5.1).
    standOn(f4)
    Timers._onSpellSucceeded("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 8690)  -- Hearthstone
    tcheck((timers.flower[4] or 0) == 0, "a non-songflower cast on a node marks NOTHING (A5.1)", fails)
    Timers._onSpellSucceeded("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 6603)
    tcheck((timers.flower[4] or 0) == 0, "second unrelated cast still marks nothing", fails)

    -- (b) The real Cleansed Songflower cast (6478) on the node DOES mark it.
    Timers._onSpellSucceeded("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-2", Timers.SONGFLOWER_SPELL)
    tcheck((timers.flower[4] or 0) > 0, "spell 6478 on a node marks the pick", fails)

    -- (c) Another unit's cast is never ours.
    timers.flower = {}
    Timers._onSpellSucceeded("UNIT_SPELLCAST_SUCCEEDED", "target", "Cast-3", Timers.SONGFLOWER_SPELL)
    tcheck((timers.flower[4] or 0) == 0, "another unit's 6478 cast is ignored", fails)

    -- (d) Radius: a pick a real distance off the stored coordinate now lands
    -- (0.06, not the 4x-too-tight 0.015) -- A5.2.
    timers.flower = {}
    standOn(f4, 0.03, 0.02)   -- ~0.036 away: inside 0.06, outside the old 0.015
    Timers._onSpellSucceeded("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-4", Timers.SONGFLOWER_SPELL)
    tcheck((timers.flower[4] or 0) > 0, "a pick 0.036 off the node still matches (A5.2)", fails)
    tcheck(Timers.NODE_MATCH_RADIUS == 0.06, "node match radius is 0.06 normalized", fails)

    -- Well outside the radius still matches nothing.
    timers.flower = {}
    standOn(f4, 0.2, 0.2)
    Timers._onSpellSucceeded("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-5", Timers.SONGFLOWER_SPELL)
    tcheck((timers.flower[4] or 0) == 0, "a cast far from every node matches nothing", fails)

    -- (e) Co-located flower/tuber sites still resolve by nearest-distance, so
    -- the wider radius cannot bleed a flower pick onto its neighbour tuber.
    local f3, t1 = Timers.NODES.flower[3], Timers.NODES.tuber[1]
    local k1 = Timers.MatchNodePick(f3.x, f3.y)
    tcheck(k1 == "flower", "standing on flower 3 resolves to the flower", fails)
    local k2, i2 = Timers.MatchNodePick(t1.x, t1.y)
    tcheck(k2 == "tuber" and i2 == 1, "standing on tuber 1 resolves to the tuber", fails)
    tcheck(Timers.MatchNodePick(0.9, 0.9) == nil, "far-away position matches no node", fails)

    _G.C_Map = savedMap
    timers.flower, timers.tuber = {}, {}
end

-- Confirmation upgrade: a lower-trust anchor, then higher trust inside CD
-- upgrades trust without a new anchor.
local function testTrustUpgrade(fails)
    Timers.state = {}
    local a = 1500000000
    Timers.Record("onyH", a, "dbm", "DBM", "pop")
    tcheck(Timers.state.onyH.trust == "dbm", "onyH first anchored by dbm", fails)
    local ok = Timers.Record("onyH", a + 600, "nwb", "NWB", "pop")
    tcheck(ok == false, "within-CD nwb report not a new anchor", fails)
    tcheck(Timers.state.onyH.trust == "nwb", "trust upgraded dbm->nwb", fails)
    tcheck(Timers.state.onyH.confirmed == true, "onyH confirmed after upgrade", fails)
    Timers.state = {}
end

-- Log dedup: two pops within the store's 30s window collapse to one entry.
local function testLogDedup(fails)
    if not (ns.Store and ns.Store.GetTimers and ns.Store.AddTimerLog) then
        fails[#fails + 1] = "store not available for dedup test"
        return
    end
    local logs = ns.Store.GetTimers().logs
    logs.rend = {}
    Timers.state = {}
    -- Anchor to the live clock so the store's 48h expiry does not trim.
    local a = now()
    ns.Store.AddTimerLog("rend", { epoch = a, who = "same", trust = "local" })
    ns.Store.AddTimerLog("rend", { epoch = a + 10, who = "same", trust = "local" })
    tcheck(#logs.rend == 1, "same-source pops within 30s dedup to 1 log", fails)
    ns.Store.AddTimerLog("rend", { epoch = a + 40, who = "same", trust = "local" })
    tcheck(#logs.rend == 2, "pop past 30s window is a new log entry", fails)
    logs.rend = {}
end

-- Node state machine + nearest-node matching.
local function testNodeStateMachine(fails)
    -- Nearest node: a point right on flower #4 resolves to index 4.
    local n4 = Timers.NODES.flower[4]
    local idx, dist = Timers.NearestNode("flower", n4.x, n4.y)
    tcheck(idx == 4, "nearest flower resolves to the exact node", fails)
    tcheck(dist ~= nil and dist < 0.001, "distance ~0 on the node", fails)
    -- State transitions: unknown -> down -> up.
    local st0 = Timers.NodeState(0, 1000, NODE_RESPAWN)
    tcheck(st0.state == "unknown", "no pop => unknown (UP?)", fails)
    local pop = 1000
    local stDown = Timers.NodeState(pop, pop + 100, NODE_RESPAWN)
    tcheck(stDown.state == "down" and math.abs(stDown.remaining - (NODE_RESPAWN - 100)) < 0.5,
        "picked node counts down", fails)
    local stUp = Timers.NodeState(pop, pop + NODE_RESPAWN + 5, NODE_RESPAWN)
    tcheck(stUp.state == "up", "node returns to up after respawn", fails)
    -- upDuration=0/nil keeps the up window indefinite (default behavior).
    local stUpForever = Timers.NodeState(pop, pop + NODE_RESPAWN + 100000, NODE_RESPAWN, 0)
    tcheck(stUpForever.state == "up", "upDuration 0 => up indefinitely", fails)
    -- A finite upDuration reverts to unknown once the window elapses.
    local stUpWin = Timers.NodeState(pop, pop + NODE_RESPAWN + 50, NODE_RESPAWN, 100)
    tcheck(stUpWin.state == "up", "up shown within upDuration window", fails)
    local stUpExp = Timers.NodeState(pop, pop + NODE_RESPAWN + 200, NODE_RESPAWN, 100)
    tcheck(stUpExp.state == "unknown", "up window expires after upDuration", fails)
    -- A shortened minus-timer flips down->up earlier.
    local stShort = Timers.NodeState(pop, pop + 1300, 1200, 0)
    tcheck(stShort.state == "up", "shorter minus-timer respawns earlier", fails)
end

-- DBM / NWB parse helpers.
local function testIngestParsers(fails)
    -- DBM tab format with a world-boss kill.
    local body = "Someone-Realm\t1\tK\t10184\t1"
    local m = Timers.ParseDBM(body)
    tcheck(m ~= nil and m.opcode == "K" and m.args[1] == "10184", "DBM K parsed", fails)
    tcheck(Timers._dbmCreatureToBuff(10184) == factionKey("ony"), "creature 10184 -> ony key", fails)
    -- Protocol gate rejects protocol 0.
    tcheck(Timers.ParseDBM("S\t0\tK\t10184") == nil, "DBM protocol < 1 rejected", fails)
    -- NWB space-explode with a trailing payload containing spaces.
    local args = Timers._explodeSpace("data 3.39 123-1 tok payloadhere", 5)
    tcheck(args[1] == "data" and args[2] == "3.39" and args[5] == "payloadhere",
        "NWB top string exploded into 5 fields", fails)
    tcheck(Timers._nwbTypeToBuff("zan") == "zg", "NWB 'zan' -> zg", fails)
    -- GUID npc-id extraction.
    tcheck(Timers._npcIDFromGUID("Creature-0-1-2-3-14834-000012AB") == 14834,
        "npc id parsed from GUID", fails)
end

-- Trust ladder ordering: local > mesh > sn > nwb > dbm (spec, round 2).
local function testTrustOrdering(fails)
    tcheck(trustRank("local") > trustRank("mesh"), "local outranks mesh", fails)
    tcheck(trustRank("mesh") > trustRank("sn"),   "mesh outranks sn", fails)
    tcheck(trustRank("sn")   > trustRank("nwb"),  "sn outranks nwb", fails)
    tcheck(trustRank("nwb")  > trustRank("dbm"),  "nwb outranks dbm", fails)
    tcheck(trustRank("dbm")  > 0,                 "dbm ranks above unknown", fails)
    tcheck(trustRank("bogus") == 0,               "unknown source ranks 0", fails)
    -- An "sn" report can upgrade a within-CD nwb/dbm anchor's trust (spec:
    -- sn sits above nwb). Uses the same Record arbitration as other sources.
    Timers.state = {}
    local a = 1500000000
    Timers.Record("onyH", a, "nwb", "NWB", "pop")
    tcheck(Timers.state.onyH.trust == "nwb", "onyH first anchored by nwb", fails)
    local ok = Timers.Record("onyH", a + 600, "sn", "SN", "pop")
    tcheck(ok == false, "within-CD sn report is not a new anchor", fails)
    tcheck(Timers.state.onyH.trust == "sn", "trust upgraded nwb->sn", fails)
    -- A lower-trust nwb report cannot downgrade an sn anchor of the same event.
    Timers.state = {}
    Timers.Record("onyH", a, "sn", "SN", "pop")
    local ok2 = Timers.Record("onyH", a + 5, "nwb", "NWB", "pop")
    tcheck(ok2 == false, "nwb cannot overwrite a fresh sn anchor", fails)
    tcheck(Timers.state.onyH.trust == "sn", "sn anchor retained over nwb", fails)
    Timers.state = {}
end

-- Request cooldowns: Nexus request returns ok,0 then false,remaining; source
-- freshness bookkeeping reflects note calls.
local function testRequestCooldowns(fails)
    Timers._lastNexusRequest = 0
    local ok1, rem1 = Timers.RequestNexusData()
    tcheck(ok1 == true and rem1 == 0, "first nexus request fires (ok,0)", fails)
    local ok2, rem2 = Timers.RequestNexusData()
    tcheck(ok2 == false, "second nexus request within 60s is blocked", fails)
    tcheck(type(rem2) == "number" and rem2 > 0 and rem2 <= 60,
        "blocked request reports a 0<rem<=60 cooldown", fails)
    -- RequestNWBData is a no-op false when not in a guild / NWB absent (bare VM).
    if not (IsInGuild and IsInGuild()) then
        tcheck(Timers.RequestNWBData() == false, "NWB request no-op false when guildless", fails)
    end
    -- Freshness note + accessor.
    Timers._freshness = { nexus = 0, nwb = 0, snPassive = 0 }
    Timers._noteFreshness("snPassive")
    local f = Timers.GetSourceFreshness()
    tcheck(f.snPassive > 0, "snPassive freshness stamped", fails)
    tcheck(f.nexus == 0 and f.nwb == 0, "other sources untouched by one note", fails)
    tcheck(f.nexus ~= nil and f.nwb ~= nil and f.snPassive ~= nil,
        "GetSourceFreshness returns all three keys", fails)
end

-- NWB request build. The wire TEXT layout (cmd/version/level/token/data) is
-- validated purely (no deflate); the encoded string is validated for presence.
local function testNWBRequestBuild(fails)
    -- Pure wire-text layout: "requestData <ver> <level> <ktoken> <data>".
    local text = Timers.BuildNWBText("PAYLOAD")
    local parts = Timers._explodeSpace(text, 5)
    tcheck(parts[1] == "requestData", "cmd field is requestData", fails)
    tcheck(tonumber(parts[2]) ~= nil and tonumber(parts[2]) >= 2.75,
        "advertised version >= 2.75 (clears NWB classic gate)", fails)
    tcheck(tonumber(parts[3]) ~= nil, "level field is numeric", fails)
    tcheck(tonumber(parts[4]) ~= nil, "server-time token is numeric", fails)
    tcheck(parts[5] == "PAYLOAD", "field 5 carries the serialized data", fails)
    -- Integration: with the libs present, the full encode yields a wire string.
    local nwb = Timers._nwb
    nwb.libSerialize = nwb.libSerialize or (LibStub and LibStub.GetLibrary and LibStub:GetLibrary("LibSerialize", true))
    nwb.deflate      = nwb.deflate      or (LibStub and LibStub.GetLibrary and LibStub:GetLibrary("LibDeflate", true))
    if nwb.libSerialize and nwb.deflate then
        local enc = Timers.BuildNWBRequest()
        tcheck(type(enc) == "string" and #enc > 0, "BuildNWBRequest returns an encoded wire string", fails)
    end
end

-- Item 39: imported/persisted pop logs seed live CD state; stale logs do not.
local function testRehydrateFromStore(fails)
    if not (ns.Store and ns.Store.GetTimers) then
        fails[#fails + 1] = "store absent for rehydrate test"; return
    end
    local logs = ns.Store.GetTimers().logs
    local t = now()
    -- Fresh rend pop (1h ago, within the 3h CD).
    Timers.state = {}
    logs.rend, logs.onyH, logs.onyA = { { epoch = t - 3600, who = "imp", trust = "sn" } }, {}, {}
    local seeded = Timers.RehydrateFromStore()
    tcheck(seeded >= 1, "fresh rend log seeds an anchor", fails)
    local s = Timers.state.rend
    tcheck(s and (s.lastPop or 0) > 0, "rend anchor set from imported log", fails)
    local cd = Timers.ComputeCD("rend", anchorEpoch(s), t)
    tcheck(cd.onCD and cd.remaining > 0, "ComputeCD reports remaining after import seed", fails)
    -- Stale rend pop (older than the 3h CD) -> no seed.
    Timers.state = {}
    logs.rend = { { epoch = t - (4 * 3600), who = "old", trust = "sn" } }
    Timers.RehydrateFromStore()
    tcheck((Timers.state.rend == nil) or ((Timers.state.rend.lastPop or 0) == 0),
        "stale log (older than CD) not seeded", fails)
    logs.rend, Timers.state = {}, {}
end

-- Item 40: NWB timer payload ingest — flat short keys, layered realms, word keys.
local function testNWBIngest(fails)
    local t = now()
    Timers.state = {}
    local a1 = Timers.IngestNWBTimers({ n = t - 100, s = t - 200, f1 = t - 50, t3 = t - 60 })
    tcheck(a1.rend and a1.ony, "flat n/s short keys ingested", fails)
    tcheck((a1.flower or 0) >= 1 and (a1.tuber or 0) >= 1, "flat flower/tuber ingested", fails)
    -- Layered realm: timers nested under a layers-like map.
    Timers.state = {}
    local a2 = Timers.IngestNWBTimers({ layers = { [1] = { n = t - 300, f2 = t - 70 } } })
    tcheck(a2.rend, "layered rend ingested (item 40)", fails)
    tcheck((a2.flower or 0) >= 1, "layered flower ingested", fails)
    -- Word keys tolerated (un-compacted layer).
    Timers.state = {}
    local a3 = Timers.IngestNWBTimers({ rendTimer = t - 100, flower5 = t - 40 })
    tcheck(a3.rend and (a3.flower or 0) >= 1, "word keys tolerated", fails)
    Timers.state = {}
end

-- Pull-window selection + drift calibration (per-buff, per-yell-stage).
-- Covers: (a) the spec constants ARE the windows and the observed median can no
-- longer displace them; (b) manual override still wins; (c) stage-2 "no bar";
-- (d) obs capping + even median (still used for drift reporting); (e) the
-- recency gate; (f) observations only record when a pull was actually active.
local function testPullWindows(fails)
    local function resetObs()
        local t = ns.Store and ns.Store.GetTimers and ns.Store.GetTimers()
        if t then t.pullObservations = {} end
    end
    local function clearOverride()
        local s = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
        if s and s.timerSettings then s.timerSettings.pullWindows = nil end
    end
    local function setOverride(tbl)
        local s = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
        if s then
            s.timerSettings = s.timerSettings or {}
            s.timerSettings.pullWindows = tbl
        end
    end

    if not (ns.Store and ns.Store.GetTimers) then
        fails[#fails + 1] = "store absent for pull-window test"; return
    end

    resetObs(); clearOverride(); Timers._pendingPull = {}

    -- (a) The spec constants ARE the windows (§10.7). No PROVISIONAL guesses.
    tcheck(Timers.PULL_WINDOWS.onyH[1] == 14.5 and Timers.PULL_WINDOWS.onyA[1] == 15,
        "Ony spec windows are 14.5 (H) / 15 (A)", fails)
    tcheck(Timers.PULL_WINDOWS.nefH[1] == 15 and Timers.PULL_WINDOWS.nefA[1] == 12,
        "Nef spec windows are 15 (H) / 12 (A)", fails)
    tcheck(Timers.PULL_WINDOWS.zg[1] == 50.5 and Timers.PULL_WINDOWS.zg[2] == 29,
        "ZG spec windows are 50.5 / 29", fails)
    tcheck(Timers.REND_BARS.thrall[1].seconds == 6 and Timers.REND_BARS.thrall[2].seconds == 17,
        "Rend bars are Orgrimmar 6s / Barrens 17s", fails)
    tcheck(Timers.REND_BARS.herald[2].seconds == 6, "Herald Barrens variant is 6s", fails)

    local w, src = Timers.EffectivePullWindow("onyH", 1)
    tcheck(w == 14.5 and src == "spec", "onyH yell1 window comes from the spec table", fails)

    -- (b) stage 2 raises NO bar for Rend / Ony / Nef.
    for _, k in ipairs({ "rend", "onyH", "onyA", "nefH", "nefA" }) do
        local w2, s2 = Timers.EffectivePullWindow(k, 2)
        tcheck(w2 == nil and s2 == "none", k .. " yell2 has no bar", fails)
    end
    tcheck(Timers.EffectivePullWindow("zg", 2) == 29, "ZG yell2 still bars at 29s", fails)

    -- (c) observations NO LONGER displace a spec constant -- calibration is now
    -- drift measurement only (the constants are authoritative).
    Timers.RecordPullObservation("onyH", 1, 100)
    Timers.RecordPullObservation("onyH", 1, 300)
    Timers.RecordPullObservation("onyH", 1, 200)
    w, src = Timers.EffectivePullWindow("onyH", 1)
    tcheck(w == 14.5 and src == "spec", "3 observations do NOT override the spec window", fails)
    local obs, n = Timers.ObservedPullMedian("onyH", 1)
    tcheck(obs == 200 and n == 3, "the observed median is still reported for drift", fails)
    resetObs()

    -- (d) a manual override still wins over the spec constant. Number pins both
    -- stages; table pins per stage.
    setOverride({ rend = 99 })
    w, src = Timers.EffectivePullWindow("rend", 1)
    tcheck(w == 99 and src == "override", "numeric override wins over the spec constant", fails)
    w, src = Timers.EffectivePullWindow("rend", 2)
    tcheck(w == 99 and src == "override", "numeric override pins both stages", fails)
    setOverride({ onyH = { [1] = 111, [2] = 22 } })
    w = Timers.EffectivePullWindow("onyH", 1); tcheck(w == 111, "table override yell1=111", fails)
    w = Timers.EffectivePullWindow("onyH", 2); tcheck(w == 22, "table override yell2=22", fails)
    clearOverride()

    -- (b) observation capping at PULL_OBS_CAP + even-count median.
    resetObs()
    for i = 1, Timers.PULL_OBS_CAP + 2 do Timers.RecordPullObservation("zg", 2, i * 10) end
    local list = ns.Store.GetTimers().pullObservations.zg[2]
    tcheck(#list == Timers.PULL_OBS_CAP, "obs list capped at PULL_OBS_CAP", fails)
    tcheck(list[1] == 30 and list[#list] == (Timers.PULL_OBS_CAP + 2) * 10,
        "oldest evicted, newest kept (FIFO)", fails)
    resetObs()
    Timers.RecordPullObservation("zg", 2, 10)
    Timers.RecordPullObservation("zg", 2, 20)
    Timers.RecordPullObservation("zg", 2, 30)
    Timers.RecordPullObservation("zg", 2, 40)
    tcheck(Timers._median({ 10, 20, 30, 40 }) == 25, "even-count median averages middles", fails)
    tcheck(Timers.ObservedPullMedian("zg", 2) == 25, "even-count obs median reported", fails)

    -- (e) recency gate: remaining = window - elapsed against the spec window
    -- (ZG stage 1 = 50.5s). Fresh -> ~50.5; 20s late -> ~30.5.
    resetObs(); Timers._pendingPull = {}
    local cap = { pull = nil }
    ns:On("PULL_DETECTED", function(buffKey, duration) cap.pull = { buff = buffKey, duration = duration } end)
    local t = now()
    Timers.state = {}; cap.pull = nil
    Timers.Record("zg", t, "local", "live", "pop", nil, nil, 1)
    tcheck(cap.pull and cap.pull.buff == "zg" and math.abs(cap.pull.duration - 50.5) <= 1,
        "fresh yell-1 pull shows the ~50.5s spec window", fails)
    Timers.state = {}; cap.pull = nil
    Timers.Record("zg", t - 20, "local", "late", "pop", nil, nil, 1)
    tcheck(cap.pull and math.abs(cap.pull.duration - (50.5 - 20)) <= 1,
        "late yell-1 zg shows remaining = window - elapsed (~30.5)", fails)

    -- (f) observation records ONLY when a pull was active for that buff.
    resetObs(); Timers._pendingPull = {}
    -- A fresh pull seeds a pending for onyH; a later land books the observation.
    Timers.state = {}
    Timers.Record("onyH", t, "local", "pull", "pop", nil, nil, 2, nil)
    Timers._setPendingPull("onyH", t, 2)
    tcheck(Timers._pendingPull.onyH ~= nil, "a pull seeds a pending observation", fails)
    local recN = Timers.NotePullGain("onyH", t + 30)
    tcheck(recN == 1, "buff-land with active pull books one observation", fails)
    local ol = ns.Store.GetTimers().pullObservations
    tcheck(ol.onyH and ol.onyH[2] and ol.onyH[2][1] == 30, "observed onyH yell2 = 30s", fails)
    tcheck(Timers._pendingPull.onyH == nil, "pending consumed after land", fails)
    -- No pending for nefH => a buff-land books nothing (no spurious sample).
    local recNone = Timers.NotePullGain("nefH", t + 30)
    tcheck(recNone == 0, "buff-land with NO active pull books nothing", fails)
    tcheck(not (ol.nefH and ol.nefH[2]), "no spurious nefH observation", fails)
    -- Both stages of one buff resolve from a single land.
    resetObs(); Timers._pendingPull = {}
    Timers._setPendingPull("rend", t, 1)
    Timers._setPendingPull("rend", t + 100, 2)
    tcheck(Timers.NotePullGain("rend", t + 140) == 2, "one land calibrates both yell stages", fails)
    local rl = ns.Store.GetTimers().pullObservations.rend
    tcheck(rl[1][1] == 140 and rl[2][1] == 40, "rend yell1=140, yell2=40 booked", fails)
    -- Shared aura (Rallying Cry) credits only the candidate with a pending pull,
    -- most-recent yell wins (ony vs nef ambiguity).
    resetObs(); Timers._pendingPull = {}
    Timers._setPendingPull("nefH", t + 5, 2)   -- more recent than onyH below
    Timers._setPendingPull("onyH", t, 2)
    local credited = Timers._creditPullLand("rallying cry of the dragonslayer", t + 50)
    tcheck(credited == "nefH", "rallying-cry land credits most-recent pending (nefH)", fails)
    tcheck(Timers._pendingPull.nefH == nil and Timers._pendingPull.onyH ~= nil,
        "only the credited candidate is consumed", fails)
    -- Unrelated land with nothing pending records nothing and errors nothing.
    resetObs(); Timers._pendingPull = {}
    tcheck(Timers._creditPullLand("spirit of zandalar", t) == nil, "no pending zg -> no credit", fails)

    resetObs(); clearOverride(); Timers._pendingPull = {}; Timers.state = {}
end

function Timers.RunSelfTests(verbose)
    local suites = {
        { name = "cd derivation",     fn = testCDDerivation },
        { name = "false-positive gate", fn = testFalsePositive },
        { name = "yell table (A2)",   fn = testYellTable },
        { name = "announcer kill respawn (A3)", fn = testAnnouncerKill },
        { name = "quest hand-in (A4)", fn = testQuestHandin },
        { name = "songflower pick gate (A5)", fn = testSongflowerPick },
        { name = "pull recency gate", fn = testPullRecencyGate },
        { name = "pull windows + drift", fn = testPullWindows },
        { name = "trust upgrade",     fn = testTrustUpgrade },
        { name = "trust ordering",    fn = testTrustOrdering },
        { name = "request cooldowns", fn = testRequestCooldowns },
        { name = "nwb request build", fn = testNWBRequestBuild },
        { name = "log dedup",         fn = testLogDedup },
        { name = "node state machine", fn = testNodeStateMachine },
        { name = "ingest parsers",    fn = testIngestParsers },
        { name = "rehydrate from store", fn = testRehydrateFromStore },
        { name = "nwb payload ingest", fn = testNWBIngest },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok = pcall(suite.fn, fails)
        local passed = ok and #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then
                ns:Print("  PASS timers/" .. suite.name)
            elseif not ok then
                ns:Print("  FAIL timers/" .. suite.name .. " :: error in test")
            else
                for _, f in ipairs(fails) do
                    ns:Print("  FAIL timers/" .. suite.name .. " :: " .. f)
                end
            end
        end
    end
    return allPass
end

----------------------------------------------------------------------
-- Lifecycle wiring
----------------------------------------------------------------------

function Timers.OnLogin()
    -- Register the DBM prefix defensively so we can decode D5 even if DBM
    -- registers later; NWB is handled through AceComm below.
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        C_ChatInfo.RegisterAddonMessagePrefix("D5")
    end

    -- Weekly reset check at init (before seeding warnings so we do not arm
    -- warnings against data that a boundary just wiped).
    Timers.CheckWeeklyReset()

    -- Seed CD-warning scheduler from persisted anchors (no backfire).
    seedAllWarnings()

    -- Re-seed live CD state when a bulk store refresh lands (import etc. — item 39).
    if ns.On then
        ns:On("STORE_REFRESHED", function() ns:SafeCall(Timers.OnStoreRefreshed) end)
    end

    -- Stand up receive-only NWB ingest if the shared libs are present.
    setupNWB()

    -- Stand up receive-only ShadowNetwork passive ingest (snbridge.lua).
    if ns.SNBridge and ns.SNBridge.OnLogin then
        ns:SafeCall(ns.SNBridge.OnLogin)
    end

    -- Wire the mesh handoffs: peers answer RequestNexusData with a snapshot we
    -- apply through ApplySnapshot; we answer their requests with GetSnapshot;
    -- single mesh timer/pull events (future originator path) route through the
    -- same trust-gated ingestion.
    if ns.Mesh then
        if ns.Mesh.RegisterSnapshotProvider then
            ns.Mesh.RegisterSnapshotProvider(Timers.GetSnapshot)
        end
        if ns.Mesh.SetSnapshotHandler then
            ns.Mesh.SetSnapshotHandler(function(snap)
                Timers.ApplySnapshot(snap, "mesh")
            end)
        end
        if ns.Mesh.SetTimerHandler then
            ns.Mesh.SetTimerHandler(function(evt, sender)
                if type(evt) ~= "table" or not evt.buff then return end
                if evt.pull then
                    Timers.OnMeshPull(evt.buff, evt.epoch, evt.duration, evt.zone,
                                      { who = sender })
                else
                    Timers.OnMeshTimer(evt.buff, evt.epoch, evt.kind,
                                       { who = sender, zone = evt.zone })
                end
            end)
        end
    end

    -- Event detectors.
    ns:RegisterEvent("CHAT_MSG_MONSTER_YELL", onMonsterYell)
    ns:RegisterEvent("CHAT_MSG_MONSTER_SAY",  onMonsterYell)
    ns:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", onCombatLog)
    ns:RegisterEvent("QUEST_TURNED_IN", onQuestTurnedIn)
    ns:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", onSpellSucceeded)
    -- Pull auto-calibration: measure announce->drop when the buff lands on us.
    ns:RegisterEvent("UNIT_AURA", onPlayerAura)
    ns:RegisterEvent("CHAT_MSG_ADDON", function(event, prefix, msg)
        if prefix == "D5" then
            ns:SafeCall(Timers.OnDBMMessage, msg)
        end
    end)

    -- 5-min weekly-reset ticker.
    if C_Timer and C_Timer.NewTicker then
        C_Timer.NewTicker(300, function() ns:SafeCall(Timers.CheckWeeklyReset) end)
    end

    -- Login data requests + NWB re-watch.
    Timers.RequestTimerData()
    startNWBRewatch()
end

-- Register self-tests + the debug dump through the Core registries (added
-- in wave N2). Guarded so a bare-VM harness that lacks them still loads.
if ns.RegisterSelfTest then
    ns:RegisterSelfTest("timers", Timers.RunSelfTests)
end
if ns.RegisterDebugCommand then
    ns:RegisterDebugCommand("timers", function() Timers.DebugDump() end)
    ns:RegisterDebugCommand("nwb", function() Timers.NWBDebugDump() end)
    ns:RegisterDebugCommand("pulls", function() Timers.PullsDebugDump() end)
end

-- Go active at login (Core fires Tracker/Protocol OnLogin already; we hook
-- the same lifecycle event so no Core edit is needed for activation).
if ns.On then
    ns:On("LOGIN", function() ns:SafeCall(Timers.OnLogin) end)
end
