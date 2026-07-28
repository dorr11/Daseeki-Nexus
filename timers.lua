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

-- Which buff keys own a persisted store log, and the store log key.
local STORE_LOG_KEY = { rend = "rend", onyH = "onyH", onyA = "onyA" }

-- Buffs that feed the CD-warning scheduler (spec: Rend + Ony only).
local WARNED_BUFFS = { "rend", "onyH", "onyA" }

-- Trust ladder. Higher wins; equal-or-higher upgrades an existing entry.
local TRUST_RANK = { ["local"] = 4, mesh = 3, nwb = 2, dbm = 1 }
Timers.TRUST_RANK = TRUST_RANK

local function trustRank(t) return TRUST_RANK[t or ""] or 0 end

----------------------------------------------------------------------
-- Per-buff runtime state
--
-- state[buffKey] = {
--   lastPop    = epoch of the last confirmed buff drop (CD anchor),
--   lastKilled = epoch of the last kill/announce (also anchors CD),
--   trust      = trust tag of the anchoring event,
--   who        = reporter label,
--   confirmed  = true once a higher-or-equal-trust source agreed,
-- }
----------------------------------------------------------------------

Timers.state = {}

local function stateOf(buffKey)
    local s = Timers.state[buffKey]
    if not s then
        s = { lastPop = 0, lastKilled = 0, trust = nil, who = nil, confirmed = false }
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
-- The CD anchor is the later of lastPop / lastKilled. A "killed" entry
-- resets the CD because the head is freshly available for turn-in.
----------------------------------------------------------------------

-- Return the effective anchor epoch for a buff's cooldown.
local function anchorEpoch(s)
    return math.max(s.lastPop or 0, s.lastKilled or 0)
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

function Timers.Record(buffKey, epoch, trust, who, kind, zone, pullDuration)
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

    -- Apply the anchor.
    if isKill then
        s.lastKilled = epoch
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

    -- Fan out to the UI wave.
    ns:Fire("TIMER_UPDATED", buffKey)
    if isKill or kind == "pop" then
        ns:Fire("PULL_DETECTED", buffKey, pullDuration or 0, trust, zone)
    end

    -- (Re)seed warnings for the CD-scheduled buffs.
    if scheduleWarnings then scheduleWarnings(buffKey) end

    -- If we are the elected guild broadcaster, relay the merged change.
    if maybeBroadcast then maybeBroadcast() end

    return true, "applied"
end

----------------------------------------------------------------------
-- Detector 1 — local yell / say scanning
--
-- MONSTER_YELL / MONSTER_SAY carry (text, monsterName, ...). The monster
-- NAME reliably identifies the buff; the TEXT fragment distinguishes the
-- yell number (1 = kill/announce, 2 = come-get-buffed). Alliance cannot
-- read Horde yell text, so Rend is keyed on NPC name alone.
----------------------------------------------------------------------

-- NPC name (lowercased) -> { base buff, split=true if H/A }.
local YELL_NPC = {
    ["thrall"]                 = { buff = "rend" },
    ["herald of thrall"]       = { buff = "rend" },
    ["overlord runthak"]       = { buff = "onyH" },
    ["major mattingly"]        = { buff = "onyA" },
    ["high overlord saurfang"] = { buff = "nefH" },
    ["field marshal afrasiabi"]= { buff = "nefA" },
    ["molthor"]                = { buff = "zg" },
    ["zandalarian emissary"]   = { buff = "zg" },
}

-- Text fragments (lowercased) that mark yell number 1 (kill/announce).
local YELL1_FRAGMENTS = {
    "slain", "has been slain", "brought", "victory", "fallen", "killed",
    "dead", "defeated",
}
-- Text fragments that mark yell number 2 (buff being applied / come get it).
local YELL2_FRAGMENTS = {
    "rallying cry", "dragonslayer", "warchief", "blessing", "zandalar",
    "spirit", "emissary", "reward",
}

local function classifyYell(text)
    text = (text or ""):lower()
    for i = 1, #YELL2_FRAGMENTS do
        if text:find(YELL2_FRAGMENTS[i], 1, true) then return 2 end
    end
    for i = 1, #YELL1_FRAGMENTS do
        if text:find(YELL1_FRAGMENTS[i], 1, true) then return 1 end
    end
    return nil   -- unknown; caller applies a default
end
Timers._classifyYell = classifyYell

-- Resolve an inbound yell to (buffKey, yellNum). Returns nil if unmatched.
function Timers.MatchYell(text, monsterName)
    local key = (monsterName or ""):lower()
    local def = YELL_NPC[key]
    if not def then
        -- Loose contains-match so realm-localized prefixes still resolve.
        for npc, d in pairs(YELL_NPC) do
            if key:find(npc, 1, true) then def = d break end
        end
    end
    if not def then return nil end
    local yellNum = classifyYell(text)
    if not yellNum then
        -- No readable text (e.g. Alliance reading a Horde yell): assume the
        -- announcer's "buff available" yell (2), the actionable case.
        yellNum = 2
    end
    return def.buff, yellNum
end

local function onMonsterYell(event, text, monsterName)
    local buffKey, yellNum = Timers.MatchYell(text, monsterName)
    if not buffKey then return end
    local zone = GetRealZoneText and GetRealZoneText() or nil
    if yellNum == 1 then
        Timers.Record(buffKey, now(), "local", monsterName, "killed", zone)
    else
        Timers.Record(buffKey, now(), "local", monsterName, "pop", zone)
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

-- Capital zones where announcer events are valid.
local CAPITAL_ZONES = {
    ["orgrimmar"]    = true,
    ["stormwind city"]= true,
    ["thunder bluff"]= true,
    ["ironforge"]    = true,
    ["undercity"]    = true,
    ["darnassus"]    = true,
}

-- Announcer NPC-id table -> buffKey. IDs are best-known Classic values and
-- are matched alongside the destName so a mislabelled id never blocks a
-- valid name hit. (Verify numeric ids against live CLEU before relying on
-- id-only matching.)
local ANNOUNCER_ID = {
    [14392] = "onyH",   -- Overlord Runthak (Orgrimmar)   [verify]
    [16803] = "onyA",   -- Major Mattingly (Stormwind)     [verify]
}
Timers._announcerID = ANNOUNCER_ID

-- Same-name fallback keyed on the yell NPC table (announcer names reused).
local function announcerBuffFor(npcID, destName)
    if npcID and ANNOUNCER_ID[npcID] then return ANNOUNCER_ID[npcID] end
    if destName then
        local key = destName:lower()
        local def = YELL_NPC[key]
        if def then return def.buff end
    end
    return nil
end

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
    -- Announcer death => the buff cycle just fired; treat as a kill/announce.
    Timers.Record(buffKey, now(), "local", destName, "killed", GetRealZoneText and GetRealZoneText() or nil)
end

----------------------------------------------------------------------
-- Detector 3 — QUEST_TURNED_IN hand-in ids
----------------------------------------------------------------------

-- questID -> buffKey (H/A resolved for ony/nef where the id is faction-fixed).
local HANDIN_QUEST = {
    [4974] = "rend",
    [7491] = "onyH",  [7496] = "onyA",
    [7782] = "nefH",  [7784] = "nefA",
    [8183] = "zg",
}
Timers._handinQuest = HANDIN_QUEST

local function onQuestTurnedIn(event, questID)
    local buffKey = HANDIN_QUEST[questID]
    if not buffKey then return end
    Timers.Record(buffKey, now(), "local", "handin", "quest",
                  GetRealZoneText and GetRealZoneText() or nil)
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

Timers._nwb = { serializer = nil, deflate = nil, comm = nil, ready = false }

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

-- Ingest a decoded NWB timer payload table (short keys). Faction-resolves
-- ony/nef into our key space; ingests flower/tuber pops.
function Timers.IngestNWBTimers(payload)
    if type(payload) ~= "table" then return end
    local r = nwbEpoch(payload.n); if r then Timers.Record("rend", r, "nwb", "NWB", "pop") end
    local o = nwbEpoch(payload.s); if o then Timers.Record(factionKey("ony"), o, "nwb", "NWB", "pop") end
    local nf = nwbEpoch(payload.y); if nf then Timers.Record(factionKey("nef"), nf, "nwb", "NWB", "pop") end
    -- Songflowers f1..f10, tubers t1..t6 (epoch of last pick).
    for i = 1, 10 do
        local e = nwbEpoch(payload["f" .. i])
        if e then Timers.MarkNode("flower", i, e, "nwb") end
    end
    for i = 1, 6 do
        local e = nwbEpoch(payload["t" .. i])
        if e then Timers.MarkNode("tuber", i, e, "nwb") end
    end
end

-- Handle one fully-reassembled NWB message (called by AceComm).
function Timers.OnNWBMessage(prefix, message, channel, sender)
    local nwb = Timers._nwb
    if not nwb.ready or not nwb.serializer or not nwb.deflate then return end
    -- World-buff timer data rides GUILD (also YELL/SAY world broadcast).
    local decoded
    if channel == "YELL" or channel == "SAY" then
        decoded = nwb.deflate.DecodeForWoWChatChannel and nwb.deflate:DecodeForWoWChatChannel(message)
    else
        decoded = nwb.deflate.DecodeForWoWAddonChannel and nwb.deflate:DecodeForWoWAddonChannel(message)
    end
    if not decoded then return end
    local decompressed = nwb.deflate:DecompressDeflate(decoded)
    if not decompressed then return end
    local ok, top = nwb.serializer:Deserialize(decompressed)
    if not ok or type(top) ~= "string" then return end

    local args = explodeSpace(top, 5)
    local cmd = args[1]
    local remoteVersion = tonumber(args[2]) or 0
    if remoteVersion < NWB_MIN_VERSION then return end   -- version gate
    local dataStr = args[5]

    if cmd == "data" or cmd == "settings" or cmd == "requestData" then
        if type(dataStr) == "string" and #dataStr > 0 then
            local ok2, payload = nwb.serializer:Deserialize(dataStr)
            if ok2 and type(payload) == "table" then
                Timers.IngestNWBTimers(payload)
            end
        end
        Timers._sawNWB = true
    elseif cmd == "yell" or cmd == "yell2" then
        local t = dataStr and dataStr:match("^(%S+)")
        local buffKey = t and nwbTypeToBuff(t)
        if buffKey then Timers.Record(buffKey, now(), "nwb", "NWB", "pop") end
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
    if type(LibStub) ~= "function" then return end   -- libs absent -> no ingest
    local serializer = LibStub("AceSerializer-3.0", true)
    local deflate    = LibStub("LibDeflate", true)
    local comm       = LibStub("AceComm-3.0", true)
    if not (serializer and deflate and comm) then return end
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

-- Pick detection from a successful player cast in Felwood.
local function onSpellSucceeded(event, unit)
    if unit ~= "player" then return end
    if not (C_Map and C_Map.GetBestMapForUnit) then return end
    local mapID = C_Map.GetBestMapForUnit("player")
    if mapID ~= Timers.FELWOOD_MAP then return end
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if not pos then return end
    local x, y = pos:GetXY()
    if not x or not y then return end
    -- Match the nearest flower or tuber within a tight radius (~ node size).
    local RADIUS = 0.015
    local fIdx, fDist = Timers.NearestNode("flower", x, y)
    local tIdx, tDist = Timers.NearestNode("tuber", x, y)
    if fDist and (not tDist or fDist <= tDist) and fDist <= RADIUS then
        Timers.MarkNode("flower", fIdx, now(), "local")
    elseif tDist and tDist <= RADIUS then
        Timers.MarkNode("tuber", tIdx, now(), "local")
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
    if not (C_Timer and C_Timer.After) then return end

    local s = stateOf(buffKey)
    local anchor = anchorEpoch(s)
    if anchor <= 0 then return end
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
-- scheduler and false-positive gate survive a relog.
function Timers.RehydrateFromStore()
    if not (ns.Store and ns.Store.GetTimers) then return end
    local logs = ns.Store.GetTimers().logs or {}
    for buffKey, logKey in pairs(STORE_LOG_KEY) do
        local list = logs[logKey]
        if list and list[1] then
            local newest = list[1]
            local s = stateOf(buffKey)
            if newest.killed then
                s.lastKilled = math.max(s.lastKilled or 0, newest.epoch or 0)
            else
                s.lastPop = math.max(s.lastPop or 0, newest.epoch or 0)
            end
            s.trust = s.trust or newest.trust or "local"
        end
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
            snap.buffs[k] = { lastPop = s.lastPop, lastKilled = s.lastKilled, trust = s.trust }
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
    Timers.Record(buffKey, epoch, "mesh", (meta and meta.who) or "mesh", kind or "pop",
                  meta and meta.zone)
end

-- Inbound pull event from the mesh with a 10s relay-age gate (spec).
function Timers.OnMeshPull(buffKey, epoch, duration, zone, meta)
    local age = now() - (epoch or now())
    if age > 10 then return end   -- stale relayed pull, drop
    Timers.Record(buffKey, epoch or now(), "mesh", (meta and meta.who) or "mesh", "pop",
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
local MESH_REQUEST_CD = 30          -- seconds between mesh data requests
local NWB_REREQUEST_INTERVAL = 120  -- seconds; re-ask if no NWB seen yet

function Timers.RequestTimerData()
    local t = now()
    if (t - (Timers._lastMeshRequest or 0)) < MESH_REQUEST_CD then return end
    Timers._lastMeshRequest = t
    if ns.Mesh and ns.Mesh.RequestTimers then
        ns:SafeCall(ns.Mesh.RequestTimers)
    end
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
        if s and anchorEpoch(s) > 0 then
            local cdInfo = Timers.ComputeCD(k, anchorEpoch(s), t)
            local status = cdInfo.ready and "READY" or ("CD " .. fmtRemaining(cdInfo.remaining))
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

-- False-positive gate: within-CD pop rejected, kill resets, post-CD ok.
local function testFalsePositive(fails)
    Timers.state = {}
    local a = 1500000000
    local ok1 = Timers.Record("rend", a, "local", "t1", "pop")
    tcheck(ok1 == true, "first rend pop applied", fails)
    local ok2 = Timers.Record("rend", a + 3600, "local", "t2", "pop")
    tcheck(ok2 == false, "rend pop within CD rejected as false positive", fails)
    local ok3 = Timers.Record("rend", a + 1800, "local", "t3", "killed")
    tcheck(ok3 == true, "kill within CD applied (resets)", fails)
    -- After a kill reset at a+1800, a pop at a+1801 is within the new CD.
    local ok4 = Timers.Record("rend", a + 1801, "local", "t4", "pop")
    tcheck(ok4 == false, "pop right after kill reset still within CD", fails)
    -- A pop a full CD past the kill anchor is accepted.
    local ok5 = Timers.Record("rend", a + 1800 + CD.rend + 1, "local", "t5", "pop")
    tcheck(ok5 == true, "pop a full CD past the kill anchor accepted", fails)
    Timers.state = {}
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

function Timers.RunSelfTests(verbose)
    local suites = {
        { name = "cd derivation",     fn = testCDDerivation },
        { name = "false-positive gate", fn = testFalsePositive },
        { name = "trust upgrade",     fn = testTrustUpgrade },
        { name = "log dedup",         fn = testLogDedup },
        { name = "node state machine", fn = testNodeStateMachine },
        { name = "ingest parsers",    fn = testIngestParsers },
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

    -- Stand up receive-only NWB ingest if the shared libs are present.
    setupNWB()

    -- Event detectors.
    ns:RegisterEvent("CHAT_MSG_MONSTER_YELL", onMonsterYell)
    ns:RegisterEvent("CHAT_MSG_MONSTER_SAY",  onMonsterYell)
    ns:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED", onCombatLog)
    ns:RegisterEvent("QUEST_TURNED_IN", onQuestTurnedIn)
    ns:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED", onSpellSucceeded)
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
end

-- Go active at login (Core fires Tracker/Protocol OnLogin already; we hook
-- the same lifecycle event so no Core edit is needed for activation).
if ns.On then
    ns:On("LOGIN", function() ns:SafeCall(Timers.OnLogin) end)
end
