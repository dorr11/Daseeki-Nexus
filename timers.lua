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

-- Raw cooldowns (seconds). Rend 3h, Ony 6h per faction; zg (Spirit of Zandalar)
-- cycles on the shorter 3h window.
--
-- NEFARIAN IS DISABLED (0) ON CLASSIC ERA — and a 0 here is not cosmetic.
-- Both reference addons agree with each other and disagreed with us: the
-- canonical world-buff addon forces the Nefarian cooldown to 0 on Era, which
-- means no countdown, no cooldown bar, the type is never packed into an outgoing
-- payload, and an INBOUND Nefarian timer is silently discarded. The other
-- reference simply removed Nef cooldown tracking. Our old 21600 was wrong twice
-- over: the base constant is 28800 (8h, not 6h) and Era zeroes it regardless, so
-- we were displaying a six-hour Nefarian cooldown that no reference shows.
--
-- Detection is deliberately untouched: a Nef drop still alerts and still raises
-- its pull bar, the announcer kill still runs the 360s respawn model, and the
-- Nef alert-matrix rows stay. Only the COOLDOWN/timer model goes.
local CD = {
    rend = 3 * 3600,
    onyH = 6 * 3600,
    onyA = 6 * 3600,
    nefH = 0,          -- DISABLED on Classic Era (see above)
    nefA = 0,          -- DISABLED on Classic Era
    zg   = 3 * 3600,
}
Timers.CD = CD

-- A buff whose cooldown constant is 0 is NOT COOLDOWN-TRACKED: no pop anchor is
-- ever set for it from any source, no cooldown is computed or displayed, and
-- inbound timer data for it is dropped. Kill/respawn state and alerts are
-- unaffected. Deliberately false for a key absent from CD entirely (battleShout
-- is an alert-only callback key and must keep flowing through Record's guard).
local function cdDisabled(buffKey)
    local cd = CD[buffKey]
    return cd ~= nil and cd <= 0
end
Timers.IsCooldownDisabled = cdDisabled

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
--
-- "dbm" keeps its rung but no longer produces anchors at all: DBM's boss-kill
-- and combat-start syncs describe a raid boss, not a world-buff drop, and both
-- are now non-anchoring hints (F2/F5). The rank stays so a legacy anchor that
-- still carries the tag (an old SavedVariables log entry) arbitrates as the
-- weakest source rather than as an unknown one, which ranks 0.
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
--
-- TWO-PHASE MODEL (F12). 360s is NOT "dead then instantly back": it is the
-- CERTAIN-DEAD phase, after which the announcer returns at a RANDOM time inside
-- the following 120s window (NWB_BEHAVIOR_SPEC §3.4 — the 360s message is
-- literally "will respawn at a random time within the next 2 minutes"). The
-- availability MODEL flips at 360 (nothing blocks a drop from that instant), but
-- a display that says a flat "Open" at 360 is over-promising, so BuffStatus
-- exposes the phase alongside the state: "dead" (< 360), "window" (360..480 —
-- can pop, announcer may still be walking back), "open" (>= 480).
local ANNOUNCER_RESPAWN = 360
Timers.ANNOUNCER_RESPAWN = ANNOUNCER_RESPAWN
local ANNOUNCER_RESPAWN_WINDOW = 120
Timers.ANNOUNCER_RESPAWN_WINDOW = ANNOUNCER_RESPAWN_WINDOW

-- kind="killed" MEANS ONE THING: an ANNOUNCER NPC died (F2). Only these four
-- buffs have an announcer whose death is a real, observable respawn event
-- (Overlord Runthak / Major Mattingly / High Overlord Saurfang / Field Marshal
-- Afrasiabi-Stonebridge). Rend and Zandalar have NO announcer NPC at all: the
-- only "kill" in their world is the RAID BOSS dying (Rend Blackhand, Hakkar),
-- which is a completely different event — it is not a drop and it starts no
-- respawn. Every path that can produce a kill record is gated on this set, so a
-- boss-kill report can never plant a phantom 6-minute respawn on Rend or ZG.
local ANNOUNCER_BUFFS = { onyH = true, onyA = true, nefH = true, nefA = true }
Timers.ANNOUNCER_BUFFS = ANNOUNCER_BUFFS

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
    -- `cd <= 0` is the cooldown-disabled case (Nefarian on Era): there is no
    -- cooldown to compute, so the buff reads as "nothing to count down".
    if not cd or cd <= 0 or not anchor or anchor <= 0 then
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
--   killed  : the announcer died and is still inside its certain-dead phase
--   canpop  : off cooldown AND past the certain-dead phase
--   cd      : on cooldown, `remaining` seconds left
--
-- F3 — THE LONGER CONSTRAINT WINS, not the newest event. The old rule was "a
-- kill newer than the newest pop wins", which let killing the announcer ERASE a
-- live multi-hour cooldown from the readout: kill Runthak two minutes after an
-- Onyxia drop and the UI said "killed, back in 6 minutes" when the buff was in
-- fact five hours and fifty-eight minutes away. A kill and a cooldown are two
-- INDEPENDENT gates on the same question ("when can this buff drop again"), so
-- the answer is whichever gate clears LAST — regardless of which was recorded
-- most recently. Kills still never start a cooldown (A3.1); they simply cannot
-- shorten one either.
--
-- DISPLAY_GRACE is applied HERE and only here (SN spec §10.2: raw 10800s /
-- display 10805s). The +5s absorbs detection lag and clock drift so a bar does
-- not blink to "open" a heartbeat before the last relay of the same drop lands.
-- The false-positive gate deliberately keeps using the RAW cooldown.
--
-- Extra fields when a kill is in play (additive; existing readers ignore them):
--   phase          "dead" | "window" | "open"   (F12 two-phase respawn)
--   windowEndsAt   epoch at which the announcer is certainly back
--   windowRemaining seconds left of the 120s random window (0 outside it)
function Timers.BuffStatus(buffKey, t)
    t = t or now()
    local s = Timers.state[buffKey]
    local pop    = (s and s.lastPop) or 0
    local killed = (s and s.killedAt) or 0

    -- Kill gate: certain-dead until +360, random window until +480.
    local killEndsAt, windowEndsAt, phase, windowRemaining = 0, 0, nil, 0
    if killed > 0 then
        killEndsAt   = killed + ANNOUNCER_RESPAWN
        windowEndsAt = killEndsAt + ANNOUNCER_RESPAWN_WINDOW
        if t < killEndsAt then
            phase, windowRemaining = "dead", ANNOUNCER_RESPAWN_WINDOW
        elseif t < windowEndsAt then
            phase, windowRemaining = "window", windowEndsAt - t
        else
            phase, windowRemaining = "open", 0
        end
    end

    -- Cooldown gate: cooldown-disabled buffs (Nefarian on Era) have none.
    local cdEndsAt = 0
    if not cdDisabled(buffKey) and pop > 0 then
        local info = Timers.ComputeCD(buffKey, pop, t)
        cdEndsAt = (info.nextAt or 0) + DISPLAY_GRACE
    end

    if pop <= 0 and killed <= 0 then
        return { state = "nodata", remaining = 0, nextAt = 0 }
    end

    local cdLive   = cdEndsAt > t
    local killLive = killEndsAt > t

    -- F-KILL — A KILL MUST NEVER BE SWALLOWED BY A LONGER COOLDOWN.
    --
    -- F3 was right that the CD wins the AVAILABILITY question (`state`): a kill
    -- says nothing about a cooldown that is still running, and letting the kill
    -- win there made "killed, back in 6 minutes" appear while the buff was
    -- genuinely six hours away. But `state` was the kill's ONLY channel, so
    -- whenever the cooldown outlived the 360s respawn the kill disappeared from
    -- every consumer in the addon.
    --
    -- That is exactly what happened on 2026-08-03. The owner's raid killed a
    -- mind-controlled Overlord Runthak at 22:39:33 with ~19 minutes left on the
    -- Onyxia cooldown. Local detection fired, `killedAt` was stamped and the
    -- `killed` log entry persisted — and the dashboard row went on counting the
    -- cooldown down as though nothing had happened, so the kill read to the owner
    -- as "not detected at all".
    --
    -- Both references keep kill and drop as two INDEPENDENT facts and surface the
    -- kill in its own right (NWB §3.3 shows "<Buff> NPC (<name>) was killed
    -- <time> ago"; SN §8.7's status bar carries a dedicated `Killed Mm SSs`
    -- readout with its own pulse). So the kill now rides EVERY return as additive
    -- fields, and `state` keeps its F3 meaning untouched:
    --   killedAt       the stamp itself (nil when there is no kill)
    --   killActive     the announcer is down AND the kill is the newest event
    --   killRemaining  seconds of the certain-dead phase left (0 once elapsed)
    --   cdEndsAt       so a consumer that promotes the kill to the headline can
    --                  still show the cooldown it displaced
    --
    -- `killActive` requires the kill to be at least as new as the pop because a
    -- drop is proof the announcer is BACK — he is the NPC who yells. (Record also
    -- clears a superseded stamp outright; this is the belt to that pair of
    -- braces, and it also covers state rehydrated from an older build's log.)
    local killActive    = (killed > 0) and (killed >= pop) and (t < windowEndsAt)
    local killRemaining = (killEndsAt > t) and (killEndsAt - t) or 0

    local out
    if cdLive and (not killLive or cdEndsAt >= killEndsAt) then
        out = { state = "cd", remaining = cdEndsAt - t, nextAt = cdEndsAt }
    elseif killLive then
        out = { state = "killed", remaining = killEndsAt - t, nextAt = killEndsAt }
    elseif cdEndsAt <= 0 and killed <= 0 then
        -- Both gates clear. A cooldown-disabled buff with no kill has nothing to
        -- say (its pop, if one ever reached state, models no countdown at all).
        return { state = "nodata", remaining = 0, nextAt = 0 }
    else
        out = { state = "canpop", remaining = 0, nextAt = math.max(cdEndsAt, killEndsAt) }
    end

    out.phase           = phase
    out.windowEndsAt    = (killed > 0) and windowEndsAt or nil
    out.windowRemaining = windowRemaining
    out.killedAt        = (killed > 0) and killed or nil
    out.killActive      = killActive or nil
    out.killRemaining   = killRemaining
    out.cdEndsAt        = (cdEndsAt > 0) and cdEndsAt or nil
    return out
end

-- False-positive gate (pure). A fresh POP within a full CD of the current
-- anchor is a duplicate report and is rejected. A KILL is a reset and is
-- always allowed to re-anchor. Grace is intentionally NOT applied here (the
-- gate uses the RAW cooldown; only the readout gets DISPLAY_GRACE).
--
-- DIRECTION MATTERS (F1): this gate answers "is this report a duplicate of the
-- anchor we already hold", which is only meaningful for an epoch AT OR AFTER the
-- anchor. An OLDER epoch is a different question — "may this report move the
-- anchor BACKWARDS" — and is answered by IsAnchorRewind below. Folding the two
-- together (abs(delta) < cd) would reject legitimate corrections outright and
-- still leave the rewind unguarded for deltas beyond a cooldown, which is
-- exactly the hole that let an old NWB log entry rewind a fresh anchor.
function Timers.IsFalsePositive(buffKey, anchor, newEpoch, isKill)
    if isKill then return false end
    local cd = CD[buffKey]
    if not cd or cd <= 0 or not anchor or anchor <= 0 then return false end
    -- Within a full CD after the anchor => false positive.
    if newEpoch >= anchor and (newEpoch - anchor) < cd then
        return true
    end
    return false
end

-- Backwards-anchor guard (pure, F1). An anchor that moves BACKWARDS re-opens a
-- cooldown that has already partly run, resurrects CD warnings that were
-- correctly cancelled, and makes the pull-recency gate re-evaluate an older
-- moment. It is essentially never right, and every bulk ingest path (an NWB
-- timer log walked in wire order, a peer snapshot, an SN log array) can hand us
-- an older epoch AFTER a newer one.
--
-- The one legitimate case is a CORRECTION from a source that outranks whoever
-- set the anchor: our own eyes correcting a relayed guess. So an older epoch may
-- replace the stored anchor ONLY when the new trust STRICTLY outranks the stored
-- trust. Equal trust never rewinds — two reports of the same rank are two
-- opinions, and the newer moment is the one already applied.
function Timers.IsAnchorRewind(prevAnchor, newEpoch, trust, prevTrust)
    if not prevAnchor or prevAnchor <= 0 then return false end
    if not newEpoch or newEpoch >= prevAnchor then return false end
    return trustRank(trust) <= trustRank(prevTrust)
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

-- (F13) `Timers.RaisePull` USED TO LIVE HERE and is deliberately gone. It was a
-- published wrapper over `raisePull` with a DIFFERENT argument order, and it had
-- exactly zero callers: every detector that bars without recording a pop (Rend's
-- second bar, the ZG stage-2 bar, the ZG quest hand-in) calls the local
-- `raisePull` directly, and no other file in the addon ever referenced it —
--   grep -rn "RaisePull" --include=*.lua .   ->  the definition alone.
-- A dead public surface with a mismatched signature is a trap for the next
-- caller, so the trap is removed rather than documented. `Timers._raisePull`
-- remains exposed for the self-tests.

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

    -- Cooldown-disabled types (Nefarian on Era) are NEVER anchored, from any
    -- source: local yell, quest hand-in, mesh/SN relay, NWB payload or timer
    -- log. This is the single choke point that implements "stop anchoring Nef
    -- from any source, and reject inbound Nef timer data" — every ingest path in
    -- this file and in snbridge/mesh/import funnels through Record.
    -- An announcer KILL is still recorded: it drives the 360s respawn readout,
    -- which both references keep.
    if not isKill and cdDisabled(buffKey) then
        return false, "cooldown disabled for this buff"
    end

    -- F2 — ANNOUNCER-ONLY KILLS. `killed` writes the 6-minute respawn clock, so
    -- it may only ever mean "the announcer NPC died". Rend and Zandalar have no
    -- announcer; a "kill" reported for them is a RAID BOSS dying (Rend
    -- Blackhand, Hakkar), which is not a drop and starts no respawn. Sources are
    -- fixed at their own layer (DBM's boss-kill opcode no longer records at all,
    -- snbridge maps a rendLog/zgLog `killed` flag to a pop) and this is the
    -- backstop: rejected outright rather than silently reinterpreted, so a
    -- future source cannot manufacture either a phantom respawn OR a pop anchor.
    if isKill and not ANNOUNCER_BUFFS[buffKey] then
        return false, "kill is announcer-only (" .. tostring(buffKey) .. " has no announcer)"
    end

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

    -- F1 — NEVER REWIND AN ANCHOR. Checked against the anchor this write would
    -- actually move (killedAt for a kill, lastPop for everything else), and only
    -- a STRICTLY higher-trust source may pull one backwards. Without this, the
    -- NWB timer log — an array walked in wire order — could hand Record a newer
    -- entry and then an older one, and the older one won simply by arriving last.
    local rewindPrev = isKill and (s.killedAt or 0) or prevAnchor
    if Timers.IsAnchorRewind(rewindPrev, epoch, trust, prevTrust) then
        return false, "older than the current anchor (no rewind)"
    end

    -- Apply the anchor. A kill stamps the RESPAWN clock (killedAt), never the
    -- cooldown anchor — see Timers.BuffStatus (A3.1).
    if isKill then
        s.killedAt = epoch
    else
        s.lastPop = epoch
        -- NWB §3.3, the half we never implemented: "Setting a new drop timer
        -- resets the kill timestamp to 0." A drop is positive proof the announcer
        -- is BACK — he is the NPC who yells the buff — so a kill older than the
        -- drop is spent history. Left standing it would keep asserting "the
        -- announcer is down" straight through the respawn it already outlived.
        if (s.killedAt or 0) <= epoch then s.killedAt = 0 end
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

-- CLASS 8 / NX-13 — THE LOOSE FALLBACK'S CANDIDATE ORDER, DECIDED ONCE.
--
-- The fallback fires on any yelled name that CONTAINS a known announcer key, so
-- it takes only one key that is a substring of another for two keys to match the
-- same yell — and this table SHIPS such a pair: "thrall" and "herald of thrall".
-- A decorated or localized rendering of the Herald ("Herald of Thrall" with any
-- suffix, anything that misses the exact-match branch) matches BOTH, and
-- whichever key `pairs()` reached first won. The two are not interchangeable:
-- REND_NPC_VARIANT below reads the resolved key to choose the Barrens bar
-- variant, and the announcer decides which world buff is timed, stored, and
-- re-broadcast to the whole mesh. A coin-flip there is a wrong timer on every
-- peer's screen.
--
-- The rule: LONGEST MATCH WINS (ties broken by the key itself, ascending). Both
-- deterministic and semantically right — the more specific name is the better
-- identification. Pure and parameterised so the suite can drive the rule against
-- a table built three different ways, which the shipping table (one lifetime)
-- could never prove on its own.
function Timers.NpcCandidateOrder(rows)
    local out = {}
    for npc in pairs(rows or {}) do
        if type(npc) == "string" then out[#out + 1] = npc end
    end
    table.sort(out, function(a, b)
        if #a ~= #b then return #a > #b end
        return a < b
    end)
    return out
end

-- Resolve a monster name to its canonical key in `rows`, given that table's
-- candidate order. Exact match first, then longest containing match. Pure.
function Timers.ResolveNpcKey(rows, order, monsterName)
    local key = (monsterName or ""):lower()
    if key == "" or type(rows) ~= "table" then return nil end
    if rows[key] then return key end
    for i = 1, #(order or {}) do
        local npc = order[i]
        if key:find(npc, 1, true) then return npc end
    end
    return nil
end

local YELL_NPC_KEYS = Timers.NpcCandidateOrder(YELL_NPC_ROWS)
Timers._yellNpcKeys = YELL_NPC_KEYS

-- Resolve a monster name to its canonical table key.
local function npcKeyOf(monsterName)
    return Timers.ResolveNpcKey(YELL_NPC_ROWS, YELL_NPC_KEYS, monsterName)
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

-- Non-consuming peek: is one of OUR OWN hand-ins still waiting for its yell?
function Timers.HandinPending(buffKey, t)
    local st = Timers._handinStash[buffKey]
    if not st then return false end
    return ((t or now()) - (st.at or 0)) <= HANDIN_STASH_TTL
end

----------------------------------------------------------------------
-- Hand-in semantics — ONE definition for every source (F7)
--
-- A hand-in is not a drop. The head goes in, the announcer yells, and the buff
-- lands ~13s later; the reference converts a logged hand-in to an assumed drop
-- by adding 15s (13 measured + 2 leeway) and so do we — NWB_BEHAVIOR_SPEC §3.5.
-- Before this, the lead was applied on exactly one path (the NWB timer log) and
-- SN's quest-kind entries anchored at the raw hand-in second, so the same event
-- reported by two sources produced two anchors 15s apart and the trust ladder
-- arbitrated between a right answer and a wrong one.
--
-- The LOCAL rule (A4.1) additionally says a Rend hand-in never anchors by
-- itself: we park the name and let the FOLLOWING yell anchor, because a hand-in
-- that never produces a buff (raid wipes, someone else beat us to it server-
-- side) must not put us on a phantom 3h cooldown. A remote report cannot use the
-- stash — its yell, if any, is heard by someone else — so it takes the matching
-- rule: it is accepted ONLY while no local hand-in of ours is pending. If one
-- is, our own yell is seconds away carrying a better epoch and better
-- attribution, and this report would just be a worse duplicate of it.
--
-- LOCAL hand-ins deliberately do NOT route here: Timers.OnQuestHandin sees the
-- hand-in as it happens and owns the stash/alert/zone rules.
local HANDIN_LEAD = 15
Timers.HANDIN_LEAD = HANDIN_LEAD

-- Assumed DROP epoch for a hand-in reported at `handinEpoch` (pure).
function Timers.AssumedDropEpoch(handinEpoch)
    return (tonumber(handinEpoch) or 0) + HANDIN_LEAD
end

-- Apply a hand-in reported by a REMOTE source. `handinEpoch` is the RAW hand-in
-- time; the lead is applied here so no caller can double-apply it. Records as
-- kind "quest" (so the store log still marks it a hand-in) and never bars.
function Timers.RecordHandinReport(buffKey, handinEpoch, trust, who, zone, t)
    handinEpoch = tonumber(handinEpoch)
    if not handinEpoch or handinEpoch <= 0 then return false, "no hand-in epoch" end
    if Timers.HandinPending(buffKey, t) then
        return false, "local hand-in pending (its yell anchors)"
    end
    return Timers.Record(buffKey, Timers.AssumedDropEpoch(handinEpoch), trust, who,
                         "quest", zone, nil, nil, { noPull = true })
end

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

-- Zones where an announcer death is valid, PER ANNOUNCER (NWB §2.9: Runthak and
-- Saurfang are accepted in zones 1454/1411 — Orgrimmar and Durotar — while
-- Mattingly, Afrasiabi and Stonebridge are accepted in 1453/1429 — Stormwind
-- City and Elwynn Forest). The surrounding zone belongs in the set because
-- GetRealZoneText reads the PARENT zone at the city edge, which is exactly where
-- a raid fighting its way in is standing.
--
-- THE PAIRING IS THE POINT, and the old flat set did not pair: it accepted any
-- announcer in any capital, so a "Major Mattingly" death reported from Orgrimmar
-- counted as an Alliance-Onyxia announcer kill. Each announcer is now believed
-- only in its own city.
local HORDE_ANNOUNCER_ZONES = {
    ["orgrimmar"] = true,
    ["durotar"]   = true,
}
local ALLIANCE_ANNOUNCER_ZONES = {
    ["stormwind city"] = true,
    ["stormwind"]      = true,
    ["elwynn forest"]  = true,
}
Timers._hordeAnnouncerZones    = HORDE_ANNOUNCER_ZONES
Timers._allianceAnnouncerZones = ALLIANCE_ANNOUNCER_ZONES

-- Union of the two, kept because `Timers._capitalZones` is a published surface.
local CAPITAL_ZONES = {}
for z in pairs(HORDE_ANNOUNCER_ZONES)    do CAPITAL_ZONES[z] = true end
for z in pairs(ALLIANCE_ANNOUNCER_ZONES) do CAPITAL_ZONES[z] = true end
Timers._capitalZones = CAPITAL_ZONES

-- May `zone` legally host `buffKey`'s announcer dying? Pure, so the self-tests
-- drive the whole matrix headless.
--
-- THE H/A SUFFIX IS THE ANNOUNCER'S FACTION, NEVER THE WITNESS'S. Runthak is
-- `onyH` whoever watches him die, and both ways round happen for real: an
-- Alliance raid pushing into Orgrimmar to deny the buff, and — the way it
-- actually happened on 2026-08-03 — an Alliance priest MIND-CONTROLLING Runthak
-- so a HORDE raid could kill their own announcer and force the respawn. Nothing
-- in this detector may consult the witness's faction, and nothing may consult
-- the target's reaction or attackability either: under mind control Runthak is a
-- friendly, charmed NPC and he is still the announcer. Creature id and name are
-- the only things that survive a charm, so they are the only things we read.
-- (The reference is aware of the trick — NWB §2.9 has a whole SPELL_DISPEL path
-- for Mind Control on the announcers — but states no reaction filter either way,
-- so we exceed it deliberately and on purpose.)
function Timers.AnnouncerZoneOK(buffKey, zone)
    if not buffKey then return false end
    local set = (buffKey:sub(-1) == "A") and ALLIANCE_ANNOUNCER_ZONES
                                          or HORDE_ANNOUNCER_ZONES
    return set[tostring(zone or ""):lower()] == true
end

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

-- Combat-log fan-out. TWO independent consumers ride this event now: the capital
-- announcer-death detector here, and the Felwood presence / songflower witness
-- engine further down the file. The old early `if not inCapital() then return`
-- meant nothing outside Orgrimmar or Stormwind ever reached the combat log at
-- all, so the Felwood half has to run BEFORE that gate.
--
-- CLEU payload order (Interface 11509):
--   1 timestamp · 2 subevent · 3 hideCaster · 4 sourceGUID · 5 sourceName
--   6 sourceFlags · 7 sourceRaidFlags · 8 destGUID · 9 destName · 10 destFlags
--   11 destRaidFlags · 12 spellID · 13 spellName · ...
local function onCombatLog()
    if not CombatLogGetCurrentEventInfo then return end
    local _, subevent, _, sourceGUID, sourceName, _, _,
          destGUID, destName, destFlags, _, spellID = CombatLogGetCurrentEventInfo()

    -- Felwood engine (resolved at call time; it is defined below this point).
    if Timers.FelwoodCombatLog then
        Timers.FelwoodCombatLog(subevent, sourceGUID, sourceName,
                                destGUID, destName, destFlags, spellID)
    end

    if subevent ~= "UNIT_DIED" and subevent ~= "PARTY_KILL" then return end
    -- Resolve the announcer FIRST, then gate on that announcer's own city. The
    -- old order asked "am I in a capital" before knowing whose death this was,
    -- which is how any announcer came to be believed in any capital.
    --
    -- destFlags is read off the payload above and deliberately IGNORED here: the
    -- reaction bits flip when the NPC is mind-controlled, and an MC'd announcer
    -- dying is a first-class case, not an anomaly (see AnnouncerZoneOK).
    local npcID = npcIDFromGUID(destGUID)
    local buffKey = announcerBuffFor(npcID, destName)
    if not buffKey then return end
    if not Timers.AnnouncerZoneOK(buffKey, GetRealZoneText and GetRealZoneText() or "") then
        return
    end
    Timers.OnAnnouncerDeath(buffKey, destName)
end
-- Exposed so the self-tests can drive a synthetic combat-log death end-to-end
-- (stubbed CombatLogGetCurrentEventInfo + GetRealZoneText) rather than calling
-- OnAnnouncerDeath directly and leaving the gates themselves untested.
Timers._onCombatLog = onCombatLog

-- Generation token per buff for the armed respawn alert (F6). A second kill of
-- the same announcer must cancel the first arm rather than fire two alerts.
Timers._respawnGen = {}

-- An announcer death is a RESPAWN event, not a cooldown start: it logs a
-- `killed` entry, alerts, and broadcasts, and the readout becomes
-- "NPC killed — respawns in <t>" for 360s and then the 120s random window
-- (A3.1 + F12). It raises no pull bar (Record only bars on a pop).
--
-- F6 — the alerts matrix has an `npcRespawned` category and NOTHING ever fired
-- it: we announced the death and then went silent through the entire respawn,
-- so the one moment the player actually cares about (the announcer is back, go
-- hand in) never reached them. The arm is a plain C_Timer.After at the end of
-- the certain-dead phase, guarded by a per-buff generation token exactly as the
-- CD-warning scheduler is, so a re-kill or a state reset cancels it.
function Timers.OnAnnouncerDeath(buffKey, destName, t)
    t = t or now()
    local applied = Timers.Record(buffKey, t, "local", destName, "killed",
                                  GetRealZoneText and GetRealZoneText() or nil)
    notify(buffKey, "npcDied",
        (destName or buffLabelOf(buffKey)) .. " was killed — respawns in about 6 minutes.")
    if applied then Timers.ArmRespawnAlert(buffKey, destName, t) end
    return true
end

-- Arm the npcRespawned alert for the end of the certain-dead phase. Exposed so
-- the self-tests can drive it with a stubbed C_Timer.
function Timers.ArmRespawnAlert(buffKey, destName, t)
    local gen = (Timers._respawnGen[buffKey] or 0) + 1
    Timers._respawnGen[buffKey] = gen
    if not (C_Timer and C_Timer.After) then return false end
    local delay = (t or now()) + ANNOUNCER_RESPAWN - now()
    if delay < 0 then delay = 0 end
    C_Timer.After(delay, function()
        -- Stale arm guard: a newer kill (or a state reset) re-seeded this buff.
        if Timers._respawnGen[buffKey] ~= gen then return end
        notify(buffKey, "npcRespawned",
            (destName or buffLabelOf(buffKey))
            .. " is due back — respawning at a random time in the next 2 minutes.")
    end)
    return true
end

----------------------------------------------------------------------
-- Detector 3 — QUEST_TURNED_IN hand-in ids
----------------------------------------------------------------------

-- questID -> buffKey (H/A resolved for ony/nef where the id is faction-fixed).
--
-- FACTION SPLIT — settled from GAME DATA, not from an addon. The canonical
-- world-buff addon maps BOTH ids of each pair to the same buff type and carries
-- no faction annotation anywhere, so it is no evidence either way (and the way
-- the six ids happen to line-wrap in it actively baits a wrong reading). Ground
-- truth from the classic quest database, verified 2026-07-31:
--
--   7491  "For All To See"          Overlord Runthak,    Orgrimmar  -> Ony HORDE
--   7496  "Celebrating Good Times"  Major Mattingly,     Stormwind  -> Ony ALLIANCE
--   7782  "The Lord of Blackrock"   Field Marshal Stonebridge       -> Nef ALLIANCE
--   7784  "The Lord of Blackrock"   High Overlord Saurfang          -> Nef HORDE
--
-- A previous pass swapped BOTH pairs on the strength of the other reference's
-- spec text. Only the NEF pair was ever wrong and it is now right; the ONY pair
-- is swapped BACK here, because the swap credited every Onyxia head turn-in to
-- the opposing faction's timer.
local HANDIN_QUEST = {
    [4974] = "rend",
    [7491] = "onyH",  [7496] = "onyA",
    [7782] = "nefA",  [7784] = "nefH",
    [8183] = "zg",
}
Timers._handinQuest = HANDIN_QUEST

-- Hand-ins whose processing is SUPPRESSED while the buff is already on
-- cooldown (A4.2). Nefarian and Zandalar are never suppressed: Nef's cooldown is
-- disabled outright on Era (CD table above) and ZG keeps no pop log. A Nef
-- hand-in therefore still ALERTS — it just no longer anchors anything, because
-- Record refuses a pop for a cooldown-disabled type.
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

----------------------------------------------------------------------
-- Local buff GAIN (F6) — spec §11
--
-- The buff landing on US is the highest-confidence observation this addon can
-- make: no yell to parse, no relay to trust, the aura is on the player frame.
-- Two things were missing from it.
--
--  1. `BUFF_GAIN` was a seam with no producer. hud.lua has listened for it
--     since A12.4 (its alerts matrix carries a buffGain category); nothing ever
--     fired it, so "you got the buff" was the one event the alert framework
--     could not report. We fire it here, after crediting the pull observation,
--     with the buff key and the label so the HUD can alert without a lookup.
--
--  2. The gain never reached the pop log. Spec §11: gaining Rend or Onyxia
--     locally also adds a log entry, DEDUPLICATED against the mesh/third-party
--     sources. The store's own dedup is (epoch within 30s AND same `who`), and
--     a gain's `who` is the player while the pop's `who` is the announcer — so
--     handing it straight to AddTimerLog would double-log every witnessed drop.
--     We therefore dedup on TIME ALONE here: the entry is written only when no
--     existing entry already covers that moment, which makes this a BACKFILL —
--     it records the drops nobody reported, and stays silent for the ones
--     already logged. Nefarian/ZG have no store log and are skipped by
--     STORE_LOG_KEY, exactly as everywhere else.
--
-- No anchor is written: the aura is proof the buff exists, not proof of WHEN it
-- dropped (a chronoboon restore, a summon, a late relog all land the same aura),
-- and the pop path already owns the anchor. The unboon window is filtered before
-- we are ever called.
----------------------------------------------------------------------

-- Dedup window for the gain backfill; matches the store's own log dedup.
local GAIN_LOG_DEDUP = 30
Timers.GAIN_LOG_DEDUP = GAIN_LOG_DEDUP

-- True when the store's log for this buff already carries an entry within
-- GAIN_LOG_DEDUP of `epoch` (from ANY source: local yell, mesh, SN, NWB).
local function logCoversMoment(logKey, epoch)
    if not (ns.Store and ns.Store.GetTimers) then return true end   -- no store: never log
    local timers = ns.Store.GetTimers()
    local list = timers and timers.logs and timers.logs[logKey]
    if type(list) ~= "table" then return false end
    for i = 1, #list do
        if math.abs((list[i].epoch or 0) - epoch) <= GAIN_LOG_DEDUP then return true end
    end
    return false
end

-- Fire BUFF_GAIN and backfill the pop log for a world buff that just landed on
-- the player. Returns true when the log entry was written.
function Timers.NoteLocalBuffGain(buffKey, landTime)
    landTime = landTime or now()
    ns:Fire("BUFF_GAIN", buffKey, buffLabelOf(buffKey) .. " landed on you.", landTime)
    local logKey = STORE_LOG_KEY[buffKey]
    if not (logKey and ns.Store and ns.Store.AddTimerLog) then return false end
    if logCoversMoment(logKey, landTime) then return false end
    local who = (UnitName and UnitName("player")) or "you"
    return ns.Store.AddTimerLog(logKey, {
        epoch = landTime, who = who, trust = "local", gain = true,
    }) and true or false
end

-- Is a boonable buff appearing right now a chronoboon RESTORE rather than a
-- genuine fresh pickup? Spec §13: "a booned -> live transition is NEVER fresh,
-- and boonable slots gaining during the 3 s unboon window are excluded."
--
-- tracker.lua owns the window (it stamps Tracker._unboonUntil on the unboon
-- cast and exposes Tracker.InUnboonWindow). Called with NO argument on purpose:
-- the window is stamped in FRAME time (GetTime), whereas timers' now() is the
-- server epoch, so we let the tracker read its own clock.
--
-- Fully guarded: tracker.lua loads before timers.lua in the .toc, but headless
-- and partial loads may not have it, and a missing tracker must read as "not in
-- an unboon window" (i.e. behave exactly as before this gate existed).
local function inUnboonWindow()
    local T = ns.Tracker
    if not (T and T.InUnboonWindow) then return false end
    local ok, res = pcall(T.InUnboonWindow)
    return (ok and res) and true or false
end
Timers._inUnboonWindow = inUnboonWindow

-- UNIT_AURA handler: on a player aura change, if any pull is pending, scan the
-- player's buffs for a landed pull aura and credit its calibration. Cheap no-op
-- when nothing is pending. Uses the proven C_UnitAuras surface.
local function onPlayerAura(event, unit)
    if unit and unit ~= "player" then return end
    if next(Timers._pendingPull) == nil then return end
    -- Unboon restore: the aura reappears looking exactly like a real drop, so
    -- crediting it would poison the observed pull-window median with a ~0 s
    -- sample (and, once the BUFF_GAIN seam is fed, fire a bogus "gained" alert).
    -- We return WITHOUT consuming _pendingPull, so a genuine landing that
    -- follows the window still calibrates normally.
    if inUnboonWindow() then return end
    if not (C_UnitAuras and C_UnitAuras.GetBuffDataByIndex) then return end
    local landTime = now()
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if not aura then break end
        local nm = auraNorm(aura.name)
        for prefix in pairs(PULL_AURA_CANDIDATES) do
            if nm:find(prefix, 1, true) == 1 then
                -- creditPullLand resolves WHICH buff this aura belongs to by the
                -- pending-pull gate (Ony and Nef share one aura), so the gain
                -- alert + log backfill hang off its verdict and inherit the same
                -- attribution — never firing when we cannot say which buff it was.
                local credited = creditPullLand(prefix, landTime)
                if credited then
                    ns:SafeCall(Timers.NoteLocalBuffGain, credited, landTime)
                end
            end
        end
    end
end
Timers._onPlayerAura = onPlayerAura   -- exposed so the unboon gate is testable

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

-- Post-respawn grace band (seconds) in which a node is still displayed, with a
-- NEGATIVE countdown ("-M:SS"), before it goes "stale". The reference's
-- "show expired timers" setting is 5 minutes by default (NWB_BEHAVIOR_SPEC
-- §6.4, state 3: "the window is 0 to -300 s"), so 300 is our default too.
local FLOWER_EXPIRED_WINDOW = 300
Timers.FLOWER_EXPIRED_WINDOW = FLOWER_EXPIRED_WINDOW

-- Minimum "newer-ness" a NETWORK node epoch must have over the stored one
-- before it may overwrite. NWB_BEHAVIOR_SPEC §5.7 rejects an incoming timestamp
-- within +/-10 s of the same key on any layer (the cross-layer duplicate guard,
-- +/-30 s for non-flower keys), and separately refuses an incoming timer that is
-- "less than 25 s newer (10 s for songflowers)". Both land on 10 s for nodes,
-- which is what this constant enforces on every inbound path.
local NODE_NET_MIN_NEWER = 10
Timers.NODE_NET_MIN_NEWER = NODE_NET_MIN_NEWER

-- Standard opts for any node write that did NOT come from our own eyes.
-- `localHoldGuard` = a locally-observed pick owns its node for the FULL respawn:
-- we stood there, we saw the cast/loot/aura, and no second-hand report inside
-- those 25 minutes can be more accurate than that. `minNewer` is the +/-10 s
-- duplicate guard above.
local function netNodeOpts()
    return { localHoldGuard = NODE_RESPAWN, minNewer = NODE_NET_MIN_NEWER }
end
Timers._netNodeOpts = netNodeOpts

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
    -- CUMULATIVE songflower-ingest totals since login. `lastApplied` carries the
    -- same keys for the LAST payload only, and that snapshot is routinely empty
    -- (a `settings` payload carries no flowers at all), which makes it useless
    -- for answering "has the wire ever given me a flower?". These never reset.
    flowerTotals = {
        flowerHeard = 0, flowerApplied = 0, flowerFilled = 0, layersScanned = 0,
        rejGuard = 0, rejMinNewer = 0, rejOlder = 0, rejLayerSkip = 0,
    },
}

-- Counter names shared by the per-payload `applied` table and the cumulative
-- totals above, in print order.
local FLOWER_COUNTERS = {
    "flowerHeard", "flowerApplied", "flowerFilled", "layersScanned",
    "rejGuard", "rejMinNewer", "rejOlder", "rejLayerSkip",
}
Timers._flowerCounters = FLOWER_COUNTERS

local function nwbBump(path, key)
    local t = Timers._nwbStats[path]
    if type(t) == "table" then t[key] = (t[key] or 0) + 1 end
end

-- Bump one flower counter on BOTH the per-payload table and the session totals.
local function bumpFlower(applied, key)
    if type(applied) == "table" then applied[key] = (applied[key] or 0) + 1 end
    local tot = Timers._nwbStats.flowerTotals
    if type(tot) == "table" then tot[key] = (tot[key] or 0) + 1 end
end
Timers._bumpFlower = bumpFlower

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

----------------------------------------------------------------------
-- Inbound epoch validation  (the ingest hardening)
--
-- Our only sanity guard used to be `> 1e9`, which meant a single malformed or
-- hostile sender could plant a cooldown we would then display for hours — a
-- phantom that never clears. The reference applies a layered set of rejections
-- and we now apply the same ones.
----------------------------------------------------------------------

-- Absolute epoch ceiling (~year 2051) and a generic "not this far ahead" slack.
local EPOCH_CEILING = 2585912598
local FUTURE_SLACK  = 30000

-- Per-type future clamp: each is that type's real cooldown + 60s of slack.
-- Nef uses its TRUE 8h base here (not our disabled 0) because the clamp is a
-- wire-sanity bound on what a sender could legitimately claim; the Nef value is
-- rejected later regardless, by the cooldown-disabled rule.
local FUTURE_CLAMP = {
    rend = 10800 + 60,
    onyH = 21600 + 60, onyA = 21600 + 60,
    nefH = 28800 + 60, nefA = 28800 + 60,
    node = 1500 + 30,
}
Timers.FUTURE_CLAMP = FUTURE_CLAMP

-- Yell-vs-drop agreement window. A claimed drop whose accompanying stage-1 yell
-- epoch sits more than this many seconds on EITHER side of it did not happen the
-- way the sender says it did, and that buff is stripped from the payload. The
-- direction matters and it is symmetric: the reference rejects a stage-1 yell
-- more than 120s BEFORE the claimed drop and, separately, more than 120s AFTER
-- it. (A real drop follows its yell by 6-15s.)
local YELL_DROP_TOLERANCE = 120
Timers.YELL_DROP_TOLERANCE = YELL_DROP_TOLERANCE

-- Read a numeric epoch from a payload short-key, tolerating string values, and
-- apply the universal sanity rules: numeric, above the epoch floor, at or below
-- the absolute ceiling, and not absurdly in the future. `clampKey` (a buff key
-- or "node") additionally applies the per-type future clamp.
local function nwbEpoch(v, clampKey, t)
    local n = tonumber(v)
    if not n or n <= 1000000000 then return nil end   -- sane epoch floor
    if n > EPOCH_CEILING then return nil end
    t = t or now()
    if n > t + FUTURE_SLACK then return nil end
    local clamp = clampKey and FUTURE_CLAMP[clampKey]
    if clamp and n > t + clamp then return nil end
    return n
end
Timers._nwbEpoch = nwbEpoch

-- Wire layout of the three drop epochs and their companion stage-1 yell epochs.
-- The yell epochs are the entire point of the validation below, and we were
-- simply not reading them: they have been arriving as `o` / `t` / `z` all along.
-- (`t` is the Onyxia stage-1 yell; the tuber keys are `t1`..`t6` and do not
-- collide with it.)
local NWB_DROP_FIELDS = {
    { base = "rend", drop = "n", dropWord = "rendTimer", yell1 = "o" },
    { base = "ony",  drop = "s", dropWord = "onyTimer",  yell1 = "t" },
    { base = "nef",  drop = "y", dropWord = "nefTimer",  yell1 = "z" },
}
Timers._nwbDropFields = NWB_DROP_FIELDS

-- Resolve a wire base type to our buff key.
local function dropBuffKey(base)
    if base == "rend" then return "rend" end
    return factionKey(base)
end

-- ANNOUNCER-DEATH EPOCHS ON THE WIRE (NWB §5.6): `x` = the Onyxia announcer,
-- `D` = the Nefarian announcer. We read NEITHER, so every kill an NWB-compat peer
-- broadcast was heard, decoded, and dropped on the floor — the receive half of
-- the same hole the local detector covers on the transmit side.
--
-- FACTION RESOLUTION IS DELIBERATELY DIFFERENT FROM THE LOCAL DETECTOR. NWB
-- carries ONE Onyxia announcer field and the receiver's own faction names it,
-- which is sound here because addon traffic is faction-segregated — a payload can
-- only have reached us from a same-faction player. So this path uses factionKey,
-- exactly as the DROP path beside it does. The local combat-log detector is the
-- opposite case: it is watching a specific NPC die in front of it and keys off
-- the ANNOUNCER's faction, because the witness may be either faction (or, as on
-- 2026-08-03, the same faction killing its own mind-controlled announcer).
local NWB_KILL_FIELDS = {
    { base = "ony", field = "x", word = "onyNpcDied" },
    { base = "nef", field = "D", word = "nefNpcDied" },
}
Timers._nwbKillFields = NWB_KILL_FIELDS

-- Receive rules for a RELAYED kill (NWB §3.4), all three of them:
--   * act only on a death 0..1800s old — older is history, not news;
--   * ignore it if we already hold a kill within 60s — the same event, relayed;
--   * ignore it if the buff DROPPED within the last 600s — something that drops
--     the buff cannot simultaneously be lying dead, so the report is stale or
--     wrong whichever way round it is.
-- Returns ok:boolean, reason:string. The reason is what `/nexus debug nwb` shows.
local NWB_KILL_MAX_AGE       = 1800
local NWB_KILL_DUP_WINDOW    = 60
local NWB_KILL_DROP_SUPPRESS = 600
Timers.NWB_KILL_MAX_AGE       = NWB_KILL_MAX_AGE
Timers.NWB_KILL_DUP_WINDOW    = NWB_KILL_DUP_WINDOW
Timers.NWB_KILL_DROP_SUPPRESS = NWB_KILL_DROP_SUPPRESS

function Timers.NWBKillAcceptable(buffKey, epoch, t)
    t = t or now()
    if not ANNOUNCER_BUFFS[buffKey] then return false, "not an announcer buff" end
    local age = t - (epoch or 0)
    if age < 0 then return false, "kill reported in the future" end
    if age > NWB_KILL_MAX_AGE then return false, "kill older than 1800s" end
    local s = Timers.state[buffKey]
    if s then
        if (s.killedAt or 0) > 0
           and math.abs(epoch - s.killedAt) <= NWB_KILL_DUP_WINDOW then
            return false, "duplicate of a kill we already hold"
        end
        if (s.lastPop or 0) > 0 and (t - s.lastPop) < NWB_KILL_DROP_SUPPRESS then
            return false, "the buff dropped within 600s (announcer is back)"
        end
    end
    return true, "ok"
end

-- Validate ONE data table's world-buff drops. Returns a result table:
--   { ok = boolean, reason = string|nil,
--     accept = { rend = epoch, ony = epoch, nef = epoch },
--     reject = { <base> = "reason" } }
--
-- Two distinct severities, exactly as the reference applies them:
--   * a drop epoch carried with NO accompanying stage-1 yell epoch discards the
--     WHOLE table (ok = false) — an unwitnessed drop invalidates the payload;
--   * a stage-1 yell more than ±120s from the claimed drop strips THAT BUFF only
--     and the rest of the table still merges.
function Timers.ValidateNWBDrops(tbl, t)
    local res = { ok = true, accept = {}, reject = {} }
    if type(tbl) ~= "table" then res.ok = false; res.reason = "not a table"; return res end
    t = t or now()
    for i = 1, #NWB_DROP_FIELDS do
        local f = NWB_DROP_FIELDS[i]
        local key  = dropBuffKey(f.base)
        local drop = nwbEpoch(tbl[f.drop], key, t) or nwbEpoch(tbl[f.dropWord], key, t)
        if drop then
            local yell1 = nwbEpoch(tbl[f.yell1], nil, t)
            if not yell1 then
                res.ok = false
                res.reason = "drop with no stage-1 yell epoch (" .. f.base .. ")"
                res.accept = {}
                return res
            end
            local delta = yell1 - drop
            if delta > YELL_DROP_TOLERANCE then
                res.reject[f.base] = "stage-1 yell >120s after the claimed drop"
            elseif delta < -YELL_DROP_TOLERANCE then
                res.reject[f.base] = "stage-1 yell >120s before the claimed drop"
            else
                res.accept[f.base] = drop
            end
        end
    end
    return res
end

----------------------------------------------------------------------
-- NWB timer-log ingestion  (the biggest ingest gap on a layered realm)
--
-- The bulk payload carries an array under key `F` of log entries shaped
--   G = entry type · H = timestamp · I = layer id · J = who
-- with types `r` = Rend drop, `o` = Onyxia drop, `n` = Nefarian drop and
-- `q` = quest hand-in.
--
-- Why this matters on Whitemane specifically: Whitemane is a LAYERED realm, and
-- on layered realms the reference logs Rend only (`r` and `q`) and then PREFERS
-- the log over the raw per-layer Rend timer, because the raw Rend timer is
-- unreliable post-hotfix (the yell fires on every layer and the buff source
-- carries the player's current layer, not the hand-in layer). So the log carries
-- the reference's own most-trusted Rend data — and we were walking straight past
-- it. Our defensive layer scan did iterate the array, but `G`/`H`/`I`/`J` collide
-- with none of the timer keys, so it extracted precisely nothing.
--
-- A `q` entry is a HAND-IN, not a drop: the reference converts it to an assumed
-- drop by adding 15s (measured ~13s plus 2s leeway). We do the same.
--
-- Everything routes through Timers.Record at trust "nwb", so the trust ladder
-- and the full-cooldown false-positive gate arbitrate exactly as for every other
-- source: a log entry can never outrank a local or mesh anchor, and a duplicate
-- inside the cooldown window is rejected rather than re-anchoring.
----------------------------------------------------------------------

local NWB_LOG_KEY   = "F"
local NWB_LOG_TYPE  = "G"
local NWB_LOG_TIME  = "H"
local NWB_LOG_LAYER = "I"
local NWB_LOG_WHO   = "J"

-- Hand-in -> assumed drop offset (measured ~13s, +2s leeway). This is now ONE
-- constant shared by every hand-in path (F7); the old NWB-only name is kept as
-- an alias so nothing that referenced it breaks.
local NWB_HANDIN_LEAD = HANDIN_LEAD
Timers.NWB_HANDIN_LEAD = NWB_HANDIN_LEAD

-- Log entry type -> base buff, and whether the timestamp is a hand-in rather
-- than a drop. Nefarian entries are parsed so they can be explicitly counted and
-- dropped rather than silently vanishing.
local NWB_LOG_ENTRY = {
    r = { base = "rend", handin = false },
    o = { base = "ony",  handin = false },
    n = { base = "nef",  handin = false },
    q = { base = "rend", handin = true  },
}
Timers._nwbLogEntry = NWB_LOG_ENTRY

-- Parse ONE log entry. Returns buffKey, epoch, who, layerID, isHandin — or nil.
--
-- `epoch` is the RAW logged timestamp. The hand-in -> assumed-drop lead is NOT
-- applied here any more (F7): the caller learns it is looking at a hand-in from
-- the fifth return and routes it through the one hand-in path, so the lead
-- cannot be applied twice or forgotten on a new path.
function Timers.ParseNWBLogEntry(entry, t)
    if type(entry) ~= "table" then return nil end
    local meta = NWB_LOG_ENTRY[entry[NWB_LOG_TYPE]]
    if not meta then return nil end
    local buffKey = dropBuffKey(meta.base)
    local epoch = nwbEpoch(entry[NWB_LOG_TIME], buffKey, t)
    if not epoch then return nil end
    local who = entry[NWB_LOG_WHO]
    return buffKey, epoch, (type(who) == "string" and who) or nil,
           entry[NWB_LOG_LAYER], meta.handin == true
end

-- Walk the `F` array of one data table. Returns the number of entries parsed.
--
-- F1 — PRE-SCAN, THEN RECORD ONCE PER BUFF. This used to Record EVERY entry in
-- wire order, which was wrong in both directions: the newest entry raced the
-- older ones through the false-positive gate (so which anchor survived depended
-- on array order, not on time), and an older entry arriving last could rewind a
-- fresh anchor outright. A log is a HISTORY, and the only thing in it that can
-- inform the current anchor is its newest entry per buff — which is exactly the
-- policy snbridge already applies to SN's log arrays. So: scan the whole array,
-- keep max(epoch) per buff, and hand Record that one value.
--
-- Hand-in entries compete on their ASSUMED DROP epoch (raw + lead), because that
-- is the moment they are claiming; whichever kind wins is then applied through
-- its own path, so a winning hand-in still gets the stash rule.
function Timers.IngestNWBTimerLog(tbl, applied, t)
    applied = applied or {}
    t = t or now()
    local log = (type(tbl) == "table") and tbl[NWB_LOG_KEY] or nil
    if type(log) ~= "table" then return 0 end
    local parsed = 0
    local best = {}   -- buffKey -> { epoch, raw, who, handin }

    for _, entry in ipairs(log) do
        local buffKey, epoch, who, _, isHandin = Timers.ParseNWBLogEntry(entry, t)
        if buffKey then
            parsed = parsed + 1
            if cdDisabled(buffKey) then
                -- Nefarian log entries go the same way as Nefarian timers on Era.
                applied.nefRejected = (applied.nefRejected or 0) + 1
            else
                local effective = isHandin and Timers.AssumedDropEpoch(epoch) or epoch
                local cur = best[buffKey]
                if not cur or effective > cur.epoch then
                    best[buffKey] = { epoch = effective, raw = epoch,
                                      who = who, handin = isHandin }
                end
            end
        end
    end

    for buffKey, b in pairs(best) do
        applied.log = (applied.log or 0) + 1
        local ok
        if b.handin then
            ok = Timers.RecordHandinReport(buffKey, b.raw, "nwb",
                                           b.who or "NWB log", nil, t)
        else
            ok = Timers.Record(buffKey, b.epoch, "nwb", b.who or "NWB log", "pop")
        end
        if ok then applied.logApplied = (applied.logApplied or 0) + 1 end
    end
    return parsed
end

-- Node-read modes for readNWBTimerFields (below).
--   FULL  — a TOP-LEVEL payload: read flowers, tubers and dragons, trust "nwb".
--   LAYER — a per-layer sub-table: FLOWERS ONLY, and collected into a caller
--           supplied accumulator instead of written straight through. See
--           Timers.IngestNWBTimers for why the write is deferred.
local NODE_MODE_FULL  = "full"
local NODE_MODE_LAYER = "layer"
Timers.NODE_MODE_FULL, Timers.NODE_MODE_LAYER = NODE_MODE_FULL, NODE_MODE_LAYER

-- Was a flower field present on the wire at all, under either key spelling?
local function rawFlowerField(tbl, i)
    local v = tbl["f" .. i]
    if v == nil then v = tbl["flower" .. i] end
    return v
end

-- Apply ONE inbound flower epoch and attribute the outcome to the diagnostic
-- counters. `trust` is "nwb" for a top-level field and "nwbLayer" for one that
-- came out of a per-layer sub-table. Every write carries the standard network
-- guards: a local pick owns its node for the full respawn, and an epoch within
-- 10s of the stored one is a cross-source duplicate.
local function applyFlowerEpoch(applied, index, epoch, trust)
    local prev = (Timers.NodePopEpoch and Timers.NodePopEpoch("flower", index)) or 0
    local ok, why = Timers.MarkNode("flower", index, epoch, trust, netNodeOpts())
    if ok then
        -- `applied.flower` is the long-standing "something merged" counter and
        -- keeps its meaning; the rest are the new diagnostic breakdown.
        applied.flower = (applied.flower or 0) + 1
        bumpFlower(applied, "flowerApplied")
        -- The whole point of the layer fix: this node read "No data" a moment
        -- ago and now does not.
        if prev == 0 then bumpFlower(applied, "flowerFilled") end
    elseif why == "localHold" or why == "overwriteGuard" then
        bumpFlower(applied, "rejGuard")
    elseif why == "minNewer" then
        bumpFlower(applied, "rejMinNewer")
    elseif why == "older" then
        bumpFlower(applied, "rejOlder")
    end
    return ok
end
Timers._applyFlowerEpoch = applyFlowerEpoch

-- Read the world-buff + node timer fields out of ONE NWB data table. Wire SHORT
-- keys: n=rendTimer, s=onyTimer, y=nefTimer, o/t/z = the matching stage-1 yell
-- epochs, f1..f10=flower1..10, t1..t6=tuber1..6, F=timer log. We also tolerate
-- the WORD keys (rendTimer/onyTimer/nefTimer/flowerN/tuberN) in case a layer
-- sub-table was not key-compacted. ZG/Zandalar is NOT transmitted by NWB at all,
-- so there is no zan field to read. `applied` accumulates counts.
--
-- `nodeMode` selects the node behaviour (NODE_MODE_FULL, the default, or
-- NODE_MODE_LAYER). In LAYER mode `flowerAcc` receives index -> best epoch and
-- nothing is written to the store here.
--
-- Returns false when the whole table was discarded by drop validation.
local function readNWBTimerFields(tbl, applied, t, nodeMode, flowerAcc)
    if type(tbl) ~= "table" then return false end
    t = t or now()
    nodeMode = nodeMode or NODE_MODE_FULL

    -- F14 — FELWOOD AND THE TIMER LOG ARE READ FIRST, BEFORE the drop validation
    -- can reject the payload. ValidateNWBDrops guards the three world-buff DROP
    -- ANCHORS and nothing else: its whole-table rejection means "a claimed drop
    -- arrived without a witnessing yell", which says nothing whatsoever about the
    -- songflower and tuber epochs sitting in the same table, or about the Rend
    -- hand-in log — those fields have their own independent guards (MarkNode's
    -- local-hold + 10s duplicate gate, the log's own epoch sanity). Running the
    -- validation first meant ONE bad drop field silently discarded a payload's
    -- entire Felwood node set and its timer log, and on a layered realm that log
    -- is the most trustworthy Rend data the wire carries. Order is the whole fix;
    -- the validation itself is unchanged and still gates the anchors below.
    if nodeMode == NODE_MODE_LAYER then
        -- PER-LAYER SUB-TABLE — FLOWERS ONLY, and collected rather than written.
        --
        -- Flowers only: on a layered realm the reference keeps tubers (`t1`..`t6`)
        -- and dragons (`d1`..`d4`) as PERSONAL timers and never puts them on the
        -- wire (NWB_BEHAVIOR_SPEC L823-824 / L1157), so there is nothing to read
        -- for them here. They stay a top-level-only read: correct on a
        -- non-layered realm, a no-op on a layered one.
        --
        -- Collected rather than written: pairs() order over the layers map is
        -- undefined, and MarkNode's +/-10s guard makes a per-layer write
        -- order-dependent. See Timers.IngestNWBTimers.
        for i = 1, 10 do
            if rawFlowerField(tbl, i) ~= nil then bumpFlower(applied, "flowerHeard") end
            local e = nwbEpoch(tbl["f" .. i], "node", t) or nwbEpoch(tbl["flower" .. i], "node", t)
            if e and flowerAcc then
                local have = flowerAcc[i]
                if have == nil then
                    flowerAcc[i] = e
                elseif e > have then
                    flowerAcc[i] = e
                    bumpFlower(applied, "rejLayerSkip")   -- the older candidate loses
                else
                    bumpFlower(applied, "rejLayerSkip")   -- this candidate loses
                end
            end
        end
    else
        -- TOP-LEVEL PAYLOAD — the full node set, trust "nwb".
        for i = 1, 10 do
            if rawFlowerField(tbl, i) ~= nil then bumpFlower(applied, "flowerHeard") end
            local e = nwbEpoch(tbl["f" .. i], "node", t) or nwbEpoch(tbl["flower" .. i], "node", t)
            if e then applyFlowerEpoch(applied, i, e, "nwb") end
        end
        -- Tubers and dragons are read for completeness, but note the sharing
        -- rule: the reference keeps them as PERSONAL timers on layered realms
        -- and never puts them on the wire there. On Whitemane `t1`..`t6` and
        -- `d1`..`d4` will never arrive, so the loot detector below is the only
        -- way a tuber or dragon timer can ever exist there.
        for i = 1, 6 do
            local e = nwbEpoch(tbl["t" .. i], "node", t) or nwbEpoch(tbl["tuber" .. i], "node", t)
            if e and Timers.MarkNode("tuber", i, e, "nwb", netNodeOpts()) then
                applied.tuber = (applied.tuber or 0) + 1
            end
        end
        for i = 1, 4 do
            local e = nwbEpoch(tbl["d" .. i], "node", t) or nwbEpoch(tbl["dragon" .. i], "node", t)
            if e and Timers.MarkNode("dragon", i, e, "nwb", netNodeOpts()) then
                applied.dragon = (applied.dragon or 0) + 1
            end
        end
    end

    Timers.IngestNWBTimerLog(tbl, applied, t)

    -- ANNOUNCER DEATHS (NWB §3.4). Merged here, ALONGSIDE the timer log and
    -- BEFORE the drop-anchor validation below, because the whole-payload
    -- rejection is specifically about a drop epoch arriving without its witnessing
    -- stage-1 yell (NWB §5.7). A kill epoch has no yell to pair with and is not
    -- what that rule adjudicates — it merges on the same footing as the log.
    --
    -- Every outcome is counted so a dropped kill is VISIBLE in `/nexus debug nwb`
    -- instead of looking like a silent no-op, which is precisely how this gap
    -- stayed invisible: heard, decoded, discarded, nothing to see.
    for i = 1, #NWB_KILL_FIELDS do
        local kf = NWB_KILL_FIELDS[i]
        local killKey = dropBuffKey(kf.base)
        local killAt = nwbEpoch(tbl[kf.field], killKey, t)
                       or nwbEpoch(tbl[kf.word], killKey, t)
        if killAt then
            applied.killHeard = (applied.killHeard or 0) + 1
            local okKill, whyKill = Timers.NWBKillAcceptable(killKey, killAt, t)
            if okKill and Timers.Record(killKey, killAt, "nwb", "NWB", "killed") then
                applied.kill = (applied.kill or 0) + 1
            else
                applied.killRejected = (applied.killRejected or 0) + 1
                applied.killRejectReason = kf.base .. ": " .. (whyKill or "refused by Record")
            end
        end
    end

    -- Drop-anchor validation. Unchanged rules, now scoped to the three world-buff
    -- drop epochs it was always about: a whole-table rejection stops the ANCHORS,
    -- not the Felwood data and not the log, both of which merged above.
    local v = Timers.ValidateNWBDrops(tbl, t)
    if not v.ok then
        applied.rejectedPayload = (applied.rejectedPayload or 0) + 1
        applied.rejectReason = v.reason
        return false
    end
    for base, why in pairs(v.reject) do
        applied.rejectedYell = (applied.rejectedYell or 0) + 1
        applied.rejectReason = base .. ": " .. why
    end

    if v.accept.rend then
        Timers.Record("rend", v.accept.rend, "nwb", "NWB", "pop"); applied.rend = true
    end
    if v.accept.ony then
        Timers.Record(factionKey("ony"), v.accept.ony, "nwb", "NWB", "pop"); applied.ony = true
    end
    -- Nefarian: disabled on Era, so an inbound Nef timer is discarded outright.
    -- Record would refuse it anyway; counting it here makes the drop VISIBLE in
    -- `/nexus debug nwb` instead of looking like a silent no-op.
    if v.accept.nef then
        applied.nefRejected = (applied.nefRejected or 0) + 1
    end

    return true
end
Timers._readNWBTimerFields = readNWBTimerFields

-- Ingest a decoded NWB timer payload table. Handles BOTH flat (non-layered) and
-- LAYERED realms: on layered realms NWB nests per-layer timer tables one level
-- down under `layers`, which — unlike every timer key — is NOT key-compacted and
-- appears literally, so we read it directly. The old heuristic scan is kept only
-- as a fallback for a payload that lacks it, with the timer-log array excluded
-- so its entries can no longer be mistaken for layers.
--
-- We flatten layers deliberately FOR WORLD BUFFS: the reference flags world
-- buffs as shared across ALL layers globally and disables per-layer chat
-- labelling, so a buff genuinely drops on every layer at once. We hold no layer
-- model and must not present per-layer precision we cannot deliver.
--
-- SONGFLOWERS — THE FILL-AND-GUARD POLICY (supersedes ROUND-17 audit fix 3).
--
-- Fix 3 read node keys from the TOP-LEVEL payload only and ignored the per-layer
-- copies entirely, on the reasoning that "one layer's truth beats a blend of all
-- of them". The reasoning was sound about the BLEND and wrong about the
-- consequence: on a layered realm (Whitemane is one) nothing arrives flat, so
-- ignoring the layers meant ignoring every songflower the wire carries. The grid
-- read "No data" in all ten cells, forever. Zero data is not more accurate than
-- imperfect data; it is just less useful.
--
-- So per-layer flowers are read again, under a policy that is deliberately
-- narrow:
--
--   * A node we have NEVER seen (stored epoch 0) is FILLED. All three MarkNode
--     guards require a stored epoch > 0, so a fill passes freely. This is the
--     case that turns "No data" into a countdown.
--   * A node holding our OWN pick is untouchable for the full 1500s respawn —
--     `localHoldGuard` keys off the stored trust being "local". Layer data can
--     never outrank standing at the node and watching it get picked.
--   * A node holding second-hand data follows the ordinary network rule:
--     newest-wins, plus the +/-10s cross-source duplicate guard. Without this a
--     filled node could never be refreshed from the wire again and would simply
--     go stale.
--   * Layer-sourced writes record trust "nwbLayer", not "nwb", so a later local
--     observation is visibly an upgrade in `/nexus debug timers`.
--
-- HONEST RESIDUAL — read this before trusting a filled cell. We do not track
-- which layer WE are on, and NWB's payload does not tell us. A node filled from
-- the layers map therefore reflects a pick that happened on SOME layer, not
-- necessarily ours; walk to it and it may already be up, or still be down when
-- we said it was up. That is the trade this policy makes on purpose — some data
-- beats none, and a local observation always wins outright the moment we make
-- one. Full per-layer node tracking (our own layer id, ten timers per layer)
-- is out of scope; do not read the fill as a per-layer-accurate timer.
--
-- COLLECT-THEN-APPLY, and why it is not stylistic. pairs() order over the layers
-- map is undefined in Lua. Calling MarkNode once per layer would make the
-- outcome depend on that order: an earlier layer's epoch lands first, and the
-- +/-10s minNewer guard then blocks a later layer's genuinely newer one. It
-- would also fire NODE_UPDATED and maybeBroadcast() once per layer and put the
-- intermediate values on the mesh. So each layer pass only COLLECTS a candidate
-- epoch per node index; the newest across all layers is applied once, after the
-- loop. Deterministic regardless of iteration order.
function Timers.IngestNWBTimers(payload)
    if type(payload) ~= "table" then return end
    local applied = {}
    local t = now()
    readNWBTimerFields(payload, applied, t, NODE_MODE_FULL)

    -- Per-layer pass: flowers only, collected into `acc` (index -> best epoch).
    local acc = {}
    local layers = payload.layers
    if type(layers) == "table" then
        for _, layer in pairs(layers) do
            if type(layer) == "table" then bumpFlower(applied, "layersScanned") end
            readNWBTimerFields(layer, applied, t, NODE_MODE_LAYER, acc)
        end
    else
        for key, v in pairs(payload) do
            if key ~= NWB_LOG_KEY and type(v) == "table" then
                local looksLayerMap = false
                for _, lv in pairs(v) do
                    if type(lv) == "table" then looksLayerMap = true break end
                end
                if looksLayerMap then
                    for _, layer in pairs(v) do
                        if type(layer) == "table" then bumpFlower(applied, "layersScanned") end
                        readNWBTimerFields(layer, applied, t, NODE_MODE_LAYER, acc)
                    end
                end
            end
        end
    end
    -- ONE write per node index, with the newest epoch any layer offered.
    for i = 1, 10 do
        local e = acc[i]
        if e then applyFlowerEpoch(applied, i, e, "nwbLayer") end
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
                -- Count a payload as ingested only when something actually
                -- merged. `applied` now also carries REJECTION counters, so a
                -- non-empty table no longer implies we took anything from it.
                if applied and (applied.rend or applied.ony or (applied.flower or 0) > 0
                                or (applied.tuber or 0) > 0 or (applied.dragon or 0) > 0
                                or (applied.log or 0) > 0) then
                    stats.ingested = stats.ingested + 1
                end
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
        -- Node pick relayed from another NWB client. The event opcode carries
        -- only "<type> <layer>" — no node index and no epoch — so it cannot set
        -- a timer by itself (NWB_BEHAVIOR_SPEC §5.4: flower/flower2 "does not
        -- set a timer by itself").
        --
        -- ROUND-17 audit fix 4: what it IS, is a reliable signal that a flower
        -- was just picked somewhere and that the sender's full payload now has
        -- an index and epoch we lack. So we pull. RequestNWBData is 60s-cooled
        -- internally, which is what keeps a circuit-running guild from turning
        -- ten picks into ten requests.
        Timers._sawNWB = true
        ns:SafeCall(Timers.RequestNWBData)
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

-- Non-anchoring DBM observations (F2 + F5). buffKey -> { at, what }.
-- Diagnostic only: read by `/dsn debug timers`, never by the timer model.
Timers._dbmHint = {}

local function dbmHint(buffKey, what)
    Timers._dbmHint[buffKey] = { at = now(), what = what }
end
Timers._dbmNoteHint = dbmHint

-- DBM ingest is now entirely NON-ANCHORING. Both opcodes we read describe a RAID
-- BOSS, and neither describes a world-buff drop:
--
--   "K" (boss killed) — F2. This was recorded as kind "killed", which in our
--   model means "the ANNOUNCER died, start the 6-minute respawn". The creature
--   ids here are Onyxia 10184, Nefarian 11583, Hakkar 14834 and Rend Blackhand
--   10429: raid bosses, not announcers. So a guildmate's raid killing Onyxia
--   planted a phantom announcer respawn, and (through the old kill-wins readout)
--   could blank a live cooldown. Killing the boss is also NOT the drop — the
--   head still has to be turned in, minutes to hours later, by someone who may
--   not even be in that raid. So it records nothing at all.
--
--   "C" (combat start) — F5. This anchored a POP at RAID-PULL TIME, which is the
--   most confidently wrong timestamp available: it is before the boss dies,
--   before the head drops and long before any hand-in. A pull is not a pop.
--
-- Both survive as a hint the debug dump can show ("a raid is on Onyxia right
-- now"), which is the honest value of a D5 sync, and nothing else consumes them.
function Timers.OnDBMMessage(body)
    local m = Timers.ParseDBM(body)
    if not m then return end
    local op = m.opcode
    if op == "K" then
        -- "K": <creatureId>\t<difficulty>
        local cId = tonumber(m.args[1])
        local buffKey = cId and dbmCreatureToBuff(cId)
        if buffKey then dbmHint(buffKey, "bossKilled") end
    elseif op == "C" then
        -- "C": <delay>\t<modId>\t... — modId is a string boss-mod id; map by
        -- the creature id when it is numeric (Classic mods key on cId).
        local modId = tonumber(m.args[2])
        local buffKey = modId and dbmCreatureToBuff(modId)
        if buffKey then dbmHint(buffKey, "bossPulled") end
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
    -- Night Dragon's Breath (item 11952) — the third Felwood node type, wire
    -- keys `d1`..`d4`. Coordinates are the reference's (NWB_BEHAVIOR_SPEC §6.2,
    -- "Night Dragon's Breath nodes"); like the tuber list they are sourced from
    -- Wowhead and flagged upstream as possibly incomplete. Same 1500s respawn,
    -- same loot-line detection path as tubers, 2.0 map-percent match radius.
    dragon = {
        { x = 0.425, y = 0.139, label = "North-West of Irontree Woods" },
        { x = 0.506, y = 0.305, label = "South of Irontree Woods" },
        { x = 0.351, y = 0.590, label = "Jaedenar" },
        { x = 0.407, y = 0.783, label = "West of Emerald Sanctuary" },
    },
}

-- Node counts per kind, so the snapshot / debug / ingest loops stop hardcoding
-- 10 and 6 in five places (and so `dragon` cannot be forgotten in one of them).
Timers.NODE_COUNTS = { flower = 10, tuber = 6, dragon = 4 }

-- Per-node trust of the LAST write, keyed "flower3". One of:
--   "local"    our own eyes (cast / loot / own aura) — owns the node for 1500s
--   "nwb"      a TOP-LEVEL NWB payload field
--   "nwbLayer" an NWB per-layer sub-table field (see the fill-and-guard policy
--              on Timers.IngestNWBTimers: it may reflect another layer's pick)
--   "sn"       ShadowNetwork ingest / import
--   "mesh"     a Nexus peer snapshot
-- Feeds the localHoldGuard in MarkNode, which tests for "local" and nothing
-- else — the other values are diagnostic labels, not a ranking.
--
-- PERSISTED, deliberately: the whole point of the guard is that our own pick
-- owns its node for 25 minutes, and a /reload inside those 25 minutes must not
-- silently downgrade it back to stompable. It rides the timers data graph and is
-- created lazily on first touch — the same pattern (and the same reasoning) as
-- `pullObservations`, which store.lua documents as engine-created so it appears
-- on pre-existing saves. Falls back to a module-local table in a bare VM.
Timers._nodeTrustFallback = {}
local function nodeTrustTable()
    local t = ns.Store and ns.Store.GetTimers and ns.Store.GetTimers()
    if not t then return Timers._nodeTrustFallback end
    t.nodeTrust = t.nodeTrust or {}
    return t.nodeTrust
end
Timers._nodeTrust = setmetatable({}, {
    __index    = function(_, k) return nodeTrustTable()[k] end,
    __newindex = function(_, k, v) nodeTrustTable()[k] = v end,
})

-- Store key for a node kind: flower -> timers.flower, tuber -> timers.tuber.
local function nodePopTable(kind)
    local t = ns.Store and ns.Store.GetTimers and ns.Store.GetTimers()
    if not t then return nil end
    if kind == "flower" then return t.flower end
    if kind == "tuber"  then return t.tuber end
    if kind == "dragon" then
        -- Lazily created: `dragon` is new in this release, so a pre-existing SV
        -- has no such table and the store's defaults pass only backfills
        -- SETTINGS, not the data graph. Create on first touch.
        t.dragon = t.dragon or {}
        return t.dragon
    end
    return nil
end

-- Public read of a node's stored pop epoch; 0 when the node has never been seen.
-- The NWB ingest sits ABOVE nodePopTable's scope in this file and needs to know
-- whether a write is about to land on an EMPTY node, so it can count fills for
-- `/nexus debug nwb`. Exposed on the module table for that reason.
function Timers.NodePopEpoch(kind, index)
    local pops = nodePopTable(kind)
    return (pops and pops[index]) or 0
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
--
-- ROUND-17 (songflower accuracy, audit fix 1 + 6). Two changes:
--
-- 1. `respawn` is the REAL respawn length and callers must pass NODE_RESPAWN.
--    It used to double as a user-configurable "minus-timer duration", which is
--    what let an SN import (which copied SN's 120s minus-timer into that
--    setting) make every flower count 2 minutes and then read as available.
--    Respawn is a game constant — 1500s for flowers, tubers and dragons alike
--    (NWB_BEHAVIOR_SPEC §6.4: "exactly 1500 s ... No variance, no jitter, no
--    min/max") — so no setting may shorten it.
--
-- 2. There is no longer an indefinite "up" state. The reference has exactly
--    three display states and a respawned node reverts to "no timer" — it never
--    reads "up" forever, because after 25 minutes we simply do not know whether
--    anyone has picked it. `expiredWindow` (default FLOWER_EXPIRED_WINDOW) is
--    the post-respawn grace band in which we still show the node, counting
--    NEGATIVE so the consumer can render "-M:SS".
--
-- States:
--   "unknown" — no observation at all (stored epoch 0)
--   "down"    — picked, counting down; `remaining` > 0
--   "expired" — respawned within the last `expiredWindow`; `remaining` < 0
--   "stale"   — respawned longer ago than that; data too old to assert anything
--
-- `legacyState` projects the four onto the old three-state vocabulary
-- ("unknown"/"down"/"up") for consumers not yet migrated: "expired" -> "up"
-- (we are inside the grace band, it plausibly is up), "stale" -> "unknown" (the
-- observation is too old to claim anything). Consumers should prefer `state`.
function Timers.NodeState(popEpoch, t, respawn, expiredWindow)
    respawn = respawn or NODE_RESPAWN
    if expiredWindow == nil then expiredWindow = FLOWER_EXPIRED_WINDOW end
    if not popEpoch or popEpoch <= 0 then
        return { state = "unknown", legacyState = "unknown", remaining = 0, since = 0 }
    end
    local elapsed = t - popEpoch
    if elapsed < respawn then
        return { state = "down", legacyState = "down",
                 remaining = respawn - elapsed, since = elapsed }
    end
    local sinceUp = elapsed - respawn
    if expiredWindow > 0 and sinceUp < expiredWindow then
        -- NEGATIVE remaining: the renderer formats it as "-M:SS".
        return { state = "expired", legacyState = "up",
                 remaining = -sinceUp, since = sinceUp }
    end
    return { state = "stale", legacyState = "unknown", remaining = 0, since = sinceUp }
end

-- Record a node pick. kind ∈ "flower"/"tuber", index 1-based. Applies a
-- simple freshness gate (ignore a stale duplicate of the same pop) and
-- fires NODE_UPDATED.
--
-- `opts.overwriteGuard` (seconds) additionally refuses to overwrite a stored
-- timer that is still young. The reference applies exactly this to its two
-- second-hand observations: 1500s for a looted tuber (a live node cannot
-- legitimately be picked again inside its own respawn, so a second loot line is
-- a duplicate) and 1440s for ANOTHER player's songflower pick (their pick is
-- heuristic, so it must not stomp a fresher record). Our OWN songflower pick
-- passes no guard — it is position- and spell-validated and should win outright.
--
-- Returns true on a write. On a refusal it returns false PLUS a reason string
-- ("older" / "overwriteGuard" / "localHold" / "minNewer" / "noStore") so the NWB
-- ingest can attribute its rejections in `/nexus debug nwb`. Every existing
-- caller uses the result in boolean or `== true` / `== false` context, or
-- parenthesises the tail call, so the extra value is inert for all of them.
function Timers.MarkNode(kind, index, epoch, trust, opts)
    local pops = nodePopTable(kind)
    if not pops then return false, "noStore" end
    epoch = epoch or now()
    local prev = pops[index] or 0
    -- Ignore an older or identical epoch (dup relay); accept fresher picks.
    if epoch <= prev then return false, "older" end
    local guard = opts and opts.overwriteGuard
    if guard and prev > 0 and (epoch - prev) < guard then return false, "overwriteGuard" end
    -- ROUND-17 audit fix 2: a locally-observed pick OWNS its node for the full
    -- respawn. Our own pick is position- and spell/loot-validated; every network
    -- report of the same node inside those 25 minutes is either the same pick
    -- relayed back to us or someone's heuristic guess, and neither may stomp it.
    -- Keyed off the trust recorded WITH the stored value, so this costs nothing
    -- when the stored value was itself second-hand.
    local hold = opts and opts.localHoldGuard
    if hold and prev > 0 and (epoch - prev) < hold
       and Timers._nodeTrust[kind .. index] == "local" then
        return false, "localHold"
    end
    -- +/-10 s cross-source duplicate guard (NWB_BEHAVIOR_SPEC §5.7). The `<=`
    -- test above already covers the "older" half of the window.
    local minNewer = opts and opts.minNewer
    if minNewer and prev > 0 and (epoch - prev) < minNewer then return false, "minNewer" end
    pops[index] = epoch
    Timers._nodeTrust[kind .. index] = trust
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

-- The configurable post-respawn "expired" window, in seconds. Clamped so a
-- corrupt or SN-imported value cannot produce a nonsense band.
function Timers.ExpiredWindow()
    local fw = felwoodSettings()
    local v = tonumber(fw.flowerExpiredWindow)
    if not v then return FLOWER_EXPIRED_WINDOW end
    if v < 0 then return 0 end
    if v > 900 then return 900 end
    return v
end

-- Public: current state for a node key like "flower3" / "tuber2" / "dragon1".
--
-- ROUND-17 audit fix 1 — THE headline bug. This used to read
-- `felwood.flowerMinusDuration` as the RESPAWN LENGTH. import.lua copied SN's
-- `flowerMinusTimerDuration` (120s on a stock SN install) straight into that
-- key, so after an SN import every songflower counted down ~2 minutes and then
-- reported itself available — "timers don't seem accurate". The respawn is a
-- game constant and is now ALWAYS NODE_RESPAWN; the only thing a setting may
-- move is the post-respawn expired window.
function Timers.GetNodeState(nodeKey)
    local kind, idxStr = nodeKey:match("^(%a+)(%d+)$")
    local index = tonumber(idxStr)
    if not kind or not index then return nil end
    local pops = nodePopTable(kind)
    local popEpoch = pops and pops[index] or 0
    return Timers.NodeState(popEpoch, now(), NODE_RESPAWN, Timers.ExpiredWindow())
end

-- The songflower gather cast. This is a SONGFLOWER-ONLY trigger: the old comment
-- here claimed Whipper Root Tubers were gathered through it too, which is false.
-- Tubers are LOOTED (see the loot detector below), so the cast path's tuber
-- branch was dead code that could only ever mis-credit a flower pick — the
-- nearest-node tie-break at a flower always resolves to the flower.
local SONGFLOWER_SPELL = 6478
Timers.SONGFLOWER_SPELL = SONGFLOWER_SPELL

-- Node match radius in NORMALIZED map units (0-1).
--
-- The canonical songflower addon measures plain Euclidean distance on
-- map-PERCENT units (position x 100) and accepts 1.5 map-percent for songflowers
-- and 2.0 for tubers/dragons — 0.015 and 0.02 normalized. Because the units are
-- map percent rather than yards the accepted region is an ELLIPSE, not a circle:
-- Felwood is ~3450 x 2300 yd, so 1.5% is about 52 yd east-west and 35 yd
-- north-south.
--
-- A previous pass widened this to 0.06 citing the OTHER reference's looser
-- "6% of map distance" phrasing. The songflower addon is the canonical authority
-- for Felwood nodes and its value is the tighter 1.5%, i.e. what we had before —
-- so this reverts. 0.06 was 4x looser than canonical and raised the false-pick
-- rate for no gain.
local NODE_MATCH_RADIUS = 0.015
Timers.NODE_MATCH_RADIUS = NODE_MATCH_RADIUS
local NODE_MATCH_RADIUS_BY_KIND = { flower = 0.015, tuber = 0.02, dragon = 0.02 }
Timers.NODE_MATCH_RADIUS_BY_KIND = NODE_MATCH_RADIUS_BY_KIND

local function radiusFor(kind, radius)
    return radius or NODE_MATCH_RADIUS_BY_KIND[kind] or NODE_MATCH_RADIUS
end

-- Match a position against ONE node kind, using that kind's own radius. This is
-- the shape both real detectors need: a songflower aura can only ever be a
-- flower and a tuber loot can only ever be a tuber, so there is no cross-kind
-- tie-break to make. Returns index, distance — or nil when out of range.
function Timers.MatchNodeOfKind(kind, x, y, radius)
    if not x or not y then return nil end
    local idx, dist = Timers.NearestNode(kind, x, y)
    if not idx or dist > radiusFor(kind, radius) then return nil end
    return idx, dist
end

-- Cross-kind match, kept for callers that do not know the kind up front. Each
-- kind is judged against its OWN radius and the nearest in-range candidate wins,
-- so the co-located flower/tuber sites still separate cleanly.
function Timers.MatchNodePick(x, y, radius)
    if not x or not y then return nil end
    local bKind, bIdx, bDist
    for _, kind in ipairs({ "flower", "tuber", "dragon" }) do
        local idx, dist = Timers.MatchNodeOfKind(kind, x, y, radius)
        if idx and (not bDist or dist < bDist) then bKind, bIdx, bDist = kind, idx, dist end
    end
    if not bKind then return nil end
    return bKind, bIdx, bDist
end

-- Are we standing in Felwood? Every node detector is gated on this — including
-- the combat-log one, which fires thousands of times a second in a raid. The
-- answer only changes on a zone transition, so it is CACHED and invalidated by
-- the zone events rather than re-asking the map API per combat-log line.
-- nil = not yet resolved.
Timers._felwoodCache = nil

function Timers.InvalidateFelwoodCache()
    Timers._felwoodCache = nil
end

function Timers.InFelwood()
    local cached = Timers._felwoodCache
    if cached ~= nil then return cached end
    if not (C_Map and C_Map.GetBestMapForUnit) then return false end
    local v = (C_Map.GetBestMapForUnit("player") == Timers.FELWOOD_MAP)
    Timers._felwoodCache = v
    return v
end

-- The player's normalized Felwood position, or nil when not in Felwood / no map
-- API. Another player's coordinates are never readable, so this doubles as the
-- position proxy for a witnessed pick: we only see their aura event at all when
-- they are close enough to share our combat log.
local function playerFelwoodPos()
    if not Timers.InFelwood() then return nil end
    if not (C_Map and C_Map.GetPlayerMapPosition) then return nil end
    local pos = C_Map.GetPlayerMapPosition(Timers.FELWOOD_MAP, "player")
    if not pos then return nil end
    return pos:GetXY()
end
Timers._playerFelwoodPos = playerFelwoodPos

-- Pick detection from a successful player cast in Felwood.
-- UNIT_SPELLCAST_SUCCEEDED(unitTarget, castGUID, spellID) — the spell id was
-- always in the payload and always discarded, so ANY cast near a node (a mount,
-- a heal, a profession cast) started a 25-minute countdown (A5.1). Flower-only:
-- see the SONGFLOWER_SPELL note above.
local function onSpellSucceeded(event, unit, castGUID, spellID)
    if unit ~= "player" then return end
    if spellID ~= SONGFLOWER_SPELL then return end
    local x, y = playerFelwoodPos()
    if not x then return end
    local index = Timers.MatchNodeOfKind("flower", x, y)
    if not index then return end
    Timers.MarkNode("flower", index, now(), "local")
end

----------------------------------------------------------------------
-- Detector — Whipper Root Tuber, from LOOT  (rebuild; the cast path was dead)
--
-- Tubers are not gathered with the songflower cast. They are LOOTED, and the
-- canonical addon detects them by parsing loot CHAT lines, pulling the item link
-- out and matching on item ID — an entirely different mechanism from the
-- songflower aura. Our cast-based tuber branch could only ever fire while
-- standing at a songflower, where the nearest-node tie-break resolves to the
-- flower, so it was unreachable code; and because the reference never puts
-- tubers on the wire on layered realms, `t1`..`t6` never arrive on Whitemane
-- either. Tuber timers were therefore unreachable by BOTH paths. This is the
-- only way one can ever exist here.
--
--   11951 = Whipper Root Tuber
--   11952 = Night Dragon's Breath — same mechanism; we carry no dragon node set
--           yet, so it is recognised and ignored rather than mis-matched onto a
--           tuber node.
--
-- Gates, per the reference: must be in Felwood; both our own and other players'
-- loot lines are parsed (the other-player variant is near-useless in practice
-- because these are pushed rather than looted, but it costs nothing); a 5s
-- throttle per item type; and a node whose timer is younger than the 1500s
-- respawn is not overwritten.
--
-- There are no guild messages, chat notices or alerts for tubers anywhere in the
-- reference — map/minimap markers with countdowns only — so this records
-- silently, exactly like the flower path.
----------------------------------------------------------------------

-- Looted item id -> node kind.
-- ROUND-17 audit fix 8: 11952 (Night Dragon's Breath) was recognised and then
-- deliberately DISCARDED because we had no dragon node set. We have one now
-- (Timers.NODES.dragon), so it records like a tuber — same loot-line trigger,
-- same 1500s respawn, same 2.0 map-percent radius.
local LOOT_ITEM_NODE = {
    [11951] = "tuber",
    [11952] = "dragon",
}
Timers._lootItemNode = LOOT_ITEM_NODE

local LOOT_THROTTLE = 5
Timers.LOOT_THROTTLE = LOOT_THROTTLE
Timers._lastLootAt = {}

-- Pull every itemID out of a loot chat line's item links. One line can carry
-- several links (the "receives loot: [a] [b]" and multiple-item variants), so
-- all are returned, in order. Pure — the self-tests drive it directly.
function Timers.ParseLootItemIDs(msg)
    local out = {}
    if type(msg) ~= "string" then return out end
    for id in msg:gmatch("|Hitem:(%d+)") do
        out[#out + 1] = tonumber(id)
    end
    return out
end

-- CHAT_MSG_LOOT handler. `msg` is the formatted loot line, self or other.
-- Returns true when a node timer was actually started.
function Timers.OnLootMessage(msg, t)
    t = t or now()
    local ids = Timers.ParseLootItemIDs(msg)
    if #ids == 0 then return false end
    local x, y
    local marked = false
    for i = 1, #ids do
        local kind = LOOT_ITEM_NODE[ids[i]]
        if kind and (t - (Timers._lastLootAt[kind] or 0)) >= LOOT_THROTTLE then
            if x == nil then x, y = playerFelwoodPos() end
            if x then
                local index = Timers.MatchNodeOfKind(kind, x, y)
                if index then
                    -- Stamp the throttle on a real node match, so a loot line
                    -- nowhere near a node cannot burn the window.
                    Timers._lastLootAt[kind] = t
                    if Timers.MarkNode(kind, index, t, "local",
                                       { overwriteGuard = NODE_RESPAWN }) then
                        marked = true
                    end
                end
            end
        end
    end
    return marked
end

local function onChatLoot(event, msg)
    ns:SafeCall(Timers.OnLootMessage, msg)
end

----------------------------------------------------------------------
-- Detector — OTHER players' songflower picks  (the group circuit)
--
-- The canonical addon tracks other players' picks ON BY DEFAULT, and this was
-- the largest single coverage gap in Felwood: run the circuit in a group and a
-- reference user finishes with ten node timers while we finished with the one or
-- two we personally picked.
--
-- Mechanism: the trigger is the AURA GAIN itself, read from the COMBAT LOG —
-- SPELL_AURA_APPLIED / SPELL_AURA_REFRESH of Songflower Serenade (15366) with a
-- player-type destination GUID. The reference deliberately does NOT scan anyone's
-- aura bar and does not use the unit-aura events: songflower is frequently not
-- first in the combat log at login, and scanning bars manufactures false timers.
-- It also means the scan is not limited to party/raid units — any nearby player
-- who shares our combat log counts.
--
-- Another player's remaining duration is unreadable, so the duration check that
-- validates our OWN pick is impossible and a presence heuristic substitutes.
-- ALL of these must pass:
--   1. we are in Felwood (1448)
--   2. that player has not already been seen carrying a songflower buff — only
--      the FIRST sighting of a given player may ever create a timer
--   3. that player was seen BEFORE the buff event (an unseen player is assumed
--      to be logging in with a buff they already had)
--   4. time since last seen <= 600s
--   5. time since last seen >= 1s — in the first second after a player appears
--      the client fires their entire login aura set
--   6. neither they nor we chronoboon-released in the last 1s
--   7. global throttle: at most one witnessed pick recorded every 5s
--   8. a node timer younger than 1440s is not overwritten by someone else's pick
-- plus: discarded when the aura target is hostile and the zone PvP type is
-- contested — which Felwood always is, so in practice: never credit an
-- enemy-faction player.
--
-- Presence is fed from any combat-log event carrying a player GUID, plus target
-- and mouseover. A name's last-seen stamp is only refreshed when the previous
-- sighting was more than 180s ago — without that, someone fighting next to you
-- would have their "time since last seen" reset every tick and would sit
-- permanently inside the eligibility band. Every loading screen wipes all three
-- lists; the seen list is wiped again 5s after a zone change.
----------------------------------------------------------------------

local SONGFLOWER_AURA = 15366
Timers.SONGFLOWER_AURA = SONGFLOWER_AURA

-- Songflower Serenade runs 3600s (NWB_BEHAVIOR_SPEC §2). A remaining duration at
-- or above this threshold means the buff landed within the last second — the
-- signature of a pick we just made, as opposed to one we were already carrying.
local SONGFLOWER_DURATION   = 3600
local SONGFLOWER_FRESH_MIN  = 3599
Timers.SONGFLOWER_DURATION  = SONGFLOWER_DURATION
Timers.SONGFLOWER_FRESH_MIN = SONGFLOWER_FRESH_MIN

-- Localized buff name, resolved once at load and used as the secondary match.
-- nil on a client/VM without GetSpellInfo — the spell-id match still works.
Timers._songflowerAuraName = (GetSpellInfo and GetSpellInfo(SONGFLOWER_AURA)) or nil

-- Remaining seconds on OUR songflower buff, or nil when we do not have it (or
-- the aura API is unavailable, as in a bare VM). Scans by spell id, then by
-- localized name, because GetBuffDataByIndex fills spellId on modern clients but
-- the name is the only field guaranteed across the versions we target.
function Timers.OwnSongflowerRemaining(nowTime)
    if not (C_UnitAuras and C_UnitAuras.GetBuffDataByIndex) then return nil end
    local t = nowTime or ((GetTime and GetTime()) or 0)
    local wantName = Timers._songflowerAuraName
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if not aura then break end
        -- Field casing varies by client build, so read BOTH — tracker.lua does
        -- the same and is the surface proven in-game.
        local id = aura.spellId or aura.spellID
        local hit = (id == SONGFLOWER_AURA)
                 or (wantName and aura.name and aura.name == wantName)
        if hit then
            local exp = tonumber(aura.expirationTime) or 0
            -- expirationTime 0 = no duration (should not happen for songflower);
            -- treat as unknown rather than inventing a fresh pick.
            if exp <= 0 then return nil end
            return exp - t
        end
    end
    return nil
end

-- The chronoboon RELEASE cast. A release re-applies a stored songflower, which
-- looks identical to a fresh pick in the combat log; both parties are suppressed
-- for a second around one.
local CHRONOBOON_RELEASE_SPELL = 349863
Timers.CHRONOBOON_RELEASE_SPELL = CHRONOBOON_RELEASE_SPELL

local FLOWER_SEEN_MAX         = 600    -- gate 4
local FLOWER_SEEN_MIN         = 1      -- gate 5
local FLOWER_PICK_THROTTLE    = 5      -- gate 7
local FLOWER_OTHER_OVERWRITE  = 1440   -- gate 8
local FLOWER_PRESENCE_REFRESH = 180    -- last-seen refresh floor
local FLOWER_UNBOON_WINDOW    = 1      -- gate 6
Timers.FLOWER_SEEN_MAX        = FLOWER_SEEN_MAX
Timers.FLOWER_SEEN_MIN        = FLOWER_SEEN_MIN
Timers.FLOWER_PICK_THROTTLE   = FLOWER_PICK_THROTTLE
Timers.FLOWER_OTHER_OVERWRITE = FLOWER_OTHER_OVERWRITE

Timers._felwoodSeen      = {}   -- name -> last-seen epoch
Timers._felwoodHadFlower = {}   -- name -> true once seen carrying the buff
Timers._felwoodUnboon    = {}   -- name -> chronoboon-release epoch
Timers._lastFlowerPickAt = 0

-- `seenOnly` wipes just the last-seen table (the 5s-after-zone-change sweep);
-- otherwise all three lists go (the loading-screen wipe).
function Timers.ResetFelwoodPresence(seenOnly)
    Timers._felwoodSeen = {}
    if seenOnly then return end
    Timers._felwoodHadFlower = {}
    Timers._felwoodUnboon = {}
end

local function isPlayerGUID(guid)
    return type(guid) == "string" and guid:sub(1, 7) == "Player-"
end
Timers._isPlayerGUID = isPlayerGUID

-- Single-bit flag test without the `bit` library, which is absent under a bare
-- Lua 5.1 VM and optional in-game. Valid only for single-bit masks, which is all
-- we use. 0x40 is the combat log's HOSTILE reaction bit.
local COMBATLOG_REACTION_HOSTILE = 0x40
local function hasFlag(flags, mask)
    flags = tonumber(flags)
    if not flags or flags <= 0 or not mask or mask <= 0 then return false end
    return math.floor(flags / mask) % 2 == 1
end
Timers._hasFlag = hasFlag

local function playerNameOf()
    return (UnitName and UnitName("player")) or ""
end

-- Record a sighting. The stamp is only refreshed when the previous sighting was
-- more than FLOWER_PRESENCE_REFRESH ago (see the block comment). Returns true
-- when the stamp actually moved.
function Timers.NoteFelwoodPresence(name, t)
    if type(name) ~= "string" or name == "" then return false end
    t = t or now()
    local prev = Timers._felwoodSeen[name]
    if prev and (t - prev) <= FLOWER_PRESENCE_REFRESH then return false end
    Timers._felwoodSeen[name] = t
    return true
end

-- Apply the eight-gate heuristic to one witnessed songflower aura gain.
-- opts: { at, hostile, x, y, seenAt }. `seenAt` lets the caller pass the
-- last-seen stamp it read BEFORE this event refreshed presence.
-- Returns applied:boolean, reason:string.
function Timers.OnOtherSongflower(name, opts)
    opts = opts or {}
    local t = opts.at or now()
    if type(name) ~= "string" or name == "" then return false, "no name" end
    if name == playerNameOf() then return false, "own pick" end
    -- Hostile target in a contested zone. Felwood is always contested, so this
    -- reduces to: never credit an enemy-faction player.
    if opts.hostile then return false, "hostile target" end
    if (t - (Timers._lastFlowerPickAt or 0)) < FLOWER_PICK_THROTTLE then
        return false, "throttled"
    end
    if Timers._felwoodHadFlower[name] then return false, "already seen with the buff" end

    local seen = opts.seenAt or Timers._felwoodSeen[name]
    -- Flag them as a songflower carrier regardless of whether THIS event counts:
    -- only the first sighting of a player with the buff may ever create a timer,
    -- so a rejected first sighting still burns their one chance (that is the
    -- point — the rejection means we cannot trust their buff's provenance).
    Timers._felwoodHadFlower[name] = true

    if not seen then return false, "not seen before the buff" end
    local since = t - seen
    if since < FLOWER_SEEN_MIN then return false, "seen <1s ago (login aura burst)" end
    if since > FLOWER_SEEN_MAX then return false, "seen >600s ago" end

    local me = playerNameOf()
    if (t - (Timers._felwoodUnboon[me] or 0)) < FLOWER_UNBOON_WINDOW
       or (t - (Timers._felwoodUnboon[name] or 0)) < FLOWER_UNBOON_WINDOW then
        return false, "chronoboon release"
    end

    local x, y = opts.x, opts.y
    if not x then x, y = playerFelwoodPos() end
    if not x then return false, "no position" end
    local index = Timers.MatchNodeOfKind("flower", x, y)
    if not index then return false, "no node in range" end

    Timers._lastFlowerPickAt = t
    local ok = Timers.MarkNode("flower", index, t, "local",
                               { overwriteGuard = FLOWER_OTHER_OVERWRITE })
    return ok, ok and "recorded" or "existing node timer too fresh to overwrite"
end

-- The Felwood engine's single combat-log entry point: presence tracking,
-- chronoboon-release notes, and the songflower witness trigger. Takes the raw
-- CLEU fields so the self-tests drive exactly the code the game drives.
function Timers.FelwoodCombatLog(subevent, sourceGUID, sourceName,
                                 destGUID, destName, destFlags, spellID, t)
    if not Timers.InFelwood() then return false end
    t = t or now()

    -- Snapshot the destination's last-seen stamp BEFORE presence noting: gate 3
    -- asks whether they were seen before the buff EVENT, and this same event
    -- would otherwise refresh their stamp to `t` and fail gate 5 by itself.
    local destSeenAt = (type(destName) == "string") and Timers._felwoodSeen[destName] or nil

    -- Presence: any combat-log event with a player-type source or destination.
    if isPlayerGUID(sourceGUID) then Timers.NoteFelwoodPresence(sourceName, t) end
    if isPlayerGUID(destGUID)   then Timers.NoteFelwoodPresence(destName, t) end

    if subevent == "SPELL_CAST_SUCCESS" and spellID == CHRONOBOON_RELEASE_SPELL
       and isPlayerGUID(sourceGUID) and type(sourceName) == "string" then
        Timers._felwoodUnboon[sourceName] = t
        return false
    end

    if subevent ~= "SPELL_AURA_APPLIED" and subevent ~= "SPELL_AURA_REFRESH" then
        return false
    end
    if spellID ~= SONGFLOWER_AURA then return false end
    if not isPlayerGUID(destGUID) then return false end

    -- ROUND-17 audit fix 5 — OWN-PICK AURA FALLBACK.
    --
    -- OnOtherSongflower rejects our own name outright ("own pick"), on the
    -- assumption that our own picks are already caught by the 6478 cast event.
    -- When that event does not fire — a cast eaten by a loading screen, a
    -- lost UNIT_SPELLCAST_SUCCEEDED, a pick completed as the zone changes — we
    -- recorded NOTHING for a flower we personally picked and stood on.
    --
    -- The aura itself is the insurance. Unlike another player's buff, our own
    -- remaining duration IS readable, and that is what makes this safe: a
    -- songflower lasts 3600s, so a reading of >= 3599s means the buff landed
    -- within the last second, i.e. we just picked it. Anything less is a buff we
    -- were already carrying (a login aura burst, a chronoboon restore, a refresh
    -- from someone else's flower) and is ignored. No overwrite guard: this is a
    -- first-hand, position-validated observation and it should win outright,
    -- exactly like the cast path it backstops.
    if destName == playerNameOf() then
        local rem = Timers.OwnSongflowerRemaining()
        if rem and rem >= SONGFLOWER_FRESH_MIN then
            if (t - (Timers._felwoodUnboon[destName] or 0)) < FLOWER_UNBOON_WINDOW then
                return false
            end
            local x, y = playerFelwoodPos()
            if not x then return false end
            local index = Timers.MatchNodeOfKind("flower", x, y)
            if not index then return false end
            return (Timers.MarkNode("flower", index, t, "local"))
        end
        return false
    end

    return (Timers.OnOtherSongflower(destName, {
        at      = t,
        hostile = hasFlag(destFlags, COMBATLOG_REACTION_HOSTILE),
        seenAt  = destSeenAt,
    }))
end

-- Target / mouseover presence. The reference establishes presence from these
-- two in addition to the combat log.
local function onFelwoodUnitSighting(event, unit)
    if not Timers.InFelwood() then return end
    local u = (event == "UPDATE_MOUSEOVER_UNIT") and "mouseover" or "target"
    if not (UnitIsPlayer and UnitName and UnitIsPlayer(u)) then return end
    local nm = UnitName(u)
    if nm then Timers.NoteFelwoodPresence(nm) end
end

-- Loading screen: wipe all three lists. Zone change: wipe the seen list 5s
-- later (people around you resolve over the first few seconds after a zone in).
local function onFelwoodLoadingScreen()
    Timers.InvalidateFelwoodCache()
    Timers.ResetFelwoodPresence(false)
end

local function onFelwoodZoneChanged()
    Timers.InvalidateFelwoodCache()
    if C_Timer and C_Timer.After then
        C_Timer.After(5, function() Timers.ResetFelwoodPresence(true) end)
    else
        Timers.ResetFelwoodPresence(true)
    end
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
    local t = now()
    -- A3.3 + F3: while the newest event is a KILL the buff is respawning, not on
    -- cooldown, so scheduled CD warnings are suppressed — Kill/respawn timing
    -- carries ~2 minutes of server jitter and warning off a kill-derived clock is
    -- worse than saying nothing.
    --
    -- But that suppression used to be permanent for as long as killedAt >= the
    -- pop anchor, which is the whole rest of the cooldown: pop Onyxia, kill
    -- Runthak a minute later, and every 5-min / 1-min / off-cooldown warning for
    -- the next six hours was cancelled, silently, forever. A kill says nothing
    -- about a cooldown that is still running. So suppression now needs BOTH: the
    -- kill is newer than the pop AND no live cooldown remains to warn about.
    local liveCD = (anchor > 0) and (t < anchor + CD[buffKey])
    if (s.killedAt or 0) >= math.max(anchor, 1) and not liveCD then
        Timers._warnGen[buffKey] = (Timers._warnGen[buffKey] or 0) + 1
        return
    end
    if anchor <= 0 then return end
    if not (C_Timer and C_Timer.After) then return end
    local nextAt = anchor + CD[buffKey]

    local gen = (Timers._warnGen[buffKey] or 0) + 1
    Timers._warnGen[buffKey] = gen

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
            local cd = CD[buffKey]
            -- WALK THE WHOLE LOG FOR THE NEWEST POP AND THE NEWEST KILL,
            -- INDEPENDENTLY. Reading only `list[1]` meant whichever KIND happened
            -- to be newest silently erased the other, and the two are separate
            -- anchors that both persist (A3.1).
            --
            -- This is not theoretical. On 2026-08-03 the owner's raid killed
            -- Overlord Runthak, which pushed a `killed` entry to the head of the
            -- onyH log with the live six-hour Onyxia pop sitting right behind it
            -- at [2]. On the next login this loop would have seeded `killedAt`,
            -- never looked at [2], and the real cooldown — with hours left to run
            -- — would have vanished into "Open".
            local newestPop, newestKill
            for i = 1, #list do
                local e = list[i]
                local epoch = e and e.epoch or 0
                if epoch > 0 then
                    if e.killed then
                        if not newestKill or epoch > (newestKill.epoch or 0) then newestKill = e end
                    elseif not newestPop or epoch > (newestPop.epoch or 0) then
                        newestPop = e
                    end
                end
            end

            local s = stateOf(buffKey)
            -- Entries older than a full CD are ignored (the buff is long
            -- available = no meaningful countdown).
            local function fresh(e) return e and cd and (t - e.epoch) < cd end

            if fresh(newestPop) then
                s.lastPop = math.max(s.lastPop or 0, newestPop.epoch)
                s.trust = s.trust or newestPop.trust or "local"
                seeded = seeded + 1
                ns:Fire("TIMER_UPDATED", buffKey)
            end
            -- F2 backstop on PERSISTED data: only an announcer buff may carry a
            -- kill. A `killed` entry on Rend is legacy debris from the old DBM
            -- boss-kill mapping (a boss kill written as an announcer death) and is
            -- skipped entirely rather than rehydrated — it is neither a respawn
            -- nor a pop.
            if fresh(newestKill) and ANNOUNCER_BUFFS[buffKey] then
                -- ...and a kill the newest pop already superseded stays dead, the
                -- same rule Record applies on the live path (NWB §3.3).
                if not (newestPop and newestPop.epoch >= newestKill.epoch) then
                    s.killedAt = math.max(s.killedAt or 0, newestKill.epoch)
                    s.trust = s.trust or newestKill.trust or "local"
                    seeded = seeded + 1
                    ns:Fire("TIMER_UPDATED", buffKey)
                end
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
-- Engine state reset (F13)
--
-- PUBLIC SURFACE — this is what an options "Reset timer state" control calls.
-- It is deliberately owned here rather than open-coded by the UI, because the
-- engine's runtime state is spread across four places and a partial wipe leaves
-- the model inconsistent in ways that are very hard to see:
--
--   Timers.state          per-buff pop/kill anchors, trust and confirmation
--   Timers._warnGen       CD-warning generation tokens — bumping these is what
--                         CANCELS warnings already armed with C_Timer.After;
--                         clearing the anchors without bumping them leaves live
--                         arms that fire against state that no longer exists
--   Timers._respawnGen    same idea for the armed npcRespawned alert (F6)
--   nodeTrust             which source owns each Felwood node's timer; stale
--                         trust would let a weak source be refused against an
--                         owner that is gone
--   pullObservations      the drift-calibration samples (store-backed)
--
-- Node POP EPOCHS are deliberately NOT wiped: they are Felwood observations,
-- not world-buff state, and they expire on their own 25-minute clock.
--
-- Fires TIMER_UPDATED for every buff key so every readout repaints immediately.
-- Returns true.
----------------------------------------------------------------------
function Timers.ResetState()
    Timers.state       = {}
    Timers._warnGen    = {}
    Timers._respawnGen = {}
    Timers._pendingPull = {}
    Timers._handinStash = {}
    Timers._dbmHint    = {}

    -- Node trust: clear the store-backed table through the same accessor the
    -- proxy uses (and the bare-VM fallback), so no stale owner survives.
    Timers._nodeTrustFallback = {}
    if ns.Store and ns.Store.GetTimers then
        local t = ns.Store.GetTimers()
        if t then t.nodeTrust = {} end
    end

    -- Drift-calibration samples.
    if ns.Store and ns.Store.GetTimers then
        local t = ns.Store.GetTimers()
        if t then t.pullObservations = nil end
    end

    for i = 1, #Timers.BUFF_KEYS do
        ns:Fire("TIMER_UPDATED", Timers.BUFF_KEYS[i])
    end
    return true
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
        Timers._respawnGen = {}   -- cancel any armed npcRespawned alert (F6)
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
    local snap = { buffs = {}, flower = {}, tuber = {}, dragon = {}, at = now() }
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
    local dragon = nodePopTable("dragon")
    if flower then for i = 1, 10 do snap.flower[i] = flower[i] end end
    if tuber  then for i = 1, 6  do snap.tuber[i]  = tuber[i]  end end
    -- ROUND-17 audit fix 8: dragons ride the mesh snapshot. This is safely
    -- ADDITIVE — an older peer receiving `snap.dragon` simply has no branch that
    -- reads it and ignores the field. The timer HASH is a different matter and
    -- is deliberately NOT extended; see the note on Mesh.HashTimers below.
    if dragon then for i = 1, 4  do snap.dragon[i] = dragon[i] end end
    return snap
end

-- NOTE (ROUND-17 audit fix 8, HashTimers verdict) — mesh.lua's Mesh.HashTimers
-- hashes f1..f10, t1..t6 and timers.timerVersion, and the heartbeat compares
-- that hash against peers to decide whether to run a timer sync. It carries NO
-- version/capability guard of its own: `timerVersion` is a LOCAL edit counter,
-- not a schema version, so it does not separate old code from new.
--
-- Appending d1..d4 would therefore change the hash of every new client even when
-- all four dragon epochs are 0, and an old peer — running old code that hashes
-- 16 fields, not 20 — would compute a different value for identical data. The
-- two would mismatch on every heartbeat and sync forever without converging.
-- So dragons stay OUT of the hash this release. The cost is only that a
-- dragon-only divergence does not by itself trigger a sync; dragon epochs still
-- travel in the snapshot whenever any sync runs for any other reason.
-- Follow-up for the mesh owner (mesh.lua is not this branch's file): gate the
-- extended hash behind a peer-capability flag, then add d1..d4.

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
    -- ROUND-17 audit fix 2: a peer snapshot is second-hand for nodes exactly as
    -- NWB data is, so it carries the same guards — our own pick is not stomped
    -- by a relay of it, and a re-report inside 10s is a duplicate.
    if snap.flower then for i, e in pairs(snap.flower) do Timers.MarkNode("flower", i, e, trust, netNodeOpts()) end end
    if snap.tuber  then for i, e in pairs(snap.tuber)  do Timers.MarkNode("tuber",  i, e, trust, netNodeOpts()) end end
    if snap.dragon then for i, e in pairs(snap.dragon) do Timers.MarkNode("dragon", i, e, trust, netNodeOpts()) end end
end

-- Inbound single-timer event from the mesh (peer relay). trust "mesh".
-- A relayed HAND-IN takes the unified hand-in path (F7): +15s assumed-drop lead,
-- and refused while one of our own hand-ins is still waiting for its yell.
function Timers.OnMeshTimer(buffKey, epoch, kind, meta)
    noteFreshness("nexus")
    if kind == "quest" then
        return Timers.RecordHandinReport(buffKey, epoch or now(), "mesh",
                                         (meta and meta.who) or "mesh", meta and meta.zone)
    end
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
    -- F7: an SN quest entry is a HAND-IN, and until now it anchored at the raw
    -- hand-in second while the same event from NWB's log anchored 15s later. One
    -- path now, one lead, one stash rule.
    if kind == "quest" then
        return Timers.RecordHandinReport(buffKey, epoch or now(), "sn",
                                         (meta and meta.who) or "SN", meta and meta.zone)
    end
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
-- Base-36 (lowercase, as NWB emits) encode of a non-negative integer.
function Timers.ToBase36(n)
    n = math.floor(tonumber(n) or 0)
    if n <= 0 then return "0" end
    local digits = "0123456789abcdefghijklmnopqrstuvwxyz"
    local out = ""
    while n > 0 do
        local r = n % 36
        out = digits:sub(r + 1, r + 1) .. out
        n = math.floor(n / 36)
    end
    return out
end

function Timers.BuildNWBText(innerData)
    local level = (UnitLevel and UnitLevel("player")) or 60
    local st = (GetServerTime and GetServerTime()) or 0
    -- Field 4 is NWB's coarse ~16.7-minute epoch bucket, and the receiver
    -- RECOMPUTES it from its own clock and requires EQUALITY before merging any
    -- bulk timer data (NWB_BEHAVIOR_SPEC §5.3: "a base-36 encoding of
    -- floor((serverTime + 1998) / 1000)").
    --
    -- ROUND-17 audit fix 4: we were sending a DECIMAL string built by chopping
    -- the last three characters off tostring(serverTime + 1998). That is a
    -- different function of the clock and a different alphabet, so it could
    -- never equal what a real NWB client computes — every requestData we sent
    -- was silently discarded on arrival, which is why the pull "did nothing".
    local ktoken = Timers.ToBase36(math.floor((st + 1998) / 1000))
    return "requestData " .. NWB_REQ_VERSION .. " " .. tostring(level)
           .. " " .. ktoken .. " " .. (innerData or "")
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
            -- ROUND-17 audit fix 4: the re-watch existed to recover when no NWB
            -- traffic had been heard, but it only re-asked the MESH. The one
            -- thing it never did was ask NWB — so a guild whose only timer
            -- source is NWB sat silent forever. Both are asked now; each has its
            -- own cooldown, so the pair cannot amplify.
            ns:SafeCall(Timers.RequestNWBData)
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
            -- Two-phase respawn (F12): after the certain-dead 360s the announcer
            -- is still inside its 120s random window, and saying so is the
            -- difference between "go now" and "go in a minute".
            if st.phase == "window" then
                status = status .. " (announcer due back within "
                                .. fmtRemaining(st.windowRemaining or 0) .. ")"
            end
            local hint = Timers._dbmHint[k]
            ns:Print(string.format("  %-5s %s  trust=%s conf=%s%s",
                k, status, tostring(s.trust), tostring(s.confirmed),
                hint and ("  dbm-hint=" .. hint.what .. "@" .. hint.at) or ""))
        else
            ns:Print(string.format("  %-5s (no data)", k))
        end
    end
    ns:Print("felwood nodes:")
    for _, kind in ipairs({ "flower", "tuber", "dragon" }) do
        local pops = nodePopTable(kind)
        local count = Timers.NODE_COUNTS[kind] or 0
        for i = 1, count do
            local st = Timers.NodeState(pops and pops[i] or 0, t, NODE_RESPAWN,
                                        Timers.ExpiredWindow())
            if st.state ~= "unknown" then
                local detail = ""
                if st.state == "down" then
                    detail = fmtRemaining(st.remaining)
                elseif st.state == "expired" then
                    detail = "-" .. fmtRemaining(-st.remaining)
                end
                ns:Print(string.format("  %s%d %s %s  trust=%s", kind, i, st.state, detail,
                    tostring(Timers._nodeTrust[kind .. i])))
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
    -- Songflower ingest, CUMULATIVE since login. `lastApplied` above is the last
    -- payload only and is routinely empty, so these are the numbers to read when
    -- asking "is the wire giving me flowers at all?".
    local ft, fl = s.flowerTotals or {}, {}
    for i = 1, #FLOWER_COUNTERS do
        local k = FLOWER_COUNTERS[i]
        fl[#fl + 1] = k .. "=" .. tostring(ft[k] or 0)
    end
    ns:Print("  flowers (session totals): " .. table.concat(fl, " "))
    ns:Print("  NOTE: NWB never transmits ZG/Zandalar. On a LAYERED realm the"
        .. " songflower epochs arrive only inside the per-layer map, so we read"
        .. " them: an EMPTY node is filled (trust nwbLayer), a node holding our"
        .. " own pick is never overwritten for the full respawn, and a filled"
        .. " node follows newest-wins + the 10s duplicate guard. We do not track"
        .. " which layer WE are on, so a filled cell may reflect another layer's"
        .. " pick — some data beats none, and a local pick always wins."
        .. " Reassembly is AceComm's, shared-instance.")
    ns:Print("  lastApplied keys: rend/ony/flower/tuber/log = merged;"
        .. " rejectedPayload = drop with no stage-1 yell (whole payload dropped);"
        .. " rejectedYell = stage-1 yell >" .. YELL_DROP_TOLERANCE .. "s from the drop;"
        .. " nefRejected = Nefarian timer discarded (disabled on Era).")
    ns:Print("  flower counters: flowerHeard = fields seen (top-level + every layer);"
        .. " flowerApplied = writes that landed; flowerFilled = of those, ones that"
        .. " filled a node with NO data; layersScanned = per-layer sub-tables read;"
        .. " rejGuard = blocked by the local-pick hold; rejMinNewer = inside the 10s"
        .. " duplicate window; rejOlder = older than what we hold;"
        .. " rejLayerSkip = a layer's value dropped for a newer one on another layer.")
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
Timers._onChatLoot       = onChatLoot
Timers._onFelwoodUnitSighting = onFelwoodUnitSighting

----------------------------------------------------------------------
-- Self-tests (pure Lua; run via /dsn debug selftest)
----------------------------------------------------------------------

local function tcheck(cond, msg, fails)
    if not cond then fails[#fails + 1] = msg end
    return cond
end

----------------------------------------------------------------------
-- NX-13 (CLASS 8): the announcer fallback resolves by longest match, not by
-- iteration order.
--
-- The audit filed this LATENT, "needs an overlapping-substring NPC pair". The
-- shipping table HAS one: "thrall" is a substring of "herald of thrall". Any
-- rendering of the Herald that misses the exact-match branch matches both keys,
-- and REND_NPC_VARIANT reads the resolved key to choose which Barrens bar to
-- raise — so the coin flip does not merely pick a name, it picks a timer that
-- goes out to the whole mesh.
----------------------------------------------------------------------
local function testNpcKeyOrder(fails)
    local OF = ns.OrderFixture

    -- The shipping table's own overlapping pair, through the SHIPPING resolver.
    tcheck(Timers._npcKeyOf("Herald of Thrall") == "herald of thrall",
        "NX-13: the exact name still resolves exactly", fails)
    tcheck(Timers._npcKeyOf("Thrall") == "thrall",
        "NX-13: the shorter announcer still resolves to itself", fails)
    tcheck(Timers._npcKeyOf("Herald of Thrall <Warchief's Envoy>") == "herald of thrall",
        "NX-13: a DECORATED Herald resolves to the Herald, not to Thrall — the "
        .. "longer, more specific key wins the loose match", fails)
    tcheck(Timers._npcKeyOf("Overlord Runthak the Elder") == "overlord runthak",
        "NX-13: an undecorated loose match is unchanged", fails)
    tcheck(Timers._npcKeyOf("Innkeeper Norman") == nil,
        "NX-13: an unknown announcer still resolves to nothing", fails)
    tcheck(Timers._npcKeyOf("") == nil and Timers._npcKeyOf(nil) == nil,
        "NX-13: an empty or missing name resolves to nothing", fails)

    -- The candidate order itself: longest first, ties by key ascending, and the
    -- SAME order from three insertion histories of the same content. The
    -- shipping table has exactly one lifetime and so can never prove this on its
    -- own — which is why the rule is a pure function taking the table.
    local names = {
        "thrall", "herald of thrall", "overlord runthak", "major mattingly",
        "high overlord saurfang", "field marshal afrasiabi",
        "field marshal stonebridge", "molthor", "zandalarian emissary",
        "fallen hero of the horde", "the herald of thrall himself",
        "lord molthor", "an emissary", "emissary", "hero of the horde",
        "runthak", "saurfang", "mattingly", "afrasiabi", "stonebridge",
        "hero", "herald", "lord", "envoy", "warchief", "the warchief",
        "grand herald", "grand herald of thrall", "elder molthor", "molthor the elder",
    }
    local R1, R2, R3 = OF.Histories(names, function() return { {} } end)
    tcheck(OF.Divergent(R1, R2, R3),
        "NX-13 fixture is not divergent — the three announcer-table insertion "
        .. "histories walked in the same pairs() order, so this row proves nothing",
        fails)

    local o1 = Timers.NpcCandidateOrder(R1)
    local o2 = Timers.NpcCandidateOrder(R2)
    local o3 = Timers.NpcCandidateOrder(R3)
    tcheck(OF.Seq(o1) == OF.Seq(o2) and OF.Seq(o2) == OF.Seq(o3),
        "NX-13: the candidate order differed across insertion histories", fails)
    tcheck(#o1 >= 2 and #o1[1] >= #o1[2],
        "NX-13: the candidate list is longest-first", fails)
    do
        local sortedByLen = true
        for i = 2, #o1 do
            if #o1[i - 1] < #o1[i] then sortedByLen = false end
            if #o1[i - 1] == #o1[i] and o1[i - 1] > o1[i] then sortedByLen = false end
        end
        tcheck(sortedByLen,
            "NX-13: descending length, then key ascending, all the way down", fails)
    end

    -- The resolution itself, from all three histories, on a name that carries
    -- FOUR of these keys at once ("thrall", "herald", "herald of thrall",
    -- "grand herald of thrall").
    local DECORATED = "the grand herald of thrall, envoy"
    local r1 = Timers.ResolveNpcKey(R1, o1, DECORATED)
    local r2 = Timers.ResolveNpcKey(R2, o2, DECORATED)
    local r3 = Timers.ResolveNpcKey(R3, o3, DECORATED)
    tcheck(r1 == r2 and r2 == r3,
        "NX-13: an overlapping name resolved differently across insertion histories", fails)
    tcheck(r1 == "grand herald of thrall",
        "NX-13: the LONGEST matching key wins (got " .. tostring(r1) .. ")", fails)

    -- RED CONTROL: the pre-fix walk, verbatim, on the same three tables. It must
    -- disagree with itself — otherwise this fixture proves nothing about the bug.
    local function preFix(rows, name)
        local key = (name or ""):lower()
        if rows[key] then return key end
        for npc in pairs(rows) do
            if key:find(npc, 1, true) then return npc end
        end
    end
    local p1, p2, p3 = preFix(R1, DECORATED), preFix(R2, DECORATED), preFix(R3, DECORATED)
    tcheck(not (p1 == p2 and p2 == p3),
        "NX-13 RED CONTROL: the pre-fix first-pairs()-match agreed with itself across "
        .. "all three histories — this fixture would not have caught the bug", fails)
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

    -- (d) F3 — the LONGER constraint wins, not the newest event. (c) left a pop
    -- at t with a live six-hour cooldown; killing the announcer two minutes in
    -- must NOT erase it (the old rule read "killed, back in 6 minutes" while the
    -- buff was genuinely ~6 hours away).
    Timers.Record("onyH", t + 120, "local", "Overlord Runthak", "killed")
    local mixed = Timers.BuffStatus("onyH", t + 180)
    tcheck(mixed.state == "cd", "a kill does NOT erase a live cooldown (F3)", fails)
    tcheck(mixed.remaining > CD.onyH - 300,
        "the cooldown remaining is the real one, not the 360s respawn", fails)
    tcheck(Timers.state.onyH.killedAt == t + 120,
        "the kill is still recorded while the cooldown reads through", fails)
    -- ...and when the cooldown has run out, the kill's respawn is what remains.
    Timers.state = {}
    Timers.Record("onyH", t, "local", "yeller", "pop")
    Timers.Record("onyH", t + CD.onyH, "local", "Overlord Runthak", "killed")
    tcheck(Timers.BuffStatus("onyH", t + CD.onyH + 60).state == "killed",
        "past the cooldown, the newer kill owns the readout", fails)

    -- (e) F3 — CD warnings are suppressed by a kill ONLY when there is no live
    -- cooldown left to warn about. The old rule suppressed for as long as
    -- killedAt >= the pop anchor, i.e. permanently: one announcer kill silently
    -- cancelled every warning for the rest of a six-hour cooldown.
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
    tcheck(armed > armedAfterPop,
        "a kill during a LIVE cooldown keeps the warnings armed (F3)", fails)
    -- With no live cooldown, the kill still suppresses: respawn timing carries
    -- ~2 minutes of server jitter and warning off it is worse than silence.
    Timers.state = {}
    armed = 0
    Timers.Record("onyH", now(), "local", "Overlord Runthak", "killed")
    tcheck(armed == 0, "a kill with no live cooldown arms nothing (A3.3)", fails)
    local genBefore = Timers._warnGen.onyH or 0
    Timers.ScheduleWarnings("onyH")
    tcheck((Timers._warnGen.onyH or 0) > genBefore,
        "the suppressed path bumps the generation, cancelling earlier arms", fails)
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
    -- (onyA, not nefH: Nefarian no longer anchors at all on Era.)
    Timers.state = {}; cap.pull = nil; cap.timerUpdated = {}
    local ok = Timers.Record("onyA", t - 3600, "mesh", "peer", "pop")
    tcheck(ok == true, "stale anchor still applied", fails)
    tcheck(cap.timerUpdated["onyA"] == true, "stale anchor fires TIMER_UPDATED", fails)
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

    -- (4) Nefarian, both factions and both Alliance announcers. A Nef drop STILL
    -- ALERTS and still bars — only its cooldown model is gone on Era, so the bar
    -- must survive while the pop anchor must not be set.
    b = yell("NEFARIAN IS SLAIN! The Horde is victorious!", "High Overlord Saurfang")
    tcheck(#b == 1 and math.abs(b[1].dur - 15) <= 1, "Nef-H yell 1 bar is 15s", fails)
    tcheck((Timers.state.nefH == nil) or (Timers.state.nefH.lastPop or 0) == 0,
        "Nef-H yell bars but records NO cooldown anchor (Era)", fails)
    b = yell("People of Stormwind, the Lord of Blackrock is slain!", "Field Marshal Afrasiabi")
    tcheck(#b == 1 and math.abs(b[1].dur - 12) <= 1, "Nef-A yell 1 bar is 12s", fails)
    -- A2.5: Stonebridge was missing entirely, so Alliance lost every Nef drop
    -- he announced. He must still raise the bar.
    b = yell("People of Stormwind, the Lord of Blackrock is slain!", "Field Marshal Stonebridge")
    tcheck(#b == 1 and math.abs(b[1].dur - 12) <= 1, "Stonebridge Nef-A bar is 12s", fails)
    tcheck((Timers.state.nefA == nil) or (Timers.state.nefA.lastPop or 0) == 0,
        "Stonebridge bars Nef-A without a cooldown anchor (Era)", fails)

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
    -- (7491 is the HORDE Onyxia hand-in, matching the Horde faction stubbed above.)
    reset()
    Timers.Record("onyH", now(), "local", "yeller", "pop")
    Timers._lastNotice = nil
    local ok2, why = Timers.OnQuestHandin(7491)
    tcheck(ok2 == false and why == "on cooldown", "on-CD hand-in is ignored", fails)
    tcheck(Timers._lastNotice == nil, "on-CD hand-in emits no alert (A4.2)", fails)
    -- Rend likewise.
    reset()
    Timers.Record("rend", now(), "local", "yeller", "pop")
    tcheck(Timers.OnQuestHandin(4974) == false, "on-CD Rend hand-in ignored", fails)
    tcheck(Timers._handinStash.rend == nil, "on-CD Rend hand-in does not even stash", fails)

    -- (c) Nef and ZG are NEVER cooldown-suppressed. Nef's cooldown is disabled
    -- outright on Era, so the hand-in still ALERTS but anchors nothing.
    reset()
    tcheck(Timers.Record("nefH", now(), "local", "yeller", "pop") == false,
        "a Nef pop is refused outright on Era (no anchor from any source)", fails)
    tcheck(Timers.OnQuestHandin(7784) == true, "Nef hand-in never suppressed", fails)
    tcheck(Timers._lastNotice and Timers._lastNotice.category == "questHandin",
        "the Nef hand-in still alerts", fails)
    tcheck((Timers.state.nefH == nil) or (Timers.state.nefH.lastPop or 0) == 0,
        "the Nef hand-in sets no cooldown anchor", fails)

    -- (d) The ZG hand-in starts the 50s stage-1 pull (A4.3).
    reset()
    tcheck(Timers.OnQuestHandin(8183) == true, "ZG hand-in handled", fails)
    tcheck(#bars == 1 and bars[1].buff == "zg" and math.abs(bars[1].dur - 50.5) <= 1,
        "ZG hand-in starts the 50.5s stage-1 pull (A4.3)", fails)

    -- (e) A non-buff quest is not our business.
    reset()
    local okN = Timers.OnQuestHandin(12345)
    tcheck(okN == false, "an unrelated quest hand-in is ignored", fails)

    -- (f) Hand-in ids map to the right FACTION. Settled from the classic quest
    -- database, not from either reference addon (neither carries the split).
    tcheck(Timers._handinQuest[7491] == "onyH", "7491 'For All To See' -> Ony HORDE", fails)
    tcheck(Timers._handinQuest[7496] == "onyA", "7496 'Celebrating Good Times' -> Ony ALLIANCE", fails)
    tcheck(Timers._handinQuest[7782] == "nefA", "7782 -> Nef ALLIANCE (Stonebridge)", fails)
    tcheck(Timers._handinQuest[7784] == "nefH", "7784 -> Nef HORDE (Saurfang)", fails)
    tcheck(Timers._handinQuest[4974] == "rend" and Timers._handinQuest[8183] == "zg",
        "4974 -> Rend, 8183 -> Zandalar", fails)

    -- ...and the mapping is live end to end: turning in the Horde Onyxia head
    -- anchors onyH, never onyA.
    reset()
    _G.UnitFactionGroup = function() return "Horde" end
    tcheck(Timers.OnQuestHandin(7491) == true, "Ony Horde hand-in handled", fails)
    tcheck((Timers.state.onyH and Timers.state.onyH.lastPop or 0) > 0,
        "7491 anchors onyH", fails)
    tcheck((Timers.state.onyA == nil) or (Timers.state.onyA.lastPop or 0) == 0,
        "7491 does NOT touch onyA", fails)
    reset()
    tcheck(Timers.OnQuestHandin(7496) == true, "Ony Alliance hand-in handled", fails)
    tcheck((Timers.state.onyA and Timers.state.onyA.lastPop or 0) > 0,
        "7496 anchors onyA", fails)
    tcheck((Timers.state.onyH == nil) or (Timers.state.onyH.lastPop or 0) == 0,
        "7496 does NOT touch onyH", fails)

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
    Timers.InvalidateFelwoodCache()
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

    -- (d) Radius is back to the CANONICAL 1.5 map-percent (0.015) for flowers
    -- and 2.0 (0.02) for tubers. The interim 0.06 was 4x looser than canonical.
    tcheck(Timers.NODE_MATCH_RADIUS == 0.015, "songflower match radius is 0.015 normalized", fails)
    tcheck(Timers.NODE_MATCH_RADIUS_BY_KIND.flower == 0.015
       and Timers.NODE_MATCH_RADIUS_BY_KIND.tuber == 0.02,
        "per-kind radii are flower 0.015 / tuber 0.02", fails)

    -- Just inside 0.015 matches...
    timers.flower = {}
    standOn(f4, 0.008, 0.008)   -- ~0.0113 away: inside 0.015
    Timers._onSpellSucceeded("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-4", Timers.SONGFLOWER_SPELL)
    tcheck((timers.flower[4] or 0) > 0, "a pick 0.011 off the node matches", fails)

    -- ...and the old over-wide band (0.036) no longer does.
    timers.flower = {}
    standOn(f4, 0.03, 0.02)   -- ~0.036 away: was inside the interim 0.06
    Timers._onSpellSucceeded("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-4b", Timers.SONGFLOWER_SPELL)
    tcheck((timers.flower[4] or 0) == 0,
        "a pick 0.036 off the node is REJECTED at the canonical radius", fails)

    -- Well outside the radius still matches nothing.
    timers.flower = {}
    standOn(f4, 0.2, 0.2)
    Timers._onSpellSucceeded("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-5", Timers.SONGFLOWER_SPELL)
    tcheck((timers.flower[4] or 0) == 0, "a cast far from every node matches nothing", fails)

    -- (e) Co-located flower/tuber sites resolve by nearest-distance, each judged
    -- against its own radius.
    local f3, t1 = Timers.NODES.flower[3], Timers.NODES.tuber[1]
    local k1 = Timers.MatchNodePick(f3.x, f3.y)
    tcheck(k1 == "flower", "standing on flower 3 resolves to the flower", fails)
    local k2, i2 = Timers.MatchNodePick(t1.x, t1.y)
    tcheck(k2 == "tuber" and i2 == 1, "standing on tuber 1 resolves to the tuber", fails)
    tcheck(Timers.MatchNodePick(0.9, 0.9) == nil, "far-away position matches no node", fails)

    -- (f) The gather cast is SONGFLOWER-ONLY now: standing on a tuber node and
    -- casting 6478 must mark nothing (tubers are looted, not cast).
    timers.flower, timers.tuber = {}, {}
    standOn(t1)
    Timers._onSpellSucceeded("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-6", Timers.SONGFLOWER_SPELL)
    tcheck((timers.tuber[1] or 0) == 0, "the gather cast never marks a tuber (dead path removed)", fails)
    tcheck(Timers.MatchNodeOfKind("flower", t1.x, t1.y) == nil,
        "a tuber-node position matches no flower within 0.015", fails)

    _G.C_Map = savedMap
    Timers.InvalidateFelwoodCache()
    timers.flower, timers.tuber = {}, {}
end

-- Tuber detection via LOOT (item 11951), the rebuilt path. The old cast-based
-- path was unreachable and the wire never carries tubers on a layered realm, so
-- this is the only way a tuber timer can exist on Whitemane.
local function testTuberLoot(fails)
    if not (ns.Store and ns.Store.GetTimers) then
        fails[#fails + 1] = "store absent for tuber loot test"; return
    end
    local timers = ns.Store.GetTimers()
    timers.flower, timers.tuber = {}, {}
    Timers._lastLootAt = {}

    -- Item-link parsing is pure and drives everything else.
    local selfLine  = "You receive loot: |cffffffff|Hitem:11951::::::::60:::::|h[Whipper Root Tuber]|h|r."
    local otherLine = "Someone receives loot: |cffffffff|Hitem:11951::::::::60:::::|h[Whipper Root Tuber]|h|rx2."
    local multiLine = "You receive loot: |Hitem:2589::::::::60:::::|h[Linen Cloth]|h |Hitem:11951::::::::60:::::|h[Whipper Root Tuber]|h."
    local ids = Timers.ParseLootItemIDs(selfLine)
    tcheck(#ids == 1 and ids[1] == 11951, "loot line yields item 11951", fails)
    ids = Timers.ParseLootItemIDs(multiLine)
    tcheck(#ids == 2 and ids[1] == 2589 and ids[2] == 11951,
        "a multi-link loot line yields every item id in order", fails)
    tcheck(#Timers.ParseLootItemIDs("You have looted 3 copper.") == 0,
        "a loot line with no item link yields nothing", fails)
    tcheck(#Timers.ParseLootItemIDs(nil) == 0, "nil loot line is safe", fails)

    local savedMap = _G.C_Map
    local pos = { x = 0, y = 0 }
    local mapID = Timers.FELWOOD_MAP
    _G.C_Map = {
        GetBestMapForUnit = function() return mapID end,
        GetPlayerMapPosition = function()
            return { GetXY = function() return pos.x, pos.y end }
        end,
    }
    Timers.InvalidateFelwoodCache()
    local t1 = Timers.NODES.tuber[1]
    local function standOn(node, dx, dy) pos.x, pos.y = node.x + (dx or 0), node.y + (dy or 0) end

    -- (a) THE fix: looting a tuber ON a tuber node starts that node's timer.
    standOn(t1)
    local t = now()
    tcheck(Timers.OnLootMessage(selfLine, t) == true, "looting 11951 on tuber 1 marks it", fails)
    tcheck((timers.tuber[1] or 0) == t, "tuber 1 timer set to the loot epoch", fails)

    -- (b) 5s per-type throttle: an immediate second loot line is swallowed.
    timers.tuber = {}
    tcheck(Timers.OnLootMessage(selfLine, t + 1) == false, "second loot within 5s is throttled", fails)
    tcheck((timers.tuber[1] or 0) == 0, "throttled loot marks nothing", fails)

    -- (c) past the throttle, another player's loot line counts too.
    timers.tuber = {}
    tcheck(Timers.OnLootMessage(otherLine, t + 6) == true,
        "another player's loot line records past the throttle", fails)

    -- (d) an existing timer younger than the 1500s respawn is not overwritten.
    Timers._lastLootAt = {}
    timers.tuber = { [1] = t + 6 }
    tcheck(Timers.OnLootMessage(selfLine, t + 100) == false,
        "a node timer younger than 1500s is not overwritten", fails)
    tcheck(timers.tuber[1] == t + 6, "the younger timer survives", fails)
    -- ...but past the respawn it is.
    Timers._lastLootAt = {}
    tcheck(Timers.OnLootMessage(selfLine, t + 6 + NODE_RESPAWN + 1) == true,
        "past the 1500s respawn the node re-marks", fails)

    -- (e) not in Felwood -> nothing at all.
    Timers._lastLootAt = {}; timers.tuber = {}
    mapID = 1454   -- Orgrimmar
    Timers.InvalidateFelwoodCache()
    tcheck(Timers.OnLootMessage(selfLine, t + 2000) == false, "loot outside Felwood is ignored", fails)
    mapID = Timers.FELWOOD_MAP
    Timers.InvalidateFelwoodCache()

    -- (f) away from every tuber node -> nothing.
    Timers._lastLootAt = {}; timers.tuber = {}
    standOn(t1, 0.2, 0.2)
    tcheck(Timers.OnLootMessage(selfLine, t + 3000) == false,
        "looting a tuber away from any node marks nothing", fails)

    -- (g) Night Dragon's Breath (11952) is recognised but has no node set, so it
    -- must never be mis-credited onto a tuber node.
    Timers._lastLootAt = {}; timers.tuber = {}
    standOn(t1)
    local dragonLine = "You receive loot: |Hitem:11952::::::::60:::::|h[Night Dragon's Breath]|h."
    tcheck(Timers.OnLootMessage(dragonLine, t + 4000) == false,
        "item 11952 is recognised and ignored, never mapped onto a tuber", fails)
    tcheck((timers.tuber[1] or 0) == 0, "11952 leaves the tuber nodes untouched", fails)

    _G.C_Map = savedMap
    Timers.InvalidateFelwoodCache()
    timers.flower, timers.tuber = {}, {}
    Timers._lastLootAt = {}
end

-- Other players' songflower picks: the eight-gate witness heuristic that turns
-- one personally-picked timer into a whole group circuit.
local function testOtherSongflower(fails)
    if not (ns.Store and ns.Store.GetTimers) then
        fails[#fails + 1] = "store absent for witness test"; return
    end
    local timers = ns.Store.GetTimers()
    timers.flower, timers.tuber = {}, {}

    local savedMap = _G.C_Map
    local pos = { x = 0, y = 0 }
    local mapID = Timers.FELWOOD_MAP
    _G.C_Map = {
        GetBestMapForUnit = function() return mapID end,
        GetPlayerMapPosition = function()
            return { GetXY = function() return pos.x, pos.y end }
        end,
    }
    Timers.InvalidateFelwoodCache()
    local f5 = Timers.NODES.flower[5]
    pos.x, pos.y = f5.x, f5.y

    local t = now()
    local function reset()
        Timers.ResetFelwoodPresence(false)
        Timers._lastFlowerPickAt = 0
        timers.flower = {}
    end
    local PGUID, NGUID = "Player-4395-00ABCDEF", "Creature-0-1-2-3-14392-000012AB"

    -- Bit test (no `bit` library under a bare VM).
    tcheck(Timers._hasFlag(0x40, 0x40) == true, "hostile flag detected", fails)
    tcheck(Timers._hasFlag(0x10, 0x40) == false, "friendly flag is not hostile", fails)
    tcheck(Timers._isPlayerGUID(PGUID) == true, "player GUID recognised", fails)
    tcheck(Timers._isPlayerGUID(NGUID) == false, "creature GUID is not a player", fails)

    -- (a) THE feature: a player seen 30s ago gains Songflower Serenade next to
    -- us -> that node's timer starts.
    reset()
    Timers.NoteFelwoodPresence("Friendo", t - 30)
    local ok = Timers.FelwoodCombatLog("SPELL_AURA_APPLIED", PGUID, "Friendo",
                                       PGUID, "Friendo", 0x10, Timers.SONGFLOWER_AURA, t)
    tcheck(ok == true, "a witnessed songflower gain records a pick", fails)
    tcheck((timers.flower[5] or 0) == t, "the matched node timer is set", fails)

    -- (b) gate 2: only the FIRST sighting of a player with the buff can count.
    Timers._lastFlowerPickAt = 0
    timers.flower = {}
    Timers.NoteFelwoodPresence("Friendo", t - 30)
    local ok2 = Timers.FelwoodCombatLog("SPELL_AURA_REFRESH", PGUID, "Friendo",
                                        PGUID, "Friendo", 0x10, Timers.SONGFLOWER_AURA, t + 10)
    tcheck(ok2 == false, "a second gain from the same player is refused", fails)

    -- (c) gate 3: a player never seen before the buff is a logging-in carrier.
    reset()
    tcheck(Timers.OnOtherSongflower("Stranger", { at = t }) == false,
        "an unseen player's buff is not a pick", fails)

    -- (d) gate 5: seen less than 1s ago is the login aura burst.
    reset()
    Timers.NoteFelwoodPresence("Blinkin", t)
    tcheck(Timers.OnOtherSongflower("Blinkin", { at = t }) == false,
        "seen <1s ago is rejected (login aura burst)", fails)

    -- (e) gate 4: seen more than 600s ago is too stale to attribute.
    reset()
    Timers.NoteFelwoodPresence("Ghost", t - 700)
    tcheck(Timers.OnOtherSongflower("Ghost", { at = t }) == false,
        "seen >600s ago is rejected", fails)

    -- (f) hostile target in a contested zone is never credited.
    reset()
    Timers.NoteFelwoodPresence("Enemy", t - 30)
    tcheck(Timers.FelwoodCombatLog("SPELL_AURA_APPLIED", PGUID, "Enemy",
                                   PGUID, "Enemy", 0x40, Timers.SONGFLOWER_AURA, t) == false,
        "a hostile aura target is discarded", fails)

    -- (g) gate 6: a chronoboon release inside 1s suppresses both sides.
    reset()
    Timers.NoteFelwoodPresence("Booner", t - 30)
    Timers.FelwoodCombatLog("SPELL_CAST_SUCCESS", PGUID, "Booner", PGUID, "Booner",
                            0x10, Timers.CHRONOBOON_RELEASE_SPELL, t)
    tcheck(Timers._felwoodUnboon["Booner"] == t, "a chronoboon release is noted", fails)
    tcheck(Timers.OnOtherSongflower("Booner", { at = t }) == false,
        "a pick within 1s of a chronoboon release is rejected", fails)

    -- (h) gate 7: the 5s global throttle.
    reset()
    Timers.NoteFelwoodPresence("A", t - 30)
    Timers.NoteFelwoodPresence("B", t - 30)
    tcheck(Timers.OnOtherSongflower("A", { at = t }) == true, "first witnessed pick lands", fails)
    tcheck(Timers.OnOtherSongflower("B", { at = t + 1 }) == false,
        "a second witnessed pick within 5s is throttled", fails)

    -- (i) gate 8: a node timer younger than 1440s is not overwritten by someone
    -- else's pick — but OUR own cast (no guard) still wins outright.
    reset()
    timers.flower = { [5] = t - 100 }
    Timers.NoteFelwoodPresence("Late", t - 30)
    tcheck(Timers.OnOtherSongflower("Late", { at = t }) == false,
        "a node timer 100s old is not overwritten by a witnessed pick", fails)
    tcheck(timers.flower[5] == t - 100, "the fresher local timer survives", fails)
    tcheck(Timers.MarkNode("flower", 5, t, "local") == true,
        "our own pick has no overwrite guard and wins", fails)

    -- (j) our OWN aura gain is not a witnessed pick (the cast path owns it).
    reset()
    tcheck(Timers.OnOtherSongflower("Tester", { at = t }) == false,
        "our own name is never treated as another player's pick", fails)

    -- (k) presence refresh floor: a sighting inside 180s does not move the stamp,
    -- which is what keeps a player in combat next to us from staying eligible.
    reset()
    Timers.NoteFelwoodPresence("Sticky", t - 30)
    tcheck(Timers.NoteFelwoodPresence("Sticky", t) == false,
        "a re-sighting inside 180s does not refresh the stamp", fails)
    tcheck(Timers._felwoodSeen["Sticky"] == t - 30, "the original stamp is kept", fails)
    tcheck(Timers.NoteFelwoodPresence("Sticky", t + 200) == true,
        "a re-sighting past 180s refreshes the stamp", fails)

    -- (l) outside Felwood the whole engine is inert.
    reset()
    mapID = 1454
    Timers.InvalidateFelwoodCache()
    Timers.NoteFelwoodPresence("Friendo", t - 30)
    tcheck(Timers.FelwoodCombatLog("SPELL_AURA_APPLIED", PGUID, "Friendo",
                                   PGUID, "Friendo", 0x10, Timers.SONGFLOWER_AURA, t) == false,
        "the witness engine is inert outside Felwood", fails)
    mapID = Timers.FELWOOD_MAP
    Timers.InvalidateFelwoodCache()

    -- (m) a non-songflower aura and a non-player destination are both ignored.
    reset()
    Timers.NoteFelwoodPresence("Friendo", t - 30)
    tcheck(Timers.FelwoodCombatLog("SPELL_AURA_APPLIED", PGUID, "Friendo",
                                   PGUID, "Friendo", 0x10, 12345, t) == false,
        "an unrelated aura is ignored", fails)
    tcheck(Timers.FelwoodCombatLog("SPELL_AURA_APPLIED", PGUID, "Friendo",
                                   NGUID, "Some Mob", 0x40, Timers.SONGFLOWER_AURA, t) == false,
        "a non-player aura destination is ignored", fails)

    -- (n) the loading-screen wipe clears all three lists; the zone-change sweep
    -- clears only last-seen.
    Timers.NoteFelwoodPresence("Wipeme", t)
    Timers._felwoodHadFlower["Wipeme"] = true
    Timers.ResetFelwoodPresence(true)
    tcheck(Timers._felwoodSeen["Wipeme"] == nil, "zone sweep clears last-seen", fails)
    tcheck(Timers._felwoodHadFlower["Wipeme"] == true, "zone sweep keeps the had-buff list", fails)
    Timers.ResetFelwoodPresence(false)
    tcheck(Timers._felwoodHadFlower["Wipeme"] == nil, "loading screen clears the had-buff list", fails)

    _G.C_Map = savedMap
    Timers.InvalidateFelwoodCache()
    reset()
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
    -- F10 keep-max-epoch: the merged row's epoch advanced to a+10, so the next
    -- distinct pop must clear the +/-30s window from THERE (a+45 > a+10+30).
    -- Old expectation used a+40, which is exactly 30s from the advanced epoch —
    -- a boundary duplicate under the new (spec SN 10.1) semantics, not a new row.
    ns.Store.AddTimerLog("rend", { epoch = a + 45, who = "same", trust = "local" })
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
    -- ROUND-17 audit fix 6 — the four-state machine.
    --   unknown -> down -> expired -> stale
    -- There is no indefinite "up": a node that respawned an hour ago tells us
    -- nothing about whether it is standing there now, and reading "up" forever
    -- was a claim we could not support.
    local W = FLOWER_EXPIRED_WINDOW
    local st0 = Timers.NodeState(0, 1000, NODE_RESPAWN)
    tcheck(st0.state == "unknown", "no pop => unknown", fails)
    tcheck(st0.remaining == 0, "unknown carries no remaining", fails)

    local pop = 1000
    local stDown = Timers.NodeState(pop, pop + 100, NODE_RESPAWN)
    tcheck(stDown.state == "down" and math.abs(stDown.remaining - (NODE_RESPAWN - 100)) < 0.5,
        "picked node counts down", fails)

    -- Boundary: one second BEFORE respawn is still down.
    local stEdgeDown = Timers.NodeState(pop, pop + NODE_RESPAWN - 1, NODE_RESPAWN)
    tcheck(stEdgeDown.state == "down", "1s before respawn is still down", fails)
    -- Exactly at respawn it flips to expired with remaining 0.
    local stEdgeExp = Timers.NodeState(pop, pop + NODE_RESPAWN, NODE_RESPAWN)
    tcheck(stEdgeExp.state == "expired" and stEdgeExp.remaining == 0,
        "at exactly respawn => expired, remaining 0", fails)

    -- Inside the expired band `remaining` is NEGATIVE, so the renderer can show
    -- "-M:SS" without a second field telling it which side of zero it is on.
    local stExp = Timers.NodeState(pop, pop + NODE_RESPAWN + 80, NODE_RESPAWN)
    tcheck(stExp.state == "expired", "just-respawned node reads expired", fails)
    tcheck(math.abs(stExp.remaining + 80) < 0.5, "expired remaining is negative (-80)", fails)
    tcheck(math.abs(stExp.since - 80) < 0.5, "expired `since` is positive", fails)

    -- Last second of the band is expired; one past it is stale.
    local stExpEdge = Timers.NodeState(pop, pop + NODE_RESPAWN + W - 1, NODE_RESPAWN)
    tcheck(stExpEdge.state == "expired", "last second of the expired window", fails)
    local stStale = Timers.NodeState(pop, pop + NODE_RESPAWN + W, NODE_RESPAWN)
    tcheck(stStale.state == "stale", "past the expired window => stale", fails)
    tcheck(stStale.remaining == 0, "stale carries no remaining", fails)
    local stStaleOld = Timers.NodeState(pop, pop + NODE_RESPAWN + 100000, NODE_RESPAWN)
    tcheck(stStaleOld.state == "stale", "a day-old pop is stale, never 'up'", fails)

    -- A custom window moves only the expired/stale boundary.
    local stW = Timers.NodeState(pop, pop + NODE_RESPAWN + 50, NODE_RESPAWN, 100)
    tcheck(stW.state == "expired", "custom window: inside => expired", fails)
    local stW2 = Timers.NodeState(pop, pop + NODE_RESPAWN + 150, NODE_RESPAWN, 100)
    tcheck(stW2.state == "stale", "custom window: outside => stale", fails)
    -- A zero window skips the expired band entirely.
    local stW0 = Timers.NodeState(pop, pop + NODE_RESPAWN + 1, NODE_RESPAWN, 0)
    tcheck(stW0.state == "stale", "zero window => straight to stale", fails)

    -- legacyState keeps un-migrated consumers working: they read the old
    -- three-word vocabulary and never see "expired"/"stale".
    tcheck(st0.legacyState == "unknown", "legacy: unknown -> unknown", fails)
    tcheck(stDown.legacyState == "down", "legacy: down -> down", fails)
    tcheck(stExp.legacyState == "up", "legacy: expired -> up", fails)
    tcheck(stStale.legacyState == "up" or stStale.legacyState == "unknown",
        "legacy: stale projects onto the old vocabulary", fails)
    tcheck(stStale.legacyState == "unknown", "legacy: stale -> unknown (too old to assert)", fails)
    for _, s in ipairs({ st0, stDown, stExp, stStale }) do
        tcheck(s.legacyState == "up" or s.legacyState == "down" or s.legacyState == "unknown",
            "legacyState only ever uses the old three states", fails)
    end
end

-- ROUND-17 audit fix 1 — THE headline bug: a setting must never be able to
-- shorten the respawn countdown.
local function testRespawnSettingSplit(fails)
    local pops = nodePopTable("flower")
    if not pops then
        fails[#fails + 1] = "respawn split: no flower pop table"
        return
    end
    local s = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
    local fw = s and s.timerSettings and s.timerSettings.felwood
    if not fw then
        fails[#fails + 1] = "respawn split: no felwood settings block"
        return
    end
    local savedMinus, savedWin = fw.flowerMinusDuration, fw.flowerExpiredWindow
    local savedPop = pops[1]

    -- Reproduce the exact poisoned save an SN import used to produce: SN's
    -- 120s minus-timer copied into the key GetNodeState read as the RESPAWN.
    fw.flowerMinusDuration = 120
    fw.flowerExpiredWindow = nil
    pops[1] = now() - 200

    local st = Timers.GetNodeState("flower1")
    -- Before the fix this read "up" at 200s: the flower "respawned" after two
    -- minutes and the owner saw a 25-minute node go available in a tenth of it.
    tcheck(st.state == "down", "poisoned flowerMinusDuration no longer shortens the respawn", fails)
    tcheck(st.remaining > 1200,
        "a 200s-old pick still has >20min left regardless of the setting", fails)

    -- Every sub-respawn value behaves identically — the setting is simply not
    -- consulted for the countdown any more.
    for _, poison in ipairs({ 5, 90, 120, 300, 900, 1499 }) do
        fw.flowerMinusDuration = poison
        local p = Timers.GetNodeState("flower1")
        tcheck(p.state == "down" and p.remaining > 1200,
            "respawn ignores flowerMinusDuration = " .. poison, fails)
    end

    -- The expired WINDOW is the thing the setting now moves.
    fw.flowerExpiredWindow = 100
    pops[1] = now() - (NODE_RESPAWN + 50)
    tcheck(Timers.GetNodeState("flower1").state == "expired",
        "inside the configured expired window", fails)
    pops[1] = now() - (NODE_RESPAWN + 150)
    tcheck(Timers.GetNodeState("flower1").state == "stale",
        "outside the configured expired window", fails)

    -- The window is clamped, so a junk or hostile value cannot produce nonsense.
    fw.flowerExpiredWindow = 99999
    tcheck(Timers.ExpiredWindow() == 900, "expired window clamps to 900", fails)
    fw.flowerExpiredWindow = -5
    tcheck(Timers.ExpiredWindow() == 0, "negative expired window clamps to 0", fails)
    fw.flowerExpiredWindow = "banana"
    tcheck(Timers.ExpiredWindow() == FLOWER_EXPIRED_WINDOW,
        "non-numeric expired window falls back to the default", fails)
    fw.flowerExpiredWindow = nil
    tcheck(Timers.ExpiredWindow() == FLOWER_EXPIRED_WINDOW,
        "absent expired window falls back to the default", fails)

    -- Tubers and dragons use the same constant respawn.
    for _, kind in ipairs({ "tuber", "dragon" }) do
        local tp = nodePopTable(kind)
        if tp then
            local sv = tp[1]
            tp[1] = now() - 200
            local ts = Timers.GetNodeState(kind .. "1")
            tcheck(ts.state == "down" and ts.remaining > 1200,
                kind .. " uses the 1500s respawn too", fails)
            tp[1] = sv
        end
    end

    fw.flowerMinusDuration, fw.flowerExpiredWindow = savedMinus, savedWin
    pops[1] = savedPop
end

-- ROUND-17 audit fix 2 — the overwrite-guard matrix, per source.
-- A locally-observed pick owns its node for the full 1500s respawn; every
-- network source honours that plus the +/-10s duplicate guard.
local function testNodeGuardMatrix(fails)
    local pops = nodePopTable("flower")
    if not pops then fails[#fails + 1] = "guard matrix: no flower pop table"; return end
    local t = now()
    local IDX = 7
    local function reset(epoch, trust)
        pops[IDX] = epoch
        Timers._nodeTrust["flower" .. IDX] = trust
    end

    -- Baseline, no guards: newest-wins, older/equal refused.
    reset(t - 100, "nwb")
    tcheck(Timers.MarkNode("flower", IDX, t - 200, "nwb") == false,
        "an older epoch is always refused", fails)
    tcheck(Timers.MarkNode("flower", IDX, t - 100, "nwb") == false,
        "an identical epoch is refused (dup relay)", fails)

    -- LOCAL PICK PROTECTION. Our own pick 60s ago; each network source tries to
    -- overwrite it with something much newer and must be refused for 1500s.
    for _, src in ipairs({ "nwb", "mesh", "sn" }) do
        reset(t - 60, "local")
        tcheck(Timers.MarkNode("flower", IDX, t, src, netNodeOpts()) == false,
            src .. " cannot stomp a 60s-old LOCAL pick", fails)
        tcheck(pops[IDX] == t - 60, src .. " left the local epoch intact", fails)
    end

    -- ...for the WHOLE respawn, right up to the boundary.
    reset(t - (NODE_RESPAWN - 1), "local")
    tcheck(Timers.MarkNode("flower", IDX, t, "nwb", netNodeOpts()) == false,
        "local pick is protected 1s before its respawn elapses", fails)
    -- Once the respawn HAS elapsed the node is fair game again.
    reset(t - (NODE_RESPAWN + 1), "local")
    tcheck(Timers.MarkNode("flower", IDX, t, "nwb", netNodeOpts()) == true,
        "after the full respawn a network epoch may take the node", fails)
    tcheck(Timers._nodeTrust["flower" .. IDX] == "nwb", "trust follows the winning write", fails)

    -- The hold applies ONLY to a stored LOCAL pick: second-hand data is freely
    -- superseded by fresher second-hand data.
    reset(t - 60, "nwb")
    tcheck(Timers.MarkNode("flower", IDX, t, "mesh", netNodeOpts()) == true,
        "a network epoch may overwrite a 60s-old NETWORK epoch", fails)

    -- +/-10s CROSS-SOURCE DUPLICATE GUARD (NWB §5.7): the same pick arriving
    -- from a second source, a few seconds later, is not a new observation.
    reset(t - 60, "nwb")
    tcheck(Timers.MarkNode("flower", IDX, t - 55, "mesh", netNodeOpts()) == false,
        "an epoch 5s newer is a cross-source duplicate", fails)
    reset(t - 60, "nwb")
    tcheck(Timers.MarkNode("flower", IDX, t - 51, "mesh", netNodeOpts()) == false,
        "an epoch 9s newer is still a duplicate", fails)
    reset(t - 60, "nwb")
    tcheck(Timers.MarkNode("flower", IDX, t - 50, "mesh", netNodeOpts()) == true,
        "an epoch exactly 10s newer is accepted", fails)

    -- Our OWN pick passes no guard and wins outright, even over a fresher
    -- network epoch — it is position- and spell-validated.
    reset(t - 5, "nwb")
    tcheck(Timers.MarkNode("flower", IDX, t, "local") == true,
        "our own pick overrides recent network data with no guard", fails)
    tcheck(Timers._nodeTrust["flower" .. IDX] == "local", "own pick records local trust", fails)

    -- Trust is PERSISTED in the timers graph, so a /reload inside the 25 minutes
    -- does not quietly downgrade our pick to stompable.
    local tt = ns.Store and ns.Store.GetTimers and ns.Store.GetTimers()
    tcheck(tt and type(tt.nodeTrust) == "table" and tt.nodeTrust["flower" .. IDX] == "local",
        "node trust rides the persisted timers table", fails)

    pops[IDX] = nil
    Timers._nodeTrust["flower" .. IDX] = nil
end

-- ROUND-17 audit fix 5 — own-pick aura fallback.
local function testOwnPickAuraFallback(fails)
    local pops = nodePopTable("flower")
    if not pops then fails[#fails + 1] = "aura fallback: no flower pop table"; return end

    local savedAuras, savedName = _G.C_UnitAuras, _G.UnitName
    local savedGetTime, savedMap = _G.GetTime, _G.C_Map
    local NODE = Timers.NODES.flower[5]
    local t = now()

    -- Stand exactly on flower 5, in Felwood, as ourselves.
    local pos = { x = NODE.x, y = NODE.y }
    _G.C_Map = {
        GetBestMapForUnit = function() return Timers.FELWOOD_MAP end,
        GetPlayerMapPosition = function()
            return { GetXY = function() return pos.x, pos.y end }
        end,
    }
    Timers.InvalidateFelwoodCache()
    _G.UnitName = function(u) return (u == "player") and "Me" or "Someone" end
    _G.GetTime  = function() return 10000 end

    local function setAura(remaining)
        if remaining == nil then
            _G.C_UnitAuras = { GetBuffDataByIndex = function() return nil end }
            return
        end
        _G.C_UnitAuras = { GetBuffDataByIndex = function(unit, i)
            if unit == "player" and i == 1 then
                return { spellId = SONGFLOWER_AURA, name = "Songflower Serenade",
                         expirationTime = 10000 + remaining }
            end
            return nil
        end }
    end

    -- A full-duration buff means we picked it in the last second.
    setAura(3600)
    tcheck(Timers.OwnSongflowerRemaining() == 3600, "own remaining reads 3600", fails)
    tcheck(Timers.OwnSongflowerRemaining(10000) >= SONGFLOWER_FRESH_MIN,
        "3600s remaining clears the freshness bar", fails)
    -- The upper-case spellID spelling some builds use must match too.
    _G.C_UnitAuras = { GetBuffDataByIndex = function(unit, i)
        if unit == "player" and i == 1 then
            return { spellID = SONGFLOWER_AURA, expirationTime = 10000 + 3600 }
        end
        return nil
    end }
    tcheck(Timers.OwnSongflowerRemaining() == 3600,
        "aura.spellID (upper-case D) is matched too", fails)
    -- 3599 is the boundary and still counts.
    setAura(3599)
    tcheck(Timers.OwnSongflowerRemaining() >= SONGFLOWER_FRESH_MIN,
        "3599s remaining still counts as a fresh pick", fails)
    -- A buff we were already carrying must NOT create a timer.
    setAura(3000)
    tcheck(Timers.OwnSongflowerRemaining() < SONGFLOWER_FRESH_MIN,
        "3000s remaining is a carried buff, not a pick", fails)
    -- No buff at all, and a durationless aura, both read nil.
    setAura(nil)
    tcheck(Timers.OwnSongflowerRemaining() == nil, "no songflower => nil", fails)
    _G.C_UnitAuras = { GetBuffDataByIndex = function(unit, i)
        if i == 1 then return { spellId = SONGFLOWER_AURA, expirationTime = 0 } end
        return nil
    end }
    tcheck(Timers.OwnSongflowerRemaining() == nil, "expirationTime 0 => nil, never a fresh pick", fails)

    -- END TO END through the real combat-log entry point, which is where the
    -- old code gave up: OnOtherSongflower rejects our own name ("own pick") on
    -- the assumption the 6478 cast event already caught it. When that event does
    -- not fire, this is the only thing standing between the owner and a flower
    -- they picked, stood on, and got no timer for.
    local PGUID = "Player-1-AAA"
    _G.UnitGUID = _G.UnitGUID or function() return PGUID end
    local savedGUID = _G.UnitGUID
    _G.UnitGUID = function(u) return (u == "player") and PGUID or "Player-1-BBB" end

    pops[5] = nil
    Timers._nodeTrust["flower5"] = nil
    setAura(3600)
    local ok = Timers.FelwoodCombatLog("SPELL_AURA_APPLIED", PGUID, "Me",
                                       PGUID, "Me", 0, SONGFLOWER_AURA, t)
    tcheck(ok == true, "own fresh songflower aura marks the node", fails)
    tcheck((pops[5] or 0) == t, "the nearest flower node got our epoch", fails)
    tcheck(Timers._nodeTrust["flower5"] == "local", "own aura pick records LOCAL trust", fails)

    -- A carried buff (login aura burst, chronoboon restore, someone else's
    -- flower refreshing ours) must never manufacture a pick.
    pops[5] = nil
    setAura(3000)
    local ok2 = Timers.FelwoodCombatLog("SPELL_AURA_APPLIED", PGUID, "Me",
                                        PGUID, "Me", 0, SONGFLOWER_AURA, t)
    tcheck(ok2 == false and (pops[5] or 0) == 0,
        "a carried songflower buff marks nothing", fails)

    -- A chronoboon release re-applies a stored songflower at full duration, so
    -- the duration test alone cannot distinguish it from a pick. Suppressed.
    pops[5] = nil
    setAura(3600)
    Timers._felwoodUnboon["Me"] = t
    local ok3 = Timers.FelwoodCombatLog("SPELL_AURA_APPLIED", PGUID, "Me",
                                        PGUID, "Me", 0, SONGFLOWER_AURA, t)
    tcheck(ok3 == false and (pops[5] or 0) == 0,
        "a chronoboon release is not a pick even at full duration", fails)
    Timers._felwoodUnboon["Me"] = nil

    -- Standing nowhere near a node records nothing, however fresh the buff.
    pops[5] = nil
    pos.x, pos.y = 0.9, 0.9
    Timers.InvalidateFelwoodCache()
    setAura(3600)
    local ok4 = Timers.FelwoodCombatLog("SPELL_AURA_APPLIED", PGUID, "Me",
                                        PGUID, "Me", 0, SONGFLOWER_AURA, t)
    tcheck(ok4 == false and (pops[5] or 0) == 0,
        "a fresh buff away from every node marks nothing", fails)

    _G.C_UnitAuras = savedAuras
    _G.UnitName    = savedName
    _G.GetTime     = savedGetTime
    _G.UnitGUID    = savedGUID
    _G.C_Map       = savedMap
    Timers.InvalidateFelwoodCache()
    pops[5] = nil
    Timers._nodeTrust["flower5"] = nil
end

-- ROUND-17 audit fix 8 — dragon nodes d1..d4.
local function testDragonNodes(fails)
    tcheck(type(Timers.NODES.dragon) == "table" and #Timers.NODES.dragon == 4,
        "four dragon nodes defined", fails)
    tcheck(Timers.NODE_COUNTS.dragon == 4, "dragon node count is 4", fails)
    -- Coordinates match NWB_BEHAVIOR_SPEC §6.2 (normalized from map percent).
    local d = Timers.NODES.dragon
    tcheck(math.abs(d[1].x - 0.425) < 1e-9 and math.abs(d[1].y - 0.139) < 1e-9,
        "dragon 1 at 42.5 / 13.9", fails)
    tcheck(math.abs(d[4].x - 0.407) < 1e-9 and math.abs(d[4].y - 0.783) < 1e-9,
        "dragon 4 at 40.7 / 78.3", fails)
    -- 11952 is DETECTED now, not discarded.
    tcheck(Timers._lootItemNode[11952] == "dragon",
        "Night Dragon's Breath (11952) maps to a dragon node", fails)
    tcheck(Timers._lootItemNode[11951] == "tuber", "Whipper Root Tuber still maps to tuber", fails)
    -- Dragons share the tuber match radius (2.0 map-percent).
    tcheck(Timers.NODE_MATCH_RADIUS_BY_KIND.dragon == 0.02, "dragon radius is 0.02", fails)
    -- The store table is lazily created and MarkNode round-trips through it.
    local pops = nodePopTable("dragon")
    tcheck(type(pops) == "table", "dragon pop table is lazily created", fails)
    if pops then
        local t = now()
        tcheck(Timers.MarkNode("dragon", 2, t, "local") == true, "a dragon pick records", fails)
        tcheck(Timers.GetNodeState("dragon2").state == "down", "dragon node counts down", fails)
        -- NWB d1..d4 keys ingest.
        local a = Timers.IngestNWBTimers({ d1 = t - 100 })
        tcheck((a.dragon or 0) == 1, "NWB d1 key ingested", fails)
        tcheck(pops[1] == t - 100, "d1 epoch stored", fails)
        -- Snapshot carries dragons (additive; old peers ignore the field).
        local snap = Timers.GetSnapshot()
        tcheck(type(snap.dragon) == "table" and snap.dragon[2] == t,
            "mesh snapshot includes dragon epochs", fails)
        pops[1], pops[2] = nil, nil
        Timers._nodeTrust["dragon2"] = nil
    end
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
    tcheck(parts[5] == "PAYLOAD", "field 5 carries the serialized data", fails)

    -- ROUND-17 audit fix 4: field 4 is BASE-36 of floor((serverTime+1998)/1000),
    -- and the receiver recomputes it from its own clock and demands EQUALITY
    -- before merging bulk data. It used to be a decimal string built by chopping
    -- three characters off tostring(serverTime + 1998) — a different function
    -- AND a different alphabet, so every request we sent was discarded on
    -- arrival. "numeric" was exactly the assertion that let that through, so the
    -- test now pins the encoding itself rather than its shape.
    tcheck(Timers.ToBase36(0)  == "0",  "base36(0) = 0",  fails)
    tcheck(Timers.ToBase36(35) == "z",  "base36(35) = z", fails)
    tcheck(Timers.ToBase36(36) == "10", "base36(36) = 10", fails)
    tcheck(Timers.ToBase36(1295) == "zz", "base36(1295) = zz", fails)
    tcheck(Timers.ToBase36(1296) == "100", "base36(1296) = 100", fails)
    -- A real Whitemane-era clock: the bucket must round-trip through base 36.
    local sampleST = 1785275503
    local expectBucket = math.floor((sampleST + 1998) / 1000)
    tcheck(expectBucket == 1785277 and Timers.ToBase36(expectBucket) == "129j1",
        "base36 bucket for a live server time", fails)
    -- And the live field must equal base36 of the bucket from the SAME clock the
    -- builder read, not merely parse as a number.
    local st = (GetServerTime and GetServerTime()) or 0
    tcheck(parts[4] == Timers.ToBase36(math.floor((st + 1998) / 1000)),
        "field 4 is base-36 of floor((serverTime+1998)/1000)", fails)
    tcheck(parts[4]:match("^[0-9a-z]+$") ~= nil,
        "field 4 uses the lowercase base-36 alphabet", fails)
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

-- NWB timer payload ingest — flat short keys, layered realms, word keys, the
-- +/-120s yell validation, the Era Nefarian rejection, and the timer log.
local function testNWBIngest(fails)
    local t = now()
    local timersStore = ns.Store and ns.Store.GetTimers and ns.Store.GetTimers()
    local function reset()
        Timers.state = {}
        if timersStore then timersStore.flower, timersStore.tuber = {}, {} end
        -- Wipe node trust too: the pop tables and the trust map must be reset
        -- together or a stale "local" from an earlier case silently arms the
        -- hold guard against the next one.
        for i = 1, 10 do Timers._nodeTrust["flower" .. i] = nil end
        for i = 1, 6  do Timers._nodeTrust["tuber" .. i]  = nil end
    end

    -- Every drop epoch must now travel with its stage-1 yell epoch:
    --   n/o = rend drop/yell1 · s/t = ony drop/yell1 · y/z = nef drop/yell1.
    reset()
    local a1 = Timers.IngestNWBTimers({
        n = t - 100, o = t - 110,
        s = t - 200, t = t - 210,
        f1 = t - 50, t3 = t - 60,
    })
    tcheck(a1.rend and a1.ony, "flat n/s short keys ingested with their yell epochs", fails)
    tcheck((a1.flower or 0) >= 1 and (a1.tuber or 0) >= 1, "flat flower/tuber ingested", fails)

    -- Layered realm: timers nested under the literally-named `layers` key.
    --
    -- World buffs flatten across layers (they genuinely drop on every layer at
    -- once). Songflowers now follow the FILL-AND-GUARD policy — see the comment
    -- on Timers.IngestNWBTimers. The old assertions here pinned audit fix 3's
    -- "ignore per-layer nodes entirely", which on a layered realm (where nothing
    -- arrives flat) meant ingesting no songflowers at all.
    reset()
    local a2 = Timers.IngestNWBTimers({ layers = { [1] = { n = t - 300, o = t - 310, f2 = t - 70 } } })
    tcheck(a2.rend, "layered rend ingested from payload.layers", fails)
    tcheck((a2.flower or 0) == 1, "layered flower INGESTED (fills an empty node)", fails)
    tcheck((nodePopTable("flower") or {})[2] == t - 70,
        "the layer's node epoch really was written", fails)
    tcheck(Timers._nodeTrust["flower2"] == "nwbLayer",
        "a layer-sourced write records nwbLayer trust, not nwb", fails)

    -- The heuristic layer-map fallback (payload without a literal `layers` key)
    -- takes the same path.
    reset()
    local a2b = Timers.IngestNWBTimers({ someMap = { [1] = { n = t - 300, o = t - 310, f4 = t - 70 } } })
    tcheck(a2b.rend, "heuristic layer map still ingests buffs", fails)
    tcheck((a2b.flower or 0) == 1, "heuristic layer map ingests nodes too", fails)
    tcheck((nodePopTable("flower") or {})[4] == t - 70,
        "heuristic layer map wrote the node epoch", fails)

    -- Top-level and per-layer copies of the same node: both are read, and the
    -- ordinary network rule decides. The layer copy here is 70s newer, so it
    -- takes the node (newest-wins past the 10s duplicate guard).
    reset()
    local a2c = Timers.IngestNWBTimers({
        f3 = t - 80, layers = { [1] = { f3 = t - 10 } },
    })
    tcheck((a2c.flower or 0) == 2, "top-level AND layer flower both applied", fails)
    tcheck((nodePopTable("flower") or {})[3] == t - 10,
        "the newer of the two epochs holds the node", fails)
    -- ...and when the per-layer copy is the OLDER one, the top-level survives.
    reset()
    local a2d = Timers.IngestNWBTimers({
        f3 = t - 10, layers = { [1] = { f3 = t - 80 } },
    })
    tcheck((nodePopTable("flower") or {})[3] == t - 10,
        "an older per-layer epoch does not rewind the top-level one", fails)
    tcheck((a2d.rejOlder or 0) >= 1, "the older layer epoch is counted as rejOlder", fails)
    tcheck(Timers._nodeTrust["flower3"] == "nwb", "trust stays nwb when the layer loses", fails)

    -- Word keys tolerated (un-compacted layer).
    reset()
    local a3 = Timers.IngestNWBTimers({ rendTimer = t - 100, o = t - 105, flower5 = t - 40 })
    tcheck(a3.rend and (a3.flower or 0) >= 1, "word keys tolerated", fails)

    ------------------------------------------------------------------
    -- +/-120s yell-vs-drop validation. We used to accept anything above 1e9,
    -- so a single malformed sender could plant a cooldown that never cleared.
    ------------------------------------------------------------------

    -- (a) a drop with NO stage-1 yell discards the WHOLE table.
    reset()
    local v = Timers.ValidateNWBDrops({ n = t - 100 }, t)
    tcheck(v.ok == false, "a drop with no stage-1 yell invalidates the payload", fails)
    local a4 = Timers.IngestNWBTimers({ n = t - 100, f1 = t - 50,
                                        F = { { G = "r", H = t - 700, J = "Eve" } } })
    tcheck(not a4.rend, "rejected payload records no rend anchor", fails)
    tcheck((a4.rejectedPayload or 0) >= 1, "whole-payload rejection is counted", fails)
    -- F14: the rejection is about the DROP ANCHORS. Felwood nodes and the timer
    -- log are read before it and have their own guards, so a bad drop field no
    -- longer throws away a whole payload's songflowers or its Rend log.
    tcheck((a4.flower or 0) == 1, "a rejected payload's flowers still merge (F14)", fails)
    tcheck((nodePopTable("flower") or {})[1] == t - 50,
        "the flower epoch really was written despite the rejection", fails)
    tcheck((a4.logApplied or 0) == 1, "a rejected payload's timer log still merges (F14)", fails)
    tcheck(Timers.state.rend and Timers.state.rend.lastPop == t - 700,
        "the log anchored Rend even though the drop set was rejected", fails)

    -- (b) yell within +/-120s of the drop is ACCEPTED, on both sides.
    reset()
    v = Timers.ValidateNWBDrops({ n = t - 100, o = t - 100 - 119 }, t)
    tcheck(v.ok and v.accept.rend == t - 100, "yell 119s before the drop accepted", fails)
    v = Timers.ValidateNWBDrops({ n = t - 100, o = t - 100 + 119 }, t)
    tcheck(v.ok and v.accept.rend == t - 100, "yell 119s after the drop accepted", fails)

    -- (c) beyond +/-120s the BUFF is stripped, but the table still merges.
    reset()
    v = Timers.ValidateNWBDrops({ n = t - 100, o = t - 100 - 121 }, t)
    tcheck(v.ok and v.accept.rend == nil and v.reject.rend ~= nil,
        "yell 121s before the drop strips rend", fails)
    v = Timers.ValidateNWBDrops({ n = t - 100, o = t - 100 + 121 }, t)
    tcheck(v.ok and v.accept.rend == nil and v.reject.rend ~= nil,
        "yell 121s after the drop strips rend", fails)
    local a5 = Timers.IngestNWBTimers({ n = t - 100, o = t - 400, f1 = t - 50 })
    tcheck(not a5.rend, "an out-of-tolerance rend is not anchored", fails)
    tcheck((a5.rejectedYell or 0) >= 1, "per-buff yell rejection is counted", fails)
    tcheck((a5.flower or 0) >= 1, "the rest of the table still merges", fails)

    -- (d) absolute + future sanity clamps.
    tcheck(Timers._nwbEpoch(2585912599, nil, t) == nil, "epoch above the absolute ceiling rejected", fails)
    tcheck(Timers._nwbEpoch(t + 40000, nil, t) == nil, "epoch >30000s in the future rejected", fails)
    tcheck(Timers._nwbEpoch(t + 20000, "rend", t) == nil, "rend epoch past its +10860 clamp rejected", fails)
    tcheck(Timers._nwbEpoch(t + 5000, "rend", t) == t + 5000, "rend epoch inside its clamp accepted", fails)
    tcheck(Timers._nwbEpoch(t + 2000, "node", t) == nil, "node epoch past its +1530 clamp rejected", fails)
    tcheck(Timers._nwbEpoch("not a number", nil, t) == nil, "non-numeric epoch rejected", fails)

    ------------------------------------------------------------------
    -- Nefarian is DISABLED on Era: never anchored, inbound timers dropped.
    ------------------------------------------------------------------
    reset()
    local a6 = Timers.IngestNWBTimers({ y = t - 100, z = t - 110 })
    tcheck((a6.nefRejected or 0) >= 1, "an inbound Nef timer is explicitly rejected", fails)
    tcheck((Timers.state.nefH == nil) or (Timers.state.nefH.lastPop or 0) == 0,
        "no Nef cooldown anchor is computed from the wire", fails)
    tcheck((Timers.state.nefA == nil) or (Timers.state.nefA.lastPop or 0) == 0,
        "no Nef-A anchor either", fails)
    tcheck(Timers.BuffStatus("nefH", t).state == "nodata",
        "Nef reports no cooldown state at all", fails)
    tcheck(Timers.IsCooldownDisabled("nefH") and Timers.IsCooldownDisabled("nefA"),
        "both Nef keys are cooldown-disabled", fails)
    tcheck(not Timers.IsCooldownDisabled("rend") and not Timers.IsCooldownDisabled("onyH"),
        "Rend and Onyxia are still cooldown-tracked", fails)
    -- ...but an announcer KILL still runs the 360s respawn model.
    reset()
    tcheck(Timers.Record("nefH", t, "local", "High Overlord Saurfang", "killed") == true,
        "a Nef announcer kill is still recorded", fails)
    tcheck(Timers.BuffStatus("nefH", t + 60).state == "killed",
        "the Nef kill still reads as a respawn countdown", fails)

    ------------------------------------------------------------------
    -- Timer log (key F). The reference's PREFERRED Rend source on a layered
    -- realm — Whitemane is layered — and we were dropping it on the floor.
    ------------------------------------------------------------------
    -- Entry shape: G = type, H = timestamp, I = layer id, J = who.
    reset()
    local key, epoch, who = Timers.ParseNWBLogEntry({ G = "r", H = t - 500, I = 1454, J = "Bob" }, t)
    tcheck(key == "rend" and epoch == t - 500 and who == "Bob", "log type 'r' -> a Rend drop", fails)
    -- 'q' is a HAND-IN. The parser reports it as one and returns the RAW stamp;
    -- the +15s assumed-drop lead now lives on the single hand-in path (F7) so it
    -- cannot be applied twice or forgotten by a new caller.
    local handin
    key, epoch, who, _, handin = Timers.ParseNWBLogEntry({ G = "q", H = t - 500, I = 1454, J = "Bob" }, t)
    tcheck(key == "rend" and epoch == t - 500 and handin == true,
        "log type 'q' -> a Rend HAND-IN at its raw stamp", fails)
    tcheck(Timers.AssumedDropEpoch(t - 500) == (t - 500) + Timers.HANDIN_LEAD,
        "the assumed drop is hand-in + 15s", fails)
    tcheck(Timers.NWB_HANDIN_LEAD == Timers.HANDIN_LEAD,
        "the NWB lead alias and the shared lead are one constant", fails)
    local _, _, _, _, notHandin = Timers.ParseNWBLogEntry({ G = "r", H = t - 500 }, t)
    tcheck(notHandin == false, "a drop entry is not flagged as a hand-in", fails)
    key = Timers.ParseNWBLogEntry({ G = "o", H = t - 500 }, t)
    tcheck(key == factionKey("ony"), "log type 'o' -> a faction-resolved Onyxia drop", fails)
    key = Timers.ParseNWBLogEntry({ G = "n", H = t - 500 }, t)
    tcheck(key == factionKey("nef"), "log type 'n' parses as Nefarian", fails)
    tcheck(Timers.ParseNWBLogEntry({ G = "zz", H = t - 500 }, t) == nil, "unknown log type ignored", fails)
    tcheck(Timers.ParseNWBLogEntry({ G = "r" }, t) == nil, "log entry without a timestamp ignored", fails)
    tcheck(Timers.ParseNWBLogEntry("not a table", t) == nil, "non-table log entry ignored", fails)

    -- End to end: a log-only payload anchors Rend through the trust ladder.
    reset()
    local a7 = Timers.IngestNWBTimers({ F = { { G = "r", H = t - 500, I = 1454, J = "Bob" } } })
    tcheck((a7.log or 0) == 1 and (a7.logApplied or 0) == 1, "a log entry is ingested and applied", fails)
    tcheck(Timers.state.rend and Timers.state.rend.lastPop == t - 500,
        "the log entry anchors the Rend cooldown", fails)
    tcheck(Timers.state.rend.trust == "nwb", "the log entry carries nwb trust", fails)
    tcheck(Timers.state.rend.who == "Bob", "the log entry's 'who' is attributed", fails)

    -- A hand-in entry lands 15s later than its raw stamp.
    reset()
    Timers._handinStash = {}
    Timers.IngestNWBTimers({ F = { { G = "q", H = t - 500, I = 1454, J = "Ann" } } })
    tcheck(Timers.state.rend and Timers.state.rend.lastPop == (t - 500) + Timers.HANDIN_LEAD,
        "a 'q' hand-in anchors at +15s", fails)

    -- A Nefarian log entry is rejected with everything else Nef.
    reset()
    local a8 = Timers.IngestNWBTimers({ F = { { G = "n", H = t - 500 } } })
    tcheck((a8.nefRejected or 0) >= 1, "a Nef log entry is rejected", fails)
    tcheck((a8.logApplied or 0) == 0, "no Nef log entry is applied", fails)

    -- The log rides alongside timers, and the log array is no longer mistaken
    -- for a layer map by the fallback scan.
    reset()
    local a9 = Timers.IngestNWBTimers({
        s = t - 200, t = t - 210,
        F = { { G = "r", H = t - 600, J = "Cid" }, { G = "q", H = t - 500, J = "Dee" } },
    })
    tcheck(a9.ony, "the ony timer still merges alongside a log", fails)
    -- F1 — the log is PRE-SCANNED and only the newest entry per buff reaches
    -- Record, so `log` counts BUFFS anchored, not raw entries. The old code
    -- Recorded every entry in wire order, which made array order decide the
    -- anchor: here the 'q' hand-in at (t-500)+15 is newer than the 'r' drop at
    -- t-600, so it is the one that must win regardless of position.
    tcheck((a9.log or 0) == 1, "one buff anchored from a two-entry log", fails)
    tcheck(Timers.state.rend and Timers.state.rend.lastPop == (t - 500) + Timers.HANDIN_LEAD,
        "the NEWEST log entry takes the anchor (max, not first)", fails)
    tcheck((a9.logApplied or 0) == 1, "the newest entry applied", fails)

    -- Order-independence: the same two entries in the opposite wire order must
    -- produce the identical anchor (this is the rewind the old walk allowed).
    reset()
    local a9b = Timers.IngestNWBTimers({
        F = { { G = "q", H = t - 500, J = "Dee" }, { G = "r", H = t - 600, J = "Cid" } },
    })
    tcheck((a9b.log or 0) == 1, "reversed order still anchors exactly one buff", fails)
    tcheck(Timers.state.rend and Timers.state.rend.lastPop == (t - 500) + Timers.HANDIN_LEAD,
        "wire order does not change which log entry wins", fails)

    -- An old entry arriving after a newer one can no longer rewind the anchor:
    -- the pre-scan collapses them, and the rewind guard is the backstop.
    reset()
    Timers.IngestNWBTimers({ F = { { G = "o", H = t - 100, J = "New" } } })
    local onyKey = factionKey("ony")
    local anchoredAt = Timers.state[onyKey] and Timers.state[onyKey].lastPop
    Timers.IngestNWBTimers({ F = { { G = "o", H = t - 20000, J = "Old" } } })
    tcheck(Timers.state[onyKey].lastPop == anchoredAt,
        "an older log entry in a later payload cannot rewind the anchor", fails)

    -- A log entry cannot outrank a local anchor of the same moment.
    reset()
    Timers.Record("rend", t - 600, "local", "Me", "pop")
    local a10 = Timers.IngestNWBTimers({ F = { { G = "r", H = t - 590, J = "Cid" } } })
    tcheck((a10.logApplied or 0) == 0, "a log entry cannot displace a local anchor", fails)
    tcheck(Timers.state.rend.trust == "local", "local trust is retained", fails)

    reset()
end

-- LAYERED-REALM SONGFLOWER INGEST — the fill-and-guard policy.
--
-- On a layered realm the songflower epochs arrive ONLY inside the per-layer map;
-- nothing is written flat. Reading node keys from the top-level payload alone
-- therefore ingested no songflowers at all and every cell read "No data". These
-- cases pin the replacement policy and its honest limits.
local function testNWBLayerFlowers(fails)
    local t = now()
    local timersStore = ns.Store and ns.Store.GetTimers and ns.Store.GetTimers()
    if not timersStore then
        fails[#fails + 1] = "layer flowers: no timers store"; return
    end
    local function reset()
        Timers.state = {}
        timersStore.flower, timersStore.tuber = {}, {}
        for i = 1, 10 do Timers._nodeTrust["flower" .. i] = nil end
    end
    local function pops() return nodePopTable("flower") or {} end
    -- Snapshot of the cumulative totals, for the delta assertions below.
    local function totals()
        local out, src = {}, Timers._nwbStats.flowerTotals or {}
        for i = 1, #Timers._flowerCounters do
            local k = Timers._flowerCounters[i]
            out[k] = src[k] or 0
        end
        return out
    end

    ------------------------------------------------------------------
    -- (a) THE BUG. Flowers live only inside `layers`; no top-level f1..f10.
    ------------------------------------------------------------------
    reset()
    local a = Timers.IngestNWBTimers({
        layers = {
            [1] = { f1 = t - 100, f2 = t - 200 },
            [2] = { f1 = t - 900, f5 = t - 300 },
        },
    })
    tcheck(pops()[1] == t - 100, "layered f1 fills a node with no top-level copy", fails)
    tcheck(pops()[2] == t - 200, "layered f2 fills its node too", fails)
    tcheck(pops()[5] == t - 300, "a node present on only one layer still fills", fails)
    tcheck((a.flower or 0) == 3, "three distinct nodes merged from the layers map", fails)
    for _, i in ipairs({ 1, 2, 5 }) do
        tcheck(Timers._nodeTrust["flower" .. i] == "nwbLayer",
            "flower" .. i .. " records nwbLayer trust", fails)
    end
    tcheck((a.layersScanned or 0) == 2, "both layer sub-tables counted as scanned", fails)

    ------------------------------------------------------------------
    -- (b) A LOCAL PICK IS UNTOUCHABLE for the full respawn. Layer data may fill
    --     an empty node; it may never overwrite what we saw with our own eyes.
    ------------------------------------------------------------------
    reset()
    timersStore.flower[7] = t - 60
    Timers._nodeTrust["flower7"] = "local"
    local b = Timers.IngestNWBTimers({ layers = { [1] = { f7 = t } } })
    tcheck(pops()[7] == t - 60, "a 60s-old LOCAL pick survives layer data", fails)
    tcheck(Timers._nodeTrust["flower7"] == "local", "and keeps its local trust", fails)
    tcheck((b.flower or 0) == 0, "nothing counted as merged", fails)
    tcheck((b.rejGuard or 0) == 1, "the refusal is attributed to the local-hold guard", fails)
    -- Right up to the boundary, then fair game once the respawn has elapsed.
    reset()
    timersStore.flower[7] = t - (NODE_RESPAWN - 1)
    Timers._nodeTrust["flower7"] = "local"
    Timers.IngestNWBTimers({ layers = { [1] = { f7 = t } } })
    tcheck(pops()[7] == t - (NODE_RESPAWN - 1),
        "local pick still held 1s before its respawn elapses", fails)
    reset()
    timersStore.flower[7] = t - (NODE_RESPAWN + 1)
    Timers._nodeTrust["flower7"] = "local"
    Timers.IngestNWBTimers({ layers = { [1] = { f7 = t } } })
    tcheck(pops()[7] == t, "after the full respawn layer data may take the node", fails)

    ------------------------------------------------------------------
    -- (c) NEWEST-ACROSS-LAYERS, DETERMINISTICALLY. pairs() order over the layers
    --     map is undefined, so the same three epochs are fed in all six
    --     orderings: the newest must win every time. A per-layer MarkNode call
    --     would fail this — the +/-10s guard would block whichever genuinely
    --     newer epoch happened to arrive second.
    ------------------------------------------------------------------
    local E = { t - 400, t - 200, t - 50 }   -- >10s apart, newest last
    local orders = {
        { 1, 2, 3 }, { 1, 3, 2 }, { 2, 1, 3 },
        { 2, 3, 1 }, { 3, 1, 2 }, { 3, 2, 1 },
    }
    for oi = 1, #orders do
        local o = orders[oi]
        reset()
        local c = Timers.IngestNWBTimers({
            layers = {
                [1] = { f4 = E[o[1]] },
                [2] = { f4 = E[o[2]] },
                [3] = { f4 = E[o[3]] },
            },
        })
        tcheck(pops()[4] == t - 50,
            "newest layer epoch wins (ordering " .. oi .. ")", fails)
        tcheck((c.flower or 0) == 1,
            "exactly ONE write for the node, not one per layer (ordering " .. oi .. ")", fails)
        tcheck((c.rejLayerSkip or 0) == 2,
            "the two losing layer values are counted (ordering " .. oi .. ")", fails)
    end

    ------------------------------------------------------------------
    -- (d) COUNTERS. Per-payload on `applied`, and mirrored as session totals.
    ------------------------------------------------------------------
    reset()
    local before = totals()
    -- f1 on three layers (2 skipped, 1 filled) + f7 held by a local pick.
    timersStore.flower[7] = t - 60
    Timers._nodeTrust["flower7"] = "local"
    local d = Timers.IngestNWBTimers({
        layers = {
            [1] = { f1 = t - 300, f7 = t },
            [2] = { f1 = t - 200 },
            [3] = { f1 = t - 100 },
        },
    })
    tcheck((d.flowerHeard or 0) == 4, "flowerHeard counts every field on every layer", fails)
    tcheck((d.layersScanned or 0) == 3, "layersScanned counts the sub-tables", fails)
    tcheck((d.rejLayerSkip or 0) == 2, "rejLayerSkip counts the outvoted layer values", fails)
    tcheck((d.flowerApplied or 0) == 1, "flowerApplied counts the writes that landed", fails)
    tcheck((d.flowerFilled or 0) == 1, "flowerFilled counts writes onto an EMPTY node", fails)
    tcheck((d.rejGuard or 0) == 1, "rejGuard counts the local-hold refusal", fails)
    local after = totals()
    for _, k in ipairs({ "flowerHeard", "flowerApplied", "flowerFilled",
                         "layersScanned", "rejGuard", "rejLayerSkip" }) do
        tcheck(after[k] - before[k] == (d[k] or 0),
            "session total for " .. k .. " moved by the per-payload amount", fails)
    end
    -- A write onto an already-filled node is applied but NOT counted as a fill.
    reset()
    before = totals()
    timersStore.flower[1] = t - 300
    Timers._nodeTrust["flower1"] = "nwbLayer"
    local d2 = Timers.IngestNWBTimers({ layers = { [1] = { f1 = t - 100 } } })
    tcheck((d2.flowerApplied or 0) == 1, "refreshing a filled node still applies", fails)
    tcheck((d2.flowerFilled or 0) == 0, "...but is not a fill", fails)
    -- ...and one inside the 10s duplicate window is attributed to minNewer.
    reset()
    timersStore.flower[1] = t - 300
    Timers._nodeTrust["flower1"] = "nwbLayer"
    local d3 = Timers.IngestNWBTimers({ layers = { [1] = { f1 = t - 295 } } })
    tcheck((d3.rejMinNewer or 0) == 1, "a 5s-newer layer epoch is a cross-source duplicate", fails)
    tcheck(pops()[1] == t - 300, "and the stored epoch is untouched", fails)

    ------------------------------------------------------------------
    -- (e) REGRESSION — a FLAT (non-layered) payload is unchanged: top-level
    --     flowers still ingest, with trust "nwb" and no layer accounting.
    ------------------------------------------------------------------
    reset()
    local e = Timers.IngestNWBTimers({ f1 = t - 50, f9 = t - 80, t3 = t - 90 })
    tcheck(pops()[1] == t - 50 and pops()[9] == t - 80, "flat top-level flowers ingest", fails)
    tcheck(Timers._nodeTrust["flower1"] == "nwb" and Timers._nodeTrust["flower9"] == "nwb",
        "a flat payload records plain nwb trust", fails)
    tcheck((e.flower or 0) == 2, "applied.flower keeps its meaning on the flat path", fails)
    tcheck((e.layersScanned or 0) == 0, "no layers scanned for a flat payload", fails)
    tcheck((e.flowerHeard or 0) == 2, "flowerHeard counts top-level fields too", fails)
    tcheck((e.tuber or 0) == 1, "top-level tubers still ingest", fails)
    -- Tubers and dragons are PERSONAL on a layered realm and never travel there,
    -- so the per-layer pass must not read them even if a sender includes them.
    reset()
    local e2 = Timers.IngestNWBTimers({ layers = { [1] = { t3 = t - 90, d2 = t - 95 } } })
    tcheck((e2.tuber or 0) == 0 and (e2.dragon or 0) == 0,
        "the per-layer pass is flowers-only", fails)
    tcheck((nodePopTable("tuber") or {})[3] == nil, "no tuber written from a layer", fails)

    ------------------------------------------------------------------
    -- (f) OUR OWN EYES WIN OUTRIGHT. A local pick passes no guard at all — not
    --     the hold, not the 10s duplicate window — so it upgrades a layer fill
    --     the moment we make one.
    ------------------------------------------------------------------
    reset()
    Timers.IngestNWBTimers({ layers = { [1] = { f6 = t - 5 } } })
    tcheck(pops()[6] == t - 5 and Timers._nodeTrust["flower6"] == "nwbLayer",
        "layer fill in place before the local pick", fails)
    tcheck(Timers.MarkNode("flower", 6, t, "local") == true,
        "a local pick overrides a 5s-old layer fill with no guard", fails)
    tcheck(pops()[6] == t, "the local epoch is what the node now holds", fails)
    tcheck(Timers._nodeTrust["flower6"] == "local", "and the node upgrades to local trust", fails)
    -- ...after which the layer data cannot take it back.
    local f2 = Timers.IngestNWBTimers({ layers = { [1] = { f6 = t + 20 } } })
    tcheck(pops()[6] == t, "layer data cannot reclaim a node we just picked", fails)
    tcheck((f2.rejGuard or 0) == 1, "the reclaim attempt is counted as a guard refusal", fails)

    ------------------------------------------------------------------
    -- MarkNode's refusal reasons, which the counters above are built on.
    ------------------------------------------------------------------
    reset()
    timersStore.flower[8] = t - 100
    Timers._nodeTrust["flower8"] = "nwb"
    local ok, why = Timers.MarkNode("flower", 8, t - 200, "nwb", netNodeOpts())
    tcheck(ok == false and why == "older", "MarkNode reports 'older'", fails)
    ok, why = Timers.MarkNode("flower", 8, t - 95, "nwb", netNodeOpts())
    tcheck(ok == false and why == "minNewer", "MarkNode reports 'minNewer'", fails)
    Timers._nodeTrust["flower8"] = "local"
    ok, why = Timers.MarkNode("flower", 8, t, "nwb", netNodeOpts())
    tcheck(ok == false and why == "localHold", "MarkNode reports 'localHold'", fails)
    Timers._nodeTrust["flower8"] = "nwb"
    ok, why = Timers.MarkNode("flower", 8, t, "nwb", { overwriteGuard = NODE_RESPAWN })
    tcheck(ok == false and why == "overwriteGuard", "MarkNode reports 'overwriteGuard'", fails)
    tcheck(select("#", Timers.MarkNode("flower", 8, t, "nwb")) >= 1,
        "a successful MarkNode still returns true first", fails)
    tcheck(Timers.MarkNode("flower", 8, t + 100, "nwb") == true,
        "the extra return value does not disturb == true callers", fails)

    reset()
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

-- Chronoboon unboon gate (spec §13): a buff RESTORED by an unboon reappears on
-- the player looking exactly like a genuine drop. Crediting it would book a
-- garbage yell->land sample and (once the BUFF_GAIN seam is fed) fire a false
-- "gained" alert. tracker.lua owns the 3 s window; timers.lua only consumes it,
-- and must behave exactly as before whenever the tracker is missing or broken.
local function testUnboonGate(fails)
    local savedTracker = ns.Tracker
    local savedAuras   = C_UnitAuras
    local savedPending = Timers._pendingPull

    -- Minimal aura scanner: the player is showing Warchief's Blessing (-> rend).
    _G.C_UnitAuras = { GetBuffDataByIndex = function(unit, i)
        if unit == "player" and i == 1 then return { name = "Warchief's Blessing" } end
        return nil
    end }

    local function armPending()
        Timers._pendingPull = {}
        Timers._setPendingPull("rend", 1000, 2)
    end

    -- (a) Headless / partial load: no Tracker at all must read as "not in a
    --     window" and leave the pre-existing crediting behaviour untouched.
    ns.Tracker = nil
    tcheck(Timers._inUnboonWindow() == false,
        "unboon gate: an absent Tracker reads as not-in-window", fails)
    armPending()
    Timers._onPlayerAura("UNIT_AURA", "player")
    tcheck(Timers._pendingPull.rend == nil,
        "unboon gate: without a Tracker a land still credits", fails)

    -- (b) Window OPEN: the gain is a restore, so nothing is credited...
    ns.Tracker = { InUnboonWindow = function() return true end }
    tcheck(Timers._inUnboonWindow() == true, "unboon gate: an open window reads true", fails)
    armPending()
    Timers._onPlayerAura("UNIT_AURA", "player")
    tcheck(Timers._pendingPull.rend ~= nil,
        "an unboon restore does not credit a pull observation", fails)

    -- ...and crucially the pending is NOT consumed, so the genuine land that
    -- follows the window still calibrates normally.
    ns.Tracker = { InUnboonWindow = function() return false end }
    Timers._onPlayerAura("UNIT_AURA", "player")
    tcheck(Timers._pendingPull.rend == nil,
        "the pending survives the window and credits on the real land", fails)

    -- (c) Window CLOSED: ordinary crediting.
    armPending()
    Timers._onPlayerAura("UNIT_AURA", "player")
    tcheck(Timers._pendingPull.rend == nil,
        "outside the window a land credits normally", fails)

    -- (d) A throwing Tracker must not take the aura handler down with it.
    ns.Tracker = { InUnboonWindow = function() error("boom") end }
    tcheck(Timers._inUnboonWindow() == false,
        "unboon gate: a throwing Tracker reads as not-in-window", fails)
    armPending()
    tcheck(pcall(Timers._onPlayerAura, "UNIT_AURA", "player"),
        "a throwing Tracker does not break the aura handler", fails)

    -- (e) The gate did not disturb the existing non-player short-circuit.
    ns.Tracker = { InUnboonWindow = function() return false end }
    armPending()
    Timers._onPlayerAura("UNIT_AURA", "target")
    tcheck(Timers._pendingPull.rend ~= nil, "a non-player UNIT_AURA is still ignored", fails)

    ns.Tracker          = savedTracker
    _G.C_UnitAuras      = savedAuras
    Timers._pendingPull = savedPending or {}
end

----------------------------------------------------------------------
-- F1 — anchor-rewind matrix by trust.
--
-- The gate that was missing entirely: IsFalsePositive only ever looked FORWARD
-- from the anchor, so any report OLDER than the anchor sailed through and
-- Record wrote it, moving the anchor backwards. Every bulk path could do it
-- (an NWB log walked in wire order, a peer snapshot, an SN log array), and the
-- symptom was a cooldown that jumped BACKWARDS — countdowns growing, warnings
-- resurrected, "ready" un-readying.
----------------------------------------------------------------------
local function testAnchorRewind(fails)
    -- (a) the pure predicate, both directions and every trust relation.
    tcheck(Timers.IsAnchorRewind(0, 100, "local", "nwb") == false,
        "no existing anchor: nothing to rewind", fails)
    tcheck(Timers.IsAnchorRewind(1000, 1000, "nwb", "local") == false,
        "an equal epoch is not a rewind", fails)
    tcheck(Timers.IsAnchorRewind(1000, 1001, "nwb", "local") == false,
        "a newer epoch is never a rewind", fails)
    tcheck(Timers.IsAnchorRewind(1000, 999, "nwb", "nwb") == true,
        "EQUAL trust may not rewind (two opinions, newest already applied)", fails)
    tcheck(Timers.IsAnchorRewind(1000, 999, "nwb", "sn") == true,
        "lower trust may not rewind", fails)
    tcheck(Timers.IsAnchorRewind(1000, 999, "local", "sn") == false,
        "STRICTLY higher trust may rewind (our eyes correct a relay)", fails)
    tcheck(Timers.IsAnchorRewind(1000, 999, "nwb", nil) == false,
        "any tagged source outranks an untagged anchor", fails)

    -- (b) the same matrix through Record, on the pop anchor.
    local t = now() - 40000     -- old enough that no pull bar can be raised
    local function anchorAt(epoch, trust)
        Timers.state = {}
        Timers.Record("rend", epoch, trust, "seed", "pop")
    end

    anchorAt(t, "nwb")
    local ok, why = Timers.Record("rend", t - 20000, "nwb", "older", "pop")
    tcheck(ok == false and tostring(why):find("rewind"),
        "nwb cannot rewind an nwb anchor", fails)
    tcheck(Timers.state.rend.lastPop == t, "the newer anchor is intact", fails)

    anchorAt(t, "mesh")
    tcheck(Timers.Record("rend", t - 20000, "sn", "older", "pop") == false,
        "a LOWER-trust older report cannot rewind", fails)
    tcheck(Timers.state.rend.lastPop == t, "mesh anchor intact against sn", fails)

    anchorAt(t, "nwb")
    tcheck(Timers.Record("rend", t - 20000, "local", "our eyes", "pop") == true,
        "a STRICTLY higher-trust correction may move the anchor back", fails)
    tcheck(Timers.state.rend.lastPop == t - 20000, "the correction is applied", fails)
    tcheck(Timers.state.rend.trust == "local", "and it owns the anchor afterwards", fails)

    anchorAt(t, "sn")
    tcheck(Timers.Record("rend", t - 20000, "sn", "older sn", "pop") == false,
        "sn cannot rewind sn", fails)

    -- (c) the KILL anchor gets the identical guard, checked against killedAt.
    Timers.state = {}
    Timers.Record("onyH", t, "local", "Runthak", "killed")
    tcheck(Timers.Record("onyH", t - 500, "nwb", "NWB", "killed") == false,
        "a lower-trust older kill cannot rewind killedAt", fails)
    tcheck(Timers.state.onyH.killedAt == t, "killedAt intact", fails)
    tcheck(Timers.Record("onyH", t - 500, "local", "Runthak", "killed") == false,
        "equal trust cannot rewind killedAt either", fails)

    -- (d) a first anchor is never blocked by the guard.
    Timers.state = {}
    tcheck(Timers.Record("rend", t, "dbm", "legacy", "pop") == true,
        "the first anchor for a buff always applies", fails)

    Timers.state = {}
end

----------------------------------------------------------------------
-- F2 — kind="killed" means ANNOUNCER DEATH and nothing else.
----------------------------------------------------------------------
local function testAnnouncerOnlyKills(fails)
    tcheck(Timers.ANNOUNCER_BUFFS.onyH and Timers.ANNOUNCER_BUFFS.onyA
        and Timers.ANNOUNCER_BUFFS.nefH and Timers.ANNOUNCER_BUFFS.nefA,
        "the four announcer buffs are the announcer set", fails)
    tcheck(not Timers.ANNOUNCER_BUFFS.rend and not Timers.ANNOUNCER_BUFFS.zg,
        "Rend and Zandalar have no announcer", fails)

    local t = now() - 40000
    Timers.state = {}
    local ok, why = Timers.Record("rend", t, "local", "Rend Blackhand", "killed")
    tcheck(ok == false and tostring(why):find("announcer"),
        "a Rend 'kill' is refused (Rend Blackhand is a raid boss)", fails)
    tcheck((Timers.state.rend == nil) or (Timers.state.rend.killedAt or 0) == 0,
        "no respawn clock is started for Rend", fails)
    tcheck((Timers.state.rend == nil) or (Timers.state.rend.lastPop or 0) == 0,
        "and it is NOT silently reinterpreted as a pop either", fails)
    tcheck(Timers.Record("zg", t, "sn", "Hakkar", "killed") == false,
        "a Zandalar 'kill' is refused (Hakkar is a raid boss)", fails)
    tcheck(Timers.Record("onyH", t, "local", "Overlord Runthak", "killed") == true,
        "an announcer kill still records normally", fails)

    -- DBM: the boss-kill and combat-start opcodes anchor NOTHING any more.
    Timers.state = {}
    Timers._dbmHint = {}
    local onyKey = factionKey("ony")
    Timers.OnDBMMessage("Someone-Realm\t1\tK\t10184\t1")      -- Onyxia killed
    tcheck(next(Timers.state) == nil, "a DBM boss kill anchors nothing (F2)", fails)
    tcheck(Timers._dbmHint[onyKey] and Timers._dbmHint[onyKey].what == "bossKilled",
        "...it survives only as a diagnostic hint", fails)
    Timers.OnDBMMessage("Someone-Realm\t1\tC\t10\t10184")     -- Onyxia pulled
    tcheck(next(Timers.state) == nil, "a DBM combat start anchors nothing (F5)", fails)
    tcheck(Timers._dbmHint[onyKey].what == "bossPulled",
        "...and is recorded as a pull hint, not a pop", fails)
    Timers.OnDBMMessage("Someone-Realm\t1\tK\t10429\t1")      -- Rend Blackhand
    tcheck(Timers.state.rend == nil, "a Rend Blackhand kill plants no Rend state", fails)
    tcheck(Timers.OnDBMMessage("garbage") == nil, "a malformed D5 body is safe", fails)

    -- Persisted legacy debris: a `killed` entry on Rend (written by the OLD DBM
    -- mapping) must not rehydrate into anything at all.
    if ns.Store and ns.Store.GetTimers then
        local logs = ns.Store.GetTimers().logs
        local savedRend = logs.rend
        Timers.state = {}
        logs.rend = { { epoch = now() - 600, who = "DBM", trust = "dbm", killed = true } }
        Timers.RehydrateFromStore()
        tcheck((Timers.state.rend == nil) or ((Timers.state.rend.killedAt or 0) == 0
               and (Timers.state.rend.lastPop or 0) == 0),
            "a legacy Rend 'killed' log entry rehydrates to nothing", fails)
        -- ...while an announcer buff's killed entry still rehydrates.
        Timers.state = {}
        logs.onyH = { { epoch = now() - 60, who = "Runthak", trust = "local", killed = true } }
        Timers.RehydrateFromStore()
        tcheck(Timers.state.onyH and (Timers.state.onyH.killedAt or 0) > 0,
            "an announcer kill entry still rehydrates", fails)
        logs.rend, logs.onyH = savedRend or {}, {}
    end

    Timers.state = {}
end

----------------------------------------------------------------------
-- F12 — two-phase announcer respawn + the display grace that was exported and
-- never used. F6 — the armed npcRespawned alert.
----------------------------------------------------------------------
local function testRespawnTwoPhase(fails)
    tcheck(Timers.ANNOUNCER_RESPAWN == 360 and Timers.ANNOUNCER_RESPAWN_WINDOW == 120,
        "respawn model is 360s certain-dead + a 120s random window", fails)

    local t = 1600000000
    Timers.state = {}
    Timers.Record("onyA", t, "local", "Major Mattingly", "killed")

    local dead = Timers.BuffStatus("onyA", t + 10)
    tcheck(dead.state == "killed" and dead.phase == "dead",
        "inside 360s the announcer is certainly dead", fails)
    tcheck(math.abs(dead.remaining - 350) < 0.5, "remaining counts the certain-dead phase", fails)
    tcheck(dead.windowEndsAt == t + 480, "the random window closes at +480", fails)

    local win = Timers.BuffStatus("onyA", t + 400)
    tcheck(win.state == "canpop", "past 360s the MODEL says the buff can pop", fails)
    tcheck(win.phase == "window", "...but the display phase is the 120s random window", fails)
    tcheck(math.abs(win.windowRemaining - 80) < 0.5, "the window remaining counts to +480", fails)

    local open = Timers.BuffStatus("onyA", t + 500)
    tcheck(open.state == "canpop" and open.phase == "open",
        "past 480s the announcer is certainly back", fails)
    tcheck(open.windowRemaining == 0, "no window remains once open", fails)

    -- DISPLAY_GRACE: exported since forever, applied nowhere. The readout holds
    -- "cd" for +5s past the raw cooldown (SN §10.2: raw 10800 / display 10805).
    Timers.state = {}
    Timers.Record("rend", t, "local", "Thrall", "pop")
    tcheck(Timers.BuffStatus("rend", t + CD.rend - 1).state == "cd",
        "on cooldown just before the raw cooldown ends", fails)
    tcheck(Timers.BuffStatus("rend", t + CD.rend + 1).state == "cd",
        "still 'cd' inside the +5s display grace (F12)", fails)
    tcheck(Timers.BuffStatus("rend", t + CD.rend + DISPLAY_GRACE + 1).state == "canpop",
        "flips to canpop once the display grace elapses", fails)
    -- ...and the false-positive gate still uses the RAW cooldown, as specified.
    tcheck(Timers.IsFalsePositive("rend", t, t + CD.rend - 1, false) == true,
        "the dedup gate rejects inside the RAW cooldown", fails)
    tcheck(Timers.IsFalsePositive("rend", t, t + CD.rend, false) == false,
        "the dedup gate is not extended by the display grace", fails)

    -- F6: an announcer death arms the npcRespawned alert for the end of the
    -- certain-dead phase, cancellable by a later kill.
    Timers.state = {}
    Timers._respawnGen = {}
    local realAfter = C_Timer and C_Timer.After
    local arms = {}
    if C_Timer then C_Timer.After = function(delay, fn) arms[#arms + 1] = { delay = delay, fn = fn } end end
    Timers._lastNotice = nil
    Timers.OnAnnouncerDeath("onyH", "Overlord Runthak", now())
    tcheck(Timers._lastNotice and Timers._lastNotice.category == "npcDied",
        "the death itself alerts npcDied", fails)
    tcheck(#arms >= 1, "an announcer death ARMS a respawn alert (F6)", fails)
    local firstArm = arms[#arms]
    tcheck(firstArm and math.abs(firstArm.delay - ANNOUNCER_RESPAWN) <= 1,
        "armed for the end of the certain-dead phase", fails)
    Timers._lastNotice = nil
    firstArm.fn()
    tcheck(Timers._lastNotice and Timers._lastNotice.category == "npcRespawned",
        "firing the arm emits the npcRespawned alert", fails)
    -- A second kill invalidates the first arm (generation token).
    Timers.OnAnnouncerDeath("onyH", "Overlord Runthak", now() + 5)
    Timers._lastNotice = nil
    firstArm.fn()
    tcheck(Timers._lastNotice == nil, "the stale arm from the first kill is inert", fails)
    arms[#arms].fn()
    tcheck(Timers._lastNotice and Timers._lastNotice.category == "npcRespawned",
        "the newest arm still fires", fails)
    if C_Timer then C_Timer.After = realAfter end

    Timers.state = {}
    Timers._respawnGen = {}
end

----------------------------------------------------------------------
-- F7 — one hand-in rule for every source.
----------------------------------------------------------------------
local function testHandinUnification(fails)
    local t = now() - 40000     -- historical: no pull bars, no recency effects
    Timers.state = {}
    Timers._handinStash = {}

    -- (a) an SN quest entry is a hand-in and gets the assumed-drop lead.
    Timers.OnSNTimer("rend", t, "quest", { who = "Ann" })
    tcheck(Timers.state.rend and Timers.state.rend.lastPop == t + Timers.HANDIN_LEAD,
        "an SN hand-in anchors at the assumed drop (+15s)", fails)
    tcheck(Timers.state.rend.trust == "sn", "...carrying sn trust", fails)

    -- (b) NWB's log and SN's quest entry now agree to the second.
    Timers.state = {}
    Timers.IngestNWBTimers({ F = { { G = "q", H = t, J = "Ann" } } })
    local viaNWB = Timers.state.rend and Timers.state.rend.lastPop
    Timers.state = {}
    Timers.OnSNTimer("rend", t, "quest", { who = "Ann" })
    tcheck(viaNWB and Timers.state.rend.lastPop == viaNWB,
        "the same hand-in from NWB and SN produces the IDENTICAL anchor", fails)

    -- (c) our own pending hand-in wins: the following yell anchors, not a relay.
    Timers.state = {}
    Timers._handinStash = {}
    Timers._stashHandin("rend", "Me", now())
    tcheck(Timers.HandinPending("rend") == true, "our hand-in is pending", fails)
    local ok, why = Timers.RecordHandinReport("rend", t, "sn", "Ann")
    tcheck(ok == false and tostring(why):find("pending"),
        "a remote hand-in is refused while ours is pending", fails)
    tcheck((Timers.state.rend == nil) or (Timers.state.rend.lastPop or 0) == 0,
        "...and anchors nothing", fails)
    tcheck(Timers.HandinPending("rend") == true,
        "the refusal does not consume the stash (only the yell does)", fails)

    -- (d) an EXPIRED stash stops blocking.
    Timers._handinStash.rend.at = now() - (HANDIN_STASH_TTL + 5)
    tcheck(Timers.HandinPending("rend") == false, "an expired stash is not pending", fails)
    tcheck(Timers.RecordHandinReport("rend", t, "sn", "Ann") == true,
        "...so the remote hand-in is accepted again", fails)

    -- (e) mesh relays take the same path.
    Timers.state = {}
    Timers._handinStash = {}
    Timers.OnMeshTimer("onyH", t, "quest", { who = "Peer" })
    tcheck(Timers.state.onyH and Timers.state.onyH.lastPop == t + Timers.HANDIN_LEAD,
        "a mesh hand-in relay gets the same lead", fails)

    -- (f) a hand-in never raises a pull bar, from any source.
    local barred = false
    ns:On("PULL_DETECTED", function() barred = true end)
    Timers.state = {}
    Timers._handinStash = {}
    Timers.OnSNTimer("rend", now(), "quest", { who = "Fresh" })
    tcheck(barred == false, "a fresh remote hand-in raises no pull bar", fails)

    -- (g) the local rule is untouched: a Rend hand-in still only stashes.
    Timers.state = {}
    Timers._handinStash = {}
    Timers.OnQuestHandin(4974, now())
    tcheck(Timers._handinStash.rend ~= nil, "a LOCAL Rend hand-in still stashes", fails)
    tcheck((Timers.state.rend == nil) or (Timers.state.rend.lastPop or 0) == 0,
        "...and still anchors nothing by itself (A4.1)", fails)

    Timers.state = {}
    Timers._handinStash = {}
end

----------------------------------------------------------------------
-- F6 — the BUFF_GAIN seam finally has a producer, and a local gain backfills
-- the pop log (spec §11) without double-logging a drop we already recorded.
----------------------------------------------------------------------
local function testLocalBuffGain(fails)
    if not (ns.Store and ns.Store.GetTimers and ns.Store.AddTimerLog) then
        fails[#fails + 1] = "store absent for buff-gain test"; return
    end
    local logs = ns.Store.GetTimers().logs
    logs.rend = {}
    local gains = {}
    ns:On("BUFF_GAIN", function(buffKey, message) gains[#gains + 1] = { buff = buffKey, message = message } end)
    local t = now()

    -- (a) a gain nothing else covers fires the alert AND backfills the log.
    local wrote = Timers.NoteLocalBuffGain("rend", t)
    tcheck(#gains == 1 and gains[1].buff == "rend", "a local gain fires BUFF_GAIN", fails)
    tcheck(type(gains[1].message) == "string" and #gains[1].message > 0,
        "the event carries a message for the alert dispatcher", fails)
    tcheck(wrote == true, "...and backfills the pop log", fails)
    tcheck(#logs.rend == 1 and logs.rend[1].gain == true, "the entry is marked as a gain", fails)

    -- (b) a second gain for the same drop does not double-log.
    gains = {}
    tcheck(Timers.NoteLocalBuffGain("rend", t + 5) == false,
        "a gain inside the dedup window writes no second entry", fails)
    tcheck(#logs.rend == 1, "the log still holds one entry for that drop", fails)
    tcheck(#gains == 1, "the alert still fires (alert dedup is the HUD's job)", fails)

    -- (c) an entry from ANY other source covering the moment also suppresses it —
    -- this is the "deduplicated against the mesh/third-party sources" rule.
    logs.rend = {}
    ns.Store.AddTimerLog("rend", { epoch = t, who = "Thrall", trust = "local" })
    tcheck(Timers.NoteLocalBuffGain("rend", t + 10) == false,
        "a yell-sourced entry already covers this drop", fails)
    tcheck(#logs.rend == 1, "so no duplicate is written", fails)

    -- (d) buffs with no store log never write one.
    logs.rend = {}
    tcheck(Timers.NoteLocalBuffGain("zg", t) == false, "ZG keeps no pop log", fails)
    tcheck(Timers.NoteLocalBuffGain("nefH", t) == false, "Nefarian keeps no pop log", fails)

    -- (e) a gain never anchors: the aura proves the buff exists, not when it
    -- dropped (chronoboon restores land the same aura).
    Timers.state = {}
    logs.rend = {}
    Timers.NoteLocalBuffGain("rend", t)
    tcheck((Timers.state.rend == nil) or (Timers.state.rend.lastPop or 0) == 0,
        "a gain writes no cooldown anchor", fails)

    -- (f) the real aura handler feeds it: a pending pull + a landed world buff.
    local savedAuras, savedTracker, savedPending = _G.C_UnitAuras, ns.Tracker, Timers._pendingPull
    ns.Tracker = nil
    _G.C_UnitAuras = { GetBuffDataByIndex = function(_, i)
        if i == 1 then return { name = "Warchief's Blessing" } end
        return nil
    end }
    logs.rend = {}
    gains = {}
    Timers._pendingPull = {}
    Timers._setPendingPull("rend", now() - 10, 1)
    Timers._onPlayerAura("UNIT_AURA", "player")
    tcheck(#gains == 1 and gains[1].buff == "rend",
        "a landed world buff fires BUFF_GAIN from the aura path", fails)
    tcheck(Timers._pendingPull.rend == nil, "...and still credits the pull observation", fails)
    -- With nothing pending the aura is not attributable and must stay silent.
    gains = {}
    Timers._pendingPull = {}
    Timers._onPlayerAura("UNIT_AURA", "player")
    tcheck(#gains == 0, "an aura with no pending pull fires nothing", fails)

    _G.C_UnitAuras, ns.Tracker, Timers._pendingPull = savedAuras, savedTracker, savedPending or {}
    logs.rend = {}
    Timers.state = {}
end

----------------------------------------------------------------------
-- F13 — Timers.ResetState(), the engine-owned wipe an options Reset calls.
----------------------------------------------------------------------
local function testResetState(fails)
    local timers = ns.Store and ns.Store.GetTimers and ns.Store.GetTimers()
    Timers.state = {}
    Timers.Record("rend", now() - 100, "local", "Thrall", "pop")
    Timers._warnGen.rend      = 7
    Timers._respawnGen.onyH   = 3
    Timers._dbmHint.zg        = { at = 1, what = "bossPulled" }
    Timers._stashHandin("rend", "Me", now())
    Timers._nodeTrust["flower1"] = "sn"
    Timers.RecordPullObservation("rend", 1, 12)
    Timers.MarkNode("flower", 1, now() - 60, "local")

    local fired = {}
    ns:On("TIMER_UPDATED", function(buffKey) fired[buffKey] = true end)
    tcheck(Timers.ResetState() == true, "ResetState returns true", fails)
    tcheck(next(Timers.state) == nil, "per-buff anchors wiped", fails)
    tcheck(next(Timers._warnGen) == nil, "warning generations wiped (armed warnings cancelled)", fails)
    tcheck(next(Timers._respawnGen) == nil, "respawn arms cancelled", fails)
    tcheck(next(Timers._handinStash) == nil, "hand-in stash wiped", fails)
    tcheck(next(Timers._dbmHint) == nil, "dbm hints wiped", fails)
    tcheck(Timers._nodeTrust["flower1"] == nil, "node trust wiped", fails)
    if timers then
        tcheck(timers.pullObservations == nil, "drift observations wiped", fails)
        -- Node POP epochs are Felwood observations on their own 25-minute clock
        -- and are deliberately NOT part of a timer-state reset.
        tcheck((nodePopTable("flower") or {})[1] ~= nil, "node pop epochs survive the reset", fails)
    end
    for i = 1, #Timers.BUFF_KEYS do
        tcheck(fired[Timers.BUFF_KEYS[i]] == true,
            "TIMER_UPDATED fired for " .. Timers.BUFF_KEYS[i], fails)
    end
    tcheck(Timers.BuffStatus("rend", now()).state == "nodata",
        "the readout reads nodata after a reset", fails)

    if timers then timers.flower = {} end
    Timers.state = {}
end

----------------------------------------------------------------------
-- F-KILL — LOCAL ANNOUNCER-DEATH DETECTION, driven end to end.
--
-- These run through the REAL combat-log handler with a stubbed
-- CombatLogGetCurrentEventInfo and GetRealZoneText, so the gates themselves are
-- under test rather than just OnAnnouncerDeath. Every case is a mutation target:
-- keying off the witness's faction, dropping the per-announcer zone pairing,
-- consulting the CLEU reaction flags, or accepting any creature id all turn one
-- of these red.
----------------------------------------------------------------------

-- A Classic-Era creature GUID carrying `npcID` in the id field.
local function fakeCreatureGUID(npcID)
    return "Creature-0-4379-1-197-" .. tostring(npcID) .. "-00003F4CFB"
end

-- Fire ONE synthetic combat-log event through the live handler.
--   zone      what GetRealZoneText answers
--   faction   what UnitFactionGroup answers — the WITNESS's faction
--   destFlags the CLEU flag word (a charmed announcer reads friendly; see (c))
local function fireDeath(npcID, destName, zone, faction, destFlags, subevent)
    local savedCLEU = _G.CombatLogGetCurrentEventInfo
    local savedZone = _G.GetRealZoneText
    local savedFac  = _G.UnitFactionGroup
    _G.GetRealZoneText  = function() return zone end
    _G.UnitFactionGroup = function() return faction or "Horde" end
    _G.CombatLogGetCurrentEventInfo = function()
        return now(), subevent or "UNIT_DIED", false,
               "Player-4379-0000AAAA", "Someone", 0, 0,
               npcID and fakeCreatureGUID(npcID) or nil, destName,
               destFlags or 0, 0, nil
    end
    Timers._onCombatLog()
    _G.CombatLogGetCurrentEventInfo = savedCLEU
    _G.GetRealZoneText  = savedZone
    _G.UnitFactionGroup = savedFac
end

local function testLocalAnnouncerDetection(fails)
    local RUNTHAK, MATTINGLY, SAURFANG = 14392, 14394, 14720

    -- (a) THE CASE THE OWNER REPORTED: a Runthak death in Orgrimmar stamps
    -- killedAt on onyH through the normal trust machinery, and starts no cooldown.
    Timers.state = {}
    fireDeath(RUNTHAK, "Overlord Runthak", "Orgrimmar", "Horde")
    local s = Timers.state.onyH
    tcheck(s and (s.killedAt or 0) > 0,
        "a Runthak UNIT_DIED in Orgrimmar stamps killedAt on onyH", fails)
    tcheck(s and s.trust == "local", "...at local trust", fails)
    tcheck((s and s.lastPop or 0) == 0, "...and starts no cooldown (A3.1)", fails)

    -- (b) THE KEY IS THE ANNOUNCER'S FACTION, NEVER THE WITNESS'S. Both
    -- directions are real: an Alliance raid pushing in to deny the buff, and — as
    -- happened on 2026-08-03 — a HORDE raid killing its own announcer after an
    -- Alliance priest mind-controlled him.
    for _, witness in ipairs({ "Alliance", "Horde" }) do
        Timers.state = {}
        fireDeath(RUNTHAK, "Overlord Runthak", "Orgrimmar", witness)
        tcheck(Timers.state.onyH and (Timers.state.onyH.killedAt or 0) > 0,
            "a " .. witness .. " witness writes the HORDE announcer's key", fails)
        tcheck(Timers.state.onyA == nil,
            "...and never the " .. witness .. " witness's own faction key", fails)
    end

    -- (c) CHARM-AGNOSTIC. Under mind control the announcer's CLEU flags read
    -- REACTION_FRIENDLY (0x10) + CONTROL_PLAYER (0x100) + AFFILIATION_RAID (0x4).
    -- He is still the announcer and his death is still the respawn event, so the
    -- flag word is read off the payload and deliberately never consulted.
    Timers.state = {}
    fireDeath(RUNTHAK, "Overlord Runthak", "Orgrimmar", "Horde", 0x114)
    tcheck(Timers.state.onyH and (Timers.state.onyH.killedAt or 0) > 0,
        "a MIND-CONTROLLED announcer's death still records (2026-08-03)", fails)

    -- (d) WRONG ZONE is ignored...
    Timers.state = {}
    fireDeath(RUNTHAK, "Overlord Runthak", "Ironforge", "Horde")
    tcheck(Timers.state.onyH == nil, "a Runthak death in Ironforge is ignored", fails)
    Timers.state = {}
    fireDeath(RUNTHAK, "Overlord Runthak", "Felwood", "Horde")
    tcheck(Timers.state.onyH == nil, "...and one in Felwood", fails)

    -- ...and the gate is PER ANNOUNCER, not one flat capital list.
    Timers.state = {}
    fireDeath(MATTINGLY, "Major Mattingly", "Orgrimmar", "Horde")
    tcheck(Timers.state.onyA == nil,
        "Mattingly dying in ORGRIMMAR is not an Alliance announcer kill", fails)
    Timers.state = {}
    fireDeath(MATTINGLY, "Major Mattingly", "Stormwind City", "Horde")
    tcheck(Timers.state.onyA and (Timers.state.onyA.killedAt or 0) > 0,
        "...but Mattingly in Stormwind City is", fails)

    -- The surrounding zone counts (NWB §2.9 accepts 1411 / 1429): GetRealZoneText
    -- reads the PARENT zone at the city edge, where a raid fighting in is stood.
    Timers.state = {}
    fireDeath(SAURFANG, "High Overlord Saurfang", "Durotar", "Horde")
    tcheck(Timers.state.nefH and (Timers.state.nefH.killedAt or 0) > 0,
        "Durotar is a legal witness zone for a Horde announcer", fails)

    -- (e) WRONG CREATURE, right city, real death: nothing at all.
    Timers.state = {}
    fireDeath(12345, "Some Orgrimmar Grunt", "Orgrimmar", "Horde")
    tcheck(next(Timers.state) == nil,
        "a non-announcer death in Orgrimmar records nothing", fails)

    -- (f) NAME FALLBACK — Stonebridge carries no id in the table at all, which is
    -- the whole reason the fallback exists.
    Timers.state = {}
    fireDeath(99999, "Field Marshal Stonebridge", "Stormwind City", "Alliance")
    tcheck(Timers.state.nefA and (Timers.state.nefA.killedAt or 0) > 0,
        "Stonebridge resolves through the NAME fallback", fails)

    -- (g) a non-death subevent on the announcer records nothing.
    Timers.state = {}
    fireDeath(RUNTHAK, "Overlord Runthak", "Orgrimmar", "Horde", 0, "SPELL_DAMAGE")
    tcheck(Timers.state.onyH == nil, "SPELL_DAMAGE on the announcer records nothing", fails)

    -- The pure zone predicate, stated directly.
    tcheck(Timers.AnnouncerZoneOK("onyH", "Orgrimmar") == true, "onyH ok in Orgrimmar", fails)
    tcheck(Timers.AnnouncerZoneOK("onyH", "Stormwind City") == false,
        "onyH is NOT ok in Stormwind", fails)
    tcheck(Timers.AnnouncerZoneOK("onyA", "Elwynn Forest") == true, "onyA ok in Elwynn", fails)
    tcheck(Timers.AnnouncerZoneOK("nefH", "Durotar") == true, "nefH ok in Durotar", fails)
    tcheck(Timers.AnnouncerZoneOK(nil, "Orgrimmar") == false, "no buff key -> not ok", fails)

    Timers.state = {}
    if ns.Store and ns.Store.GetTimers then
        local logs = ns.Store.GetTimers().logs
        logs.onyH, logs.onyA = {}, {}
    end
end

----------------------------------------------------------------------
-- F-KILL — a kill must survive a longer cooldown, and a drop must retire it.
----------------------------------------------------------------------
local function testKillVisibility(fails)
    local t = 1600000000

    -- THE 2026-08-03 REGRESSION, reproduced to the minute. The announcer dies
    -- ~19 minutes before the Onyxia cooldown expires. F3 correctly keeps `state`
    -- at "cd" (the buff really is 19 minutes away) — but the kill has to remain
    -- READABLE, or every consumer shows a plain countdown and the kill looks to
    -- the owner like it was never detected.
    Timers.state = {}
    Timers.Record("onyH", t, "local", "yeller", "pop")
    local killAt = t + CD.onyH - 1175
    Timers.Record("onyH", killAt, "local", "Overlord Runthak", "killed")
    local st = Timers.BuffStatus("onyH", killAt + 2)
    tcheck(st.state == "cd", "the longer cooldown still owns `state` (F3 intact)", fails)
    tcheck(st.killActive == true, "...and the kill is STILL VISIBLE alongside it", fails)
    tcheck(st.killedAt == killAt, "killedAt rides the readout", fails)
    tcheck(math.abs((st.killRemaining or 0) - 358) < 2,
        "killRemaining counts the certain-dead phase", fails)
    tcheck((st.cdEndsAt or 0) > killAt, "the displaced cooldown end rides along too", fails)

    -- The takeover is BOUNDED: once the 480s window shuts the kill stops claiming
    -- the row, even though the cooldown is still running.
    local later = Timers.BuffStatus("onyH", killAt + 481)
    tcheck(later.state == "cd", "still on cooldown past the respawn window", fails)
    tcheck(not later.killActive, "...but the kill no longer claims the row", fails)

    -- A bare kill with no cooldown behind it is unchanged.
    Timers.state = {}
    Timers.Record("onyH", t, "local", "Overlord Runthak", "killed")
    tcheck(Timers.BuffStatus("onyH", t + 60).killActive == true, "a bare kill is active", fails)

    -- A NEWER DROP RETIRES THE KILL (NWB §3.3). The announcer is the NPC who
    -- yells, so a drop is proof he is back on his feet.
    Timers.state = {}
    Timers.Record("onyH", t, "local", "Overlord Runthak", "killed")
    tcheck(Timers.state.onyH.killedAt == t, "kill stamped", fails)
    Timers.Record("onyH", t + 400, "local", "yeller", "pop")
    tcheck((Timers.state.onyH.killedAt or 0) == 0,
        "a drop after the kill clears the kill stamp", fails)
    tcheck(not Timers.BuffStatus("onyH", t + 401).killActive,
        "...so nothing goes on claiming the announcer is down", fails)

    -- ...but a drop OLDER than the kill leaves it standing.
    Timers.state = {}
    Timers.Record("onyH", t + 400, "local", "Overlord Runthak", "killed")
    Timers.Record("onyH", t, "local", "yeller", "pop")
    tcheck(Timers.state.onyH.killedAt == t + 400,
        "an older drop does not retire a newer kill", fails)

    Timers.state = {}
end

----------------------------------------------------------------------
-- F-KILL — NWB-compat announcer-death ingestion (`x` / `D`), NWB §3.4.
----------------------------------------------------------------------
local function testNWBKillIngest(fails)
    local t = now()
    local onyKey = factionKey("ony")

    tcheck(Timers._nwbKillFields[1].field == "x" and Timers._nwbKillFields[2].field == "D",
        "the wire keys are x (Onyxia) and D (Nefarian)", fails)

    -- HEARD AND INGESTED. Until now `x` was decoded and dropped on the floor.
    Timers.state = {}
    local a = Timers.IngestNWBTimers({ x = t - 30 })
    tcheck((a.killHeard or 0) == 1, "an inbound `x` is HEARD", fails)
    tcheck((a.kill or 0) == 1, "...and ingested", fails)
    tcheck(Timers.state[onyKey] and Timers.state[onyKey].killedAt == t - 30,
        "the announcer death lands on the faction-resolved Onyxia key", fails)
    tcheck(Timers.state[onyKey] and Timers.state[onyKey].trust == "nwb",
        "...at nwb trust", fails)

    -- RULE 1: 0..1800s only.
    Timers.state = {}
    a = Timers.IngestNWBTimers({ x = t - 2000 })
    tcheck((a.killHeard or 0) == 1 and (a.kill or 0) == 0,
        "a kill older than 1800s is heard but not ingested", fails)
    tcheck((a.killRejected or 0) == 1, "...and counted as rejected", fails)
    tcheck(Timers.state[onyKey] == nil, "nothing is recorded for it", fails)

    -- RULE 2: within 60s of a kill we already hold = the same event, relayed.
    Timers.state = {}
    Timers.Record(onyKey, t - 100, "local", "Overlord Runthak", "killed")
    a = Timers.IngestNWBTimers({ x = t - 80 })
    tcheck((a.kill or 0) == 0, "a relay within 60s of our own kill is a duplicate", fails)
    tcheck(Timers.state[onyKey].killedAt == t - 100, "...and our own stamp stands", fails)

    -- RULE 3: suppressed if the buff dropped inside the last 600s — something
    -- that drops the buff cannot simultaneously be lying dead.
    Timers.state = {}
    Timers.Record(onyKey, t - 120, "local", "yeller", "pop")
    a = Timers.IngestNWBTimers({ x = t - 60 })
    tcheck((a.kill or 0) == 0, "a kill is suppressed by a drop within 600s", fails)

    -- The pure predicate, stated directly.
    Timers.state = {}
    tcheck(Timers.NWBKillAcceptable(onyKey, t - 30, t) == true, "a fresh relay is acceptable", fails)
    tcheck(Timers.NWBKillAcceptable(onyKey, t + 60, t) == false, "a future kill is not", fails)
    tcheck(Timers.NWBKillAcceptable("rend", t - 30, t) == false,
        "Rend has no announcer, so it can never take a relayed kill (F2)", fails)

    Timers.state = {}
end

----------------------------------------------------------------------
-- F-KILL — rehydration must seed the newest POP and the newest KILL separately.
----------------------------------------------------------------------
local function testRehydrateKillAndPop(fails)
    if not (ns.Store and ns.Store.GetTimers) then
        fails[#fails + 1] = "store absent for rehydrate kill/pop test"; return
    end
    local logs = ns.Store.GetTimers().logs
    local t = now()

    -- THE EXACT SHAPE THE OWNER'S LOG WAS LEFT IN on 2026-08-03: a fresh `killed`
    -- entry at the head, with the live six-hour Onyxia pop right behind it. The
    -- old newest-entry-only rehydrate read [1], never looked at [2], and the real
    -- cooldown — hours still to run — silently became "Open" on the next login.
    Timers.state = {}
    logs.onyH = {
        { epoch = t - 60,    who = "Overlord Runthak", trust = "local", killed = true },
        { epoch = t - 20425, who = "NWB",              trust = "nwb" },
    }
    Timers.RehydrateFromStore()
    local s = Timers.state.onyH
    tcheck(s and s.killedAt == t - 60, "the newest KILL rehydrates", fails)
    tcheck(s and s.lastPop == t - 20425,
        "...and the older POP behind it rehydrates TOO (it did not before)", fails)
    local st = Timers.BuffStatus("onyH", t)
    tcheck(st.state == "cd", "so the live cooldown survives the relog", fails)
    tcheck(st.killActive == true, "...and so does the kill", fails)

    -- Reversed order in the log must give the identical answer — the walk is by
    -- epoch, not by position.
    Timers.state = {}
    logs.onyH = {
        { epoch = t - 20425, who = "NWB",              trust = "nwb" },
        { epoch = t - 60,    who = "Overlord Runthak", trust = "local", killed = true },
    }
    Timers.RehydrateFromStore()
    tcheck(Timers.state.onyH.killedAt == t - 60 and Timers.state.onyH.lastPop == t - 20425,
        "log order does not change what is seeded", fails)

    -- A kill the newest pop already superseded stays retired (NWB §3.3), exactly
    -- as it would on the live Record path.
    Timers.state = {}
    logs.onyH = {
        { epoch = t - 100, who = "yeller",           trust = "local" },
        { epoch = t - 900, who = "Overlord Runthak", trust = "local", killed = true },
    }
    Timers.RehydrateFromStore()
    tcheck((Timers.state.onyH.killedAt or 0) == 0,
        "a kill older than the newest drop does not rehydrate", fails)

    logs.onyH, Timers.state = {}, {}
end

function Timers.RunSelfTests(verbose)
    local suites = {
        { name = "cd derivation",     fn = testCDDerivation },
        { name = "false-positive gate", fn = testFalsePositive },
        { name = "yell table (A2)",   fn = testYellTable },
        { name = "announcer resolution: longest match wins (NX-13)", fn = testNpcKeyOrder },
        { name = "announcer kill respawn (A3)", fn = testAnnouncerKill },
        { name = "quest hand-in (A4)", fn = testQuestHandin },
        { name = "songflower pick gate (A5)", fn = testSongflowerPick },
        { name = "tuber loot detection", fn = testTuberLoot },
        { name = "other-player songflower", fn = testOtherSongflower },
        { name = "pull recency gate", fn = testPullRecencyGate },
        { name = "pull windows + drift", fn = testPullWindows },
        { name = "unboon gate",       fn = testUnboonGate },
        { name = "trust upgrade",     fn = testTrustUpgrade },
        { name = "trust ordering",    fn = testTrustOrdering },
        { name = "request cooldowns", fn = testRequestCooldowns },
        { name = "nwb request build", fn = testNWBRequestBuild },
        { name = "log dedup",         fn = testLogDedup },
        { name = "node state machine", fn = testNodeStateMachine },
        -- ROUND-17 songflower accuracy audit.
        { name = "respawn vs setting split", fn = testRespawnSettingSplit },
        { name = "node overwrite guards",    fn = testNodeGuardMatrix },
        { name = "own-pick aura fallback",   fn = testOwnPickAuraFallback },
        { name = "dragon nodes",             fn = testDragonNodes },
        { name = "ingest parsers",    fn = testIngestParsers },
        { name = "rehydrate from store", fn = testRehydrateFromStore },
        { name = "nwb payload ingest", fn = testNWBIngest },
        { name = "nwb layered songflowers", fn = testNWBLayerFlowers },
        -- Buff-drop pipeline audit (F1/F2/F6/F7/F12/F13).
        { name = "anchor rewind by trust",   fn = testAnchorRewind },
        { name = "announcer-only kills",     fn = testAnnouncerOnlyKills },
        { name = "two-phase respawn + grace", fn = testRespawnTwoPhase },
        { name = "hand-in unification",      fn = testHandinUnification },
        { name = "local buff gain",          fn = testLocalBuffGain },
        { name = "reset state",              fn = testResetState },
        -- F-KILL: the announcer-kill detection + visibility audit (2026-08-03).
        { name = "local announcer detection", fn = testLocalAnnouncerDetection },
        { name = "kill visibility vs cooldown", fn = testKillVisibility },
        { name = "nwb announcer-death ingest", fn = testNWBKillIngest },
        { name = "rehydrate kill AND pop",   fn = testRehydrateKillAndPop },
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
    -- Whipper Root Tubers are LOOTED, not cast: the loot chat line is the trigger.
    ns:RegisterEvent("CHAT_MSG_LOOT", onChatLoot)
    -- Felwood presence feeds the other-player songflower heuristic. Combat log is
    -- registered above; these two are the reference's other presence sources.
    ns:RegisterEvent("PLAYER_TARGET_CHANGED", onFelwoodUnitSighting)
    ns:RegisterEvent("UPDATE_MOUSEOVER_UNIT", onFelwoodUnitSighting)
    -- Loading screen wipes all presence lists; a zone change wipes last-seen 5s later.
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", onFelwoodLoadingScreen)
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", onFelwoodZoneChanged)
    -- Subzone moves do not wipe presence, but they must still invalidate the
    -- cached "am I in Felwood" answer that gates the combat-log hot path.
    ns:RegisterEvent("ZONE_CHANGED", function() Timers.InvalidateFelwoodCache() end)
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
    -- ROUND-17 audit fix 4: actually ask NWB for data at login. RequestNWBData
    -- was a published, fully-built surface that NOTHING in the lifecycle ever
    -- called — only a UI button — so on a fresh login we waited for someone
    -- else's broadcast instead of asking. Deferred ~3s so AceComm, the guild
    -- roster and NWB's own receiver are all up first; a request fired before the
    -- roster is populated goes nowhere because IsInGuild() is still false.
    if C_Timer and C_Timer.After then
        C_Timer.After(3, function() ns:SafeCall(Timers.RequestNWBData) end)
    end
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
