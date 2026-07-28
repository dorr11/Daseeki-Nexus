-- Daseeki Network — mesh.lua  (WAVE N2a: MESH COMM LAYER)
-- The token-gated P2P overlay that carries cross-account state, timers,
-- heartbeats and bulk sync between Daseeki-suite accounts.
--
-- Builds on the N1 foundation:
--   * ns.Core  : RegisterEvent / On / Fire / RegisterSubcommand / GetAccountID
--   * ns.Store : WriteInboundCharacter (self-immune, epoch-gated, now with a
--                lowest-account-ID tiebreak wired below), GetAccount / segments
--   * ns.Protocol : PREFIX.{TIMER,STATE,HEARTBEAT,SYNC}, TokenBucket,
--                   PriorityQueue, Chunk.Split/Reassemble,
--                   EncodeCharacter / DecodeCharacter
--
-- Clean-room: every prefix, frame layout and schema is Daseeki's own design.
-- There is deliberately no wire-compatibility with any other addon and no
-- payload obfuscation — token-gating is the whole trust model.
--
-- Wire layers (outer -> inner):
--   1. Chunk envelope   : fixed-width, binary-safe, splits frames > ~230B.
--   2. Frame            : "1" \t op \t msgId \t sessSeq \t relayTo \t payload
--                         (payload may itself contain \t / raw binary — the
--                          header is parsed by counting the first 5 tabs).
--   3. Payload          : binary character schema (STATE) OR a LibSerialize +
--                         LibDeflate blob (heartbeat / sync / settings / timer).

local ADDON, ns = ...

local Mesh = {}
ns.Mesh = Mesh

local Protocol = ns.Protocol
local Store    = ns.Store

----------------------------------------------------------------------
-- Tunables (spec §3)
----------------------------------------------------------------------

Mesh.PROTO_VERSION   = "1"          -- frame version byte; others rejected
Mesh.MESH_CAP        = 8            -- max accounts in the overlay
Mesh.HB_BASE         = 20           -- heartbeat base seconds
Mesh.HB_JITTER       = 3            -- +/- jitter -> 17..23s
Mesh.DRAIN_INTERVAL  = 0.05         -- 50ms send ticker
Mesh.DEDUP_WINDOW    = 120          -- 2-min message-id dedup window
Mesh.TIMER_DEDUP_WIN = 120          -- timer buff:yell:epoch dedup window
Mesh.REASM_TIMEOUT   = 10           -- chunk reassembly timeout (s)
Mesh.REASM_TIMEOUT_BIG = 60         -- large settings payload window (s)
Mesh.FAIL_SKIP_COUNT = 5            -- consecutive fails -> skip target
Mesh.FAIL_SKIP_TIME  = 10           -- skip duration (s)
Mesh.DIRECT_BUDGET   = 4            -- direct state sends before delegating
Mesh.CHUNK_DATA_MAX  = 230          -- payload bytes/chunk (255 - envelope room)

-- Bucket cap / refill per prefix (spec: cap 8, refill 1/s).
Mesh.BUCKET_CAP    = 8
Mesh.BUCKET_REFILL = 1

-- Per-op token cost + max burst (spec op caps: relay <=3, sync/summoner <=5-6).
-- Cost is charged against the prefix bucket per send; MAX_BURST caps how many
-- of that op-class may drain consecutively before yielding the tick to others.
Mesh.OP_COST = {
    timer = 1, state = 1, heartbeat = 1, discovery = 1,
    relay = 1, sync = 1, settings = 1, ack = 1,
}
Mesh.OP_MAX_BURST = { relay = 3, sync = 6, settings = 6 }

-- Frame operation codes (single chars keep the header tiny).
local OP = {
    STATE      = "s",   -- binary character push
    RELAY      = "r",   -- forwarded character push (one hop; relayTo stripped)
    HEARTBEAT  = "h",   -- segment/homeless/timer hashes + online hint
    PING       = "p",   -- discovery ping
    PONG       = "o",   -- discovery response
    SYNC_REQ   = "q",   -- request manifest/segment for a diverging area
    MANIFEST   = "m",   -- manifest (ordered list + hash + epoch)
    SEGMENT    = "g",   -- segment character data
    SETTINGS   = "t",   -- settings blob
    BLACKLIST  = "b",   -- blacklist union
    ACK        = "a",   -- settings/blacklist acknowledgement
    TIMER      = "z",   -- timer / pull event (payload from N2b handoff)
}
Mesh.OP = OP

-- Priority tiers (lower = served first). Keyed by the semantic op-name strings
-- carried in a queued item's meta.op (NOT the single-char wire codes).
local PRIO = {
    timer = 1, discovery = 2, ack = 2,
    state = 3, heartbeat = 3,
    relay = 4, sync = 4,
    settings = 6,
}

----------------------------------------------------------------------
-- Pure string helpers (no WoW globals; harness-portable)
----------------------------------------------------------------------

local B36 = "0123456789abcdefghijklmnopqrstuvwxyz"
local function toBase36(n)
    n = math.floor(n or 0)
    if n <= 0 then return "0" end
    local out = {}
    while n > 0 do
        local d = n % 36
        out[#out + 1] = B36:sub(d + 1, d + 1)
        n = math.floor(n / 36)
    end
    -- reverse
    local s = {}
    for i = #out, 1, -1 do s[#s + 1] = out[i] end
    return table.concat(s)
end
Mesh.ToBase36 = toBase36

-- Split on a single-byte separator, returning ALL fields (empty preserved).
local function splitAll(s, sep)
    local out, start = {}, 1
    while true do
        local i = s:find(sep, start, true)
        if not i then
            out[#out + 1] = s:sub(start)
            break
        end
        out[#out + 1] = s:sub(start, i - 1)
        start = i + 1
    end
    return out
end

-- Join a list with a separator.
local function joinList(list, sep)
    return table.concat(list, sep)
end

-- Deterministic string hash -> base36 id. Uses two independent polynomial
-- rolling accumulators (different multipliers + 31-bit primes) combined into
-- one token, to keep collisions low for change-detection. Implemented with
-- pure ARITHMETIC only — WoW's Lua 5.1 has no bitwise operators, and every
-- product stays under 2^53 so double precision is exact.
local function fnv1a(str)
    local h1, h2 = 5381, 2166136261 % 2147483647
    for i = 1, #str do
        local b = str:byte(i)
        h1 = (h1 * 33 + b) % 2147483647
        h2 = (h2 * 65599 + b) % 2147483629
    end
    return toBase36(h1) .. "-" .. toBase36(h2)
end
Mesh.Fnv1a = fnv1a

----------------------------------------------------------------------
-- Segment / homeless / timer hashing (heartbeat inputs)
----------------------------------------------------------------------

-- Hash an ordered segment list ("X" tombstone slots included) to a short id.
function Mesh.HashSegment(list)
    if not list or #list == 0 then return "0" end
    return fnv1a(joinList(list, "\30"))
end

-- Hash a set (unordered map of key->truthy) deterministically by sorting keys.
function Mesh.HashSet(set)
    if not set then return "0" end
    local keys = {}
    for k in pairs(set) do keys[#keys + 1] = tostring(k) end
    if #keys == 0 then return "0" end
    table.sort(keys)
    return fnv1a(joinList(keys, "\30"))
end

-- Hash the timer node/log state to a short id (mismatch -> timer sync).
function Mesh.HashTimers(timers)
    if not timers then return "0" end
    local parts = {}
    local flower, tuber = timers.flower or {}, timers.tuber or {}
    for i = 1, 10 do parts[#parts + 1] = tostring(flower[i] or 0) end
    for i = 1, 6 do parts[#parts + 1] = tostring(tuber[i] or 0) end
    parts[#parts + 1] = tostring(timers.timerVersion or 0)
    return fnv1a(joinList(parts, ","))
end

-- Compute the hash bundle we advertise for an account bucket.
function Mesh.AccountHashes(bucket)
    local seg = bucket and bucket.segments or {}
    return {
        sixties   = Mesh.HashSegment(seg.sixties),
        summoners = Mesh.HashSegment(seg.summoners),
        norole    = Mesh.HashSegment(seg.norole),
        homeless  = Mesh.HashSet(bucket and bucket.homeless),
    }
end

-- Return the list of segment names whose hashes differ between two bundles.
function Mesh.DiffHashes(localH, remoteH)
    local diffs = {}
    local names = { "sixties", "summoners", "norole", "homeless" }
    for i = 1, #names do
        local n = names[i]
        if (localH and localH[n] or "0") ~= (remoteH and remoteH[n] or "0") then
            diffs[#diffs + 1] = n
        end
    end
    return diffs
end

----------------------------------------------------------------------
-- Relay assignment math (spec §3 — the testable core)
--
-- Given the online peer account IDs (numeric strings), a direct-send budget
-- and our own account ID, produce a plan:
--   direct  : peers we whisper the state to ourselves
--   relays  : { [relayPeerID] = { delegatedID, ... } } one-hop delegations
--   backups : { top, bottom } roster ends we always CC (dedup rejects dupes)
--
-- Peers are ordered ascending by numeric account ID for determinism. When the
-- peer count fits the budget every peer is a direct send. Overflow peers are
-- distributed round-robin across the direct recipients as relayTo delegations.
----------------------------------------------------------------------

local function numericAID(a) return tonumber(a) or 0 end

function Mesh.ComputeRelayPlan(peerIDs, budget, selfID)
    budget = budget or Mesh.DIRECT_BUDGET
    local peers = {}
    for i = 1, #peerIDs do
        if peerIDs[i] ~= selfID then peers[#peers + 1] = peerIDs[i] end
    end
    table.sort(peers, function(a, b)
        local na, nb = numericAID(a), numericAID(b)
        if na == nb then return tostring(a) < tostring(b) end
        return na < nb
    end)

    local plan = { direct = {}, relays = {}, backups = {} }
    if #peers == 0 then return plan end

    -- Backup relays: lowest (top) and highest (bottom) of the roster.
    plan.backups = { peers[1] }
    if #peers > 1 then plan.backups[2] = peers[#peers] end

    if #peers <= budget then
        for i = 1, #peers do plan.direct[i] = peers[i] end
        return plan
    end

    -- First `budget` peers are direct recipients; the rest are delegated.
    for i = 1, budget do
        plan.direct[i] = peers[i]
        plan.relays[peers[i]] = {}
    end
    local d = 0
    for i = budget + 1, #peers do
        local target = plan.direct[(d % budget) + 1]
        local list = plan.relays[target]
        list[#list + 1] = peers[i]
        d = d + 1
    end
    return plan
end

----------------------------------------------------------------------
-- Runtime state
----------------------------------------------------------------------

Mesh.peers = {}          -- [accountID] = { name, aid, lastSeen, lastPush,
                         --                 online, hashes = {perAccount}, timerHash }
Mesh._seenIds = {}       -- [msgId] = expiryEpoch
Mesh._timerSeen = {}     -- [dedupKey] = expiryEpoch
Mesh._outSeq = 0         -- our per-session outgoing sequence
Mesh._inSeq = {}         -- [sender] = last seen sessSeq (stale rejection)
Mesh._reasm = {}         -- [sender.."\1"..prefix.."\1"..seq] = { parts, total, first, big }
Mesh._fail = {}          -- [target] = { count, skipUntil }
Mesh._sched = {}         -- [prefix] = { bucket, queue, rr }
Mesh._ackWait = {}       -- [syncId] = { [target]=true } pending ACKs
Mesh._sessionId = 0      -- randomised at login to prefix message ids
Mesh._timerCodec = nil   -- N2b handoff codec (see §Timer handoff)
Mesh._timerHandler = nil -- N2b handoff receive callback

-- Channel-join retry state machine + discovery telemetry (see §Channel join).
Mesh._joinState = nil    -- { chanName, attempts, index, joined, gaveUp, pingedOnJoin }
Mesh._joinGen   = 0      -- generation token: supersedes stale in-flight retry loops
Mesh._lastJoinPing = 0   -- throttle re-pings triggered by newcomer channel joins
Mesh._disco = {          -- last discovery ping/pong timestamps (for /dsn debug mesh)
    lastPingSent = 0, lastPingRecv = 0,
    lastPongSent = 0, lastPongRecv = 0,
}

-- Join-retry tunables: verify GetChannelName after each attempt on a backoff.
-- Channel joins routinely fail in the first seconds after login, so we issue
-- the join, then re-check on a widening schedule up to JOIN_MAX_TRIES times.
Mesh.JOIN_DELAYS     = { 5, 7, 10, 15, 22 }   -- seconds between verification ticks
Mesh.JOIN_MAX_TRIES  = 5                       -- max join calls before giving up
Mesh.JOIN_PING_THROTTLE = 3                    -- min seconds between newcomer re-pings

----------------------------------------------------------------------
-- Lib + game API access (guarded so the pure core loads without them)
----------------------------------------------------------------------

local function libSerialize()
    return LibStub and LibStub.GetLibrary and LibStub:GetLibrary("LibSerialize", true)
end
local function libDeflate()
    return LibStub and LibStub.GetLibrary and LibStub:GetLibrary("LibDeflate", true)
end

-- Serialize+compress+channel-encode an arbitrary table -> wire string (or nil).
function Mesh.Pack(tbl)
    local LS, LD = libSerialize(), libDeflate()
    if not (LS and LD) then return nil end
    local ok, ser = pcall(function() return LS:Serialize(tbl) end)
    if not ok or not ser then return nil end
    local comp = LD:CompressDeflate(ser, { level = 9 })
    return LD:EncodeForWoWAddonChannel(comp)
end

-- Reverse of Pack: wire string -> table (or nil).
function Mesh.Unpack(str)
    local LS, LD = libSerialize(), libDeflate()
    if not (LS and LD) then return nil end
    local comp = LD:DecodeForWoWAddonChannel(str)
    if not comp then return nil end
    local ser = LD:DecompressDeflate(comp)
    if not ser then return nil end
    local ok, res = pcall(function() return select(2, LS:Deserialize(ser)) end)
    if ok then return res end
    return nil
end

----------------------------------------------------------------------
-- Identity / membership
----------------------------------------------------------------------

local function selfNameRealm()
    local name = UnitName and UnitName("player") or "player"
    local realm = (GetRealmName and GetRealmName()) or ""
    realm = realm:gsub("%s+", "")
    return name .. "-" .. realm
end
Mesh.SelfNameRealm = selfNameRealm

-- True if `sender` is us. CHAT_MSG_ADDON reports a full "Name-Realm" for our own
-- channel/guild echoes, but some paths (and CHAT_MSG_CHANNEL_JOIN) report the
-- bare "Name", so match both forms to reliably drop self-echoes.
function Mesh.IsSelfSender(sender)
    if not sender or sender == "" then return false end
    if sender == selfNameRealm() then return true end
    local bare = UnitName and UnitName("player") or "player"
    return sender == bare
end

function Mesh.MeshSettings()
    local db = Store and Store.GetSettings and Store.GetSettings()
    return db and db.mesh or nil
end

-- Mesh is live only with a token, enabled, not opted out, and a valid AID.
function Mesh.IsEnabled()
    local m = Mesh.MeshSettings()
    if not m then return false end
    if not m.enabled or m.optOut then return false end
    if not m.token or m.token == "" then return false end
    local aid = ns:GetAccountID()
    return aid ~= "" and ns:IsValidAccountID(aid)
end

-- Discovery channel name derived from the shared token so every mesh member
-- lands on the same hidden channel with zero extra config. Channel names are
-- capped short and alnum for safety.
function Mesh.GetChannelName()
    local m = Mesh.MeshSettings()
    if not m or not m.token or m.token == "" then return nil end
    -- Channel names must be alphanumeric; strip the hash separator.
    return "dsn" .. (fnv1a(m.token):gsub("%-", ""))
end

-- Count current mesh members (including self) for the 8-account cap.
local function meshMemberCount()
    local n = 1   -- self
    for _ in pairs(Mesh.peers) do n = n + 1 end
    return n
end

-- May we admit this account as a peer? Cap + tombstone gate.
function Mesh.CanAdmitPeer(aid)
    if not aid or aid == "" then return false end
    if aid == ns:GetAccountID() then return false end
    if Store.IsTombstoned and Store.IsTombstoned(aid) then return false end
    if Mesh.peers[aid] then return true end   -- already known
    return meshMemberCount() < Mesh.MESH_CAP
end

-- Record/refresh a peer (respecting cap + tombstone).
function Mesh.NotePeer(aid, name, now)
    if not Mesh.CanAdmitPeer(aid) then return nil end
    local p = Mesh.peers[aid]
    if not p then
        p = { aid = aid, hashes = {} }
        Mesh.peers[aid] = p
    end
    if name and name ~= "" then p.name = name end
    p.lastSeen = now or (Store and Store.Now and Store.Now()) or 0
    p.online = true
    return p
end

-- Resolve an account ID to its most-recently-seen Name-Realm (for relay lists).
function Mesh.NameForAID(aid)
    local p = Mesh.peers[aid]
    return p and p.name or nil
end

----------------------------------------------------------------------
-- Dedup + session guards
----------------------------------------------------------------------

local function now() return (Store and Store.Now and Store.Now()) or 0 end

-- Account-prefixed base-36 message id, unique within a session.
function Mesh.MakeMessageId()
    Mesh._outSeq = Mesh._outSeq + 1
    local aid = ns:GetAccountID()
    return (aid ~= "" and aid or "0") .. "-"
        .. toBase36(Mesh._sessionId) .. "-" .. toBase36(Mesh._outSeq)
end

-- True if this id was seen inside the dedup window (and records it if not).
function Mesh.SeenBefore(id, t)
    t = t or now()
    local exp = Mesh._seenIds[id]
    if exp and exp > t then return true end
    Mesh._seenIds[id] = t + Mesh.DEDUP_WINDOW
    return false
end

-- Timer-event dedup on buff:yellNum:epoch.
function Mesh.TimerSeen(dedupKey, t)
    if not dedupKey then return false end
    t = t or now()
    local exp = Mesh._timerSeen[dedupKey]
    if exp and exp > t then return true end
    Mesh._timerSeen[dedupKey] = t + Mesh.TIMER_DEDUP_WIN
    return false
end

-- Prune expired dedup entries (called from the drain ticker occasionally).
function Mesh.PruneDedup(t)
    t = t or now()
    for id, exp in pairs(Mesh._seenIds) do
        if exp <= t then Mesh._seenIds[id] = nil end
    end
    for k, exp in pairs(Mesh._timerSeen) do
        if exp <= t then Mesh._timerSeen[k] = nil end
    end
end

-- Session-sequence check: reject stale/out-of-order frames from a sender.
-- Returns true if the frame is fresh (and records the new high-water mark).
function Mesh.FreshSeq(sender, seq)
    seq = tonumber(seq) or 0
    if seq == 0 then return true end   -- unsequenced ops (ping/ack) always pass
    local last = Mesh._inSeq[sender] or 0
    if seq <= last then return false end
    Mesh._inSeq[sender] = seq
    return true
end

----------------------------------------------------------------------
-- Failure tracking (5 consecutive fails -> skip target 10s)
----------------------------------------------------------------------

function Mesh.TargetSkipped(target, t)
    local f = Mesh._fail[target]
    if not f then return false end
    return (f.skipUntil or 0) > (t or now())
end

function Mesh.NoteFailure(target, t)
    t = t or now()
    local f = Mesh._fail[target]
    if not f then f = { count = 0, skipUntil = 0 }; Mesh._fail[target] = f end
    f.count = f.count + 1
    if f.count >= Mesh.FAIL_SKIP_COUNT then
        f.skipUntil = t + Mesh.FAIL_SKIP_TIME
        f.count = 0
    end
end

function Mesh.NoteSuccess(target)
    local f = Mesh._fail[target]
    if f then f.count = 0 end
end

----------------------------------------------------------------------
-- Frame build / parse
--
-- Frame = version \t op \t msgId \t sessSeq \t relayTo \t payload
-- Header is the first 5 tab-delimited fields; everything after the 5th tab is
-- the payload verbatim (so binary payloads containing \t survive intact).
----------------------------------------------------------------------

local TAB = "\t"

function Mesh.BuildFrame(op, payload, opts)
    opts = opts or {}
    local msgId  = opts.msgId or Mesh.MakeMessageId()
    local seq    = opts.seq or 0
    local relay  = opts.relayTo or ""
    return table.concat({
        Mesh.PROTO_VERSION, op, msgId, tostring(seq), relay, payload or ""
    }, TAB), msgId
end

-- Parse a frame; returns table or nil,reason. Rejects wrong version bytes.
function Mesh.ParseFrame(frame)
    -- Find the first five tab positions.
    local pos, bounds = 0, {}
    for _ = 1, 5 do
        local i = frame:find(TAB, pos + 1, true)
        if not i then return nil, "short frame" end
        bounds[#bounds + 1] = i
        pos = i
    end
    local version = frame:sub(1, bounds[1] - 1)
    if version ~= Mesh.PROTO_VERSION then
        return nil, "bad version " .. tostring(version)
    end
    return {
        version = version,
        op      = frame:sub(bounds[1] + 1, bounds[2] - 1),
        msgId   = frame:sub(bounds[2] + 1, bounds[3] - 1),
        seq     = frame:sub(bounds[3] + 1, bounds[4] - 1),
        relayTo = frame:sub(bounds[4] + 1, bounds[5] - 1),
        payload = frame:sub(bounds[5] + 1),
    }
end

----------------------------------------------------------------------
-- Chunk envelope (fixed-width, binary-safe)
--   marker(1) index(3) total(3) seq(6, base36) \t data
----------------------------------------------------------------------

local function pad(s, n)
    s = tostring(s)
    while #s < n do s = "0" .. s end
    return s:sub(-n)
end

function Mesh.EnvelopeChunk(chunk)
    return chunk.marker
        .. pad(chunk.index, 3)
        .. pad(chunk.total, 3)
        .. pad(toBase36(chunk.seq or 0), 6)
        .. TAB
        .. (chunk.data or "")
end

function Mesh.DeEnvelope(wire)
    if #wire < 14 then return nil end
    local marker = wire:sub(1, 1)
    if marker ~= "S" and marker ~= "F" and marker ~= "M" and marker ~= "L" then
        return nil
    end
    local index = tonumber(wire:sub(2, 4))
    local total = tonumber(wire:sub(5, 7))
    local seqStr = wire:sub(8, 13)
    if wire:sub(14, 14) ~= TAB then return nil end
    local data = wire:sub(15)
    -- base36 decode seq
    local seq = 0
    for i = 1, #seqStr do
        local c = seqStr:sub(i, i)
        local d = (B36:find(c, 1, true) or 1) - 1
        seq = seq * 36 + d
    end
    return { marker = marker, index = index, total = total, seq = seq, data = data }
end

----------------------------------------------------------------------
-- Send scheduling (per-prefix bucket + priority queue, 50ms drain)
----------------------------------------------------------------------

local function scheduler(prefix)
    local s = Mesh._sched[prefix]
    if not s then
        s = {
            bucket = Protocol.TokenBucket.new(Mesh.BUCKET_CAP, Mesh.BUCKET_REFILL, now()),
            queue  = Protocol.PriorityQueue.new(),
            rr     = {},   -- per-target round-robin fairness bookkeeping
        }
        Mesh._sched[prefix] = s
    end
    return s
end

-- Low-level send of one already-enveloped wire string. C_ChatInfo returns a
-- SendAddonMessageResult; Success is 0. Treat 0 or nil as delivered, anything
-- else (throttled / invalid target) as a failure for the skip tracker.
local function rawSend(prefix, wire, chatType, target)
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return false end
    local res = C_ChatInfo.SendAddonMessage(prefix, wire, chatType, target)
    return res == nil or res == 0
end

-- Enqueue a fully-built frame for a prefix, chunking as needed.
-- meta = { op, chatType, target, priority, cost }
function Mesh.Enqueue(prefix, frame, meta)
    meta = meta or {}
    local seq = meta.seq or Mesh._outSeq
    local big = (#frame > Mesh.CHUNK_DATA_MAX)
    local chunks = Protocol.Chunk.Split(frame, seq, Mesh.CHUNK_DATA_MAX)
    local s = scheduler(prefix)
    local prio = meta.priority or PRIO[meta.op] or 5
    for i = 1, #chunks do
        s.queue:Push(prio, {
            wire     = Mesh.EnvelopeChunk(chunks[i]),
            chatType = meta.chatType or "WHISPER",
            target   = meta.target,
            op       = meta.op,
            cost     = meta.cost or (meta.op and Mesh.OP_COST[meta.op]) or 1,
            big      = big,
        })
    end
end

-- Drain one message per prefix per tick, honouring buckets, target skips and
-- per-op burst caps. Called by the 50ms ticker.
function Mesh.DrainTick(t)
    t = t or now()
    for prefix, s in pairs(Mesh._sched) do
        s.bucket:Refill(t)
        local burst = {}
        -- One send per prefix per tick keeps us well under the hardware cap;
        -- we scan the queue for the first eligible (non-skipped) target.
        local picked, rejects = nil, {}
        while not s.queue:IsEmpty() do
            local item = s.queue:Pop()
            if not item then break end
            local op = item.op or "state"
            local burstCap = Mesh.OP_MAX_BURST[op]
            if item.target and Mesh.TargetSkipped(item.target, t) then
                rejects[#rejects + 1] = item          -- requeue: still skipped
            elseif burstCap and (burst[op] or 0) >= burstCap then
                rejects[#rejects + 1] = item          -- yield to other ops
            elseif not s.bucket:TryConsume(item.cost, t) then
                rejects[#rejects + 1] = item          -- out of tokens this tick
                break
            else
                picked = item
                burst[op] = (burst[op] or 0) + 1
                break
            end
        end
        -- Requeue anything we skipped over this tick.
        for i = 1, #rejects do
            s.queue:Push(PRIO[rejects[i].op] or 5, rejects[i])
        end
        if picked then
            local ok = rawSend(prefix, picked.wire, picked.chatType, picked.target)
            if picked.target then
                if ok then Mesh.NoteSuccess(picked.target)
                else Mesh.NoteFailure(picked.target, t) end
            end
        end
    end
    Mesh.PruneDedup(t)
    Mesh.SweepReassembly(t)
end

----------------------------------------------------------------------
-- Reassembly
----------------------------------------------------------------------

local function reasmKey(sender, prefix, seq)
    return sender .. "\1" .. prefix .. "\1" .. tostring(seq)
end

-- Feed an enveloped chunk; returns the full frame string when complete, else nil.
function Mesh.FeedChunk(sender, prefix, env, t)
    t = t or now()
    if env.marker == "S" then
        return env.data
    end
    local key = reasmKey(sender, prefix, env.seq)
    local r = Mesh._reasm[key]
    if not r then
        r = { parts = {}, total = env.total, first = t, big = false }
        Mesh._reasm[key] = r
    end
    r.parts[env.index] = env.data
    r.total = env.total
    -- large-settings payloads get the extended window
    if prefix == Protocol.PREFIX.SYNC then r.big = true end
    -- complete?
    for i = 1, r.total do
        if r.parts[i] == nil then return nil end
    end
    Mesh._reasm[key] = nil
    local buf = {}
    for i = 1, r.total do buf[i] = r.parts[i] end
    return table.concat(buf)
end

function Mesh.SweepReassembly(t)
    t = t or now()
    for key, r in pairs(Mesh._reasm) do
        local timeout = r.big and Mesh.REASM_TIMEOUT_BIG or Mesh.REASM_TIMEOUT
        if t - (r.first or 0) > timeout then
            Mesh._reasm[key] = nil
        end
    end
end

----------------------------------------------------------------------
-- Outbound: state pushes (DSKN1) with relay assignment
----------------------------------------------------------------------

-- List of currently-online peer account IDs.
local function onlinePeerIDs()
    local ids = {}
    for aid, p in pairs(Mesh.peers) do
        if p.online then ids[#ids + 1] = aid end
    end
    return ids
end

-- Build a relayTo string for a delegated list: "Name-Realm,aid2,aid3".
-- The first entry is the FULL name of the primary delegate so the receiver can
-- forward even before it has that peer in its own table.
local function buildRelayTo(delegatedIDs)
    if #delegatedIDs == 0 then return "" end
    local first = delegatedIDs[1]
    local firstName = Mesh.NameForAID(first) or first
    local parts = { firstName }
    for i = 2, #delegatedIDs do parts[#parts + 1] = delegatedIDs[i] end
    return joinList(parts, ",")
end

-- Push a live character record to the mesh (called on STATE_CHANGED).
function Mesh.PushState(nameRealm, record)
    if not Mesh.IsEnabled() then return end
    local payload = Protocol.EncodeCharacter(record)
    local ids = onlinePeerIDs()
    local plan = Mesh.ComputeRelayPlan(ids, Mesh.DIRECT_BUDGET, ns:GetAccountID())

    local sent = {}    -- guard against double-whispering a backup
    local function sendDirect(aid, delegated)
        local name = Mesh.NameForAID(aid)
        if not name or sent[name] then return end
        sent[name] = true
        local relayTo = delegated and buildRelayTo(delegated) or ""
        local seq = Mesh._outSeq + 1
        local frame = Mesh.BuildFrame(OP.STATE, payload, { seq = seq, relayTo = relayTo })
        Mesh.Enqueue(Protocol.PREFIX.STATE, frame, {
            op = "state", chatType = "WHISPER", target = name, seq = seq,
        })
        local p = Mesh.peers[aid]; if p then p.lastPush = now() end
    end

    for i = 1, #plan.direct do
        local aid = plan.direct[i]
        sendDirect(aid, plan.relays[aid])
    end
    -- Backup top/bottom relays even when the budget already covered everyone.
    for i = 1, #plan.backups do
        sendDirect(plan.backups[i], nil)
    end
end

-- Forward a received state push one hop to its delegated targets, then strip.
local function forwardRelay(frame, relayTo, payload, srcSeq)
    if not relayTo or relayTo == "" then return end
    local list = splitAll(relayTo, ",")
    for i = 1, #list do
        local token = list[i]
        local name
        if i == 1 then
            name = token                 -- first entry is a full Name-Realm
        else
            name = Mesh.NameForAID(token) -- rest are account IDs
        end
        if name and name ~= "" then
            local seq = Mesh._outSeq + 1
            local fwd = Mesh.BuildFrame(OP.RELAY, payload, { seq = seq, relayTo = "" })
            Mesh.Enqueue(Protocol.PREFIX.STATE, fwd, {
                op = "relay", chatType = "WHISPER", target = name, seq = seq,
            })
        end
    end
end

----------------------------------------------------------------------
-- Inbound: dispatch a decoded frame
----------------------------------------------------------------------

-- Map a Name-Realm sender to its account ID via the peer table (best effort).
local function aidForName(name)
    for aid, p in pairs(Mesh.peers) do
        if p.name == name then return aid end
    end
    return nil
end

local function handleState(f, sender, isRelay)
    local rec, err = Protocol.DecodeCharacter(f.payload)
    if not rec then return end
    local ownerAID = aidForName(rec.nameRealm) or aidForName(sender) or ""
    -- Owner-wins / epoch / lowest-account-ID tiebreak lives in the store.
    local senderAID = aidForName(sender)
    Store.WriteInboundCharacter(ownerAID, rec.nameRealm, rec, senderAID)
    -- One-hop forward for genuine (non-relay) pushes carrying a relayTo list.
    if not isRelay then
        forwardRelay(f, f.relayTo, f.payload, f.seq)
    end
end

local function handleHeartbeat(f, sender)
    local hb = Mesh.Unpack(f.payload)
    if not hb or not hb.aid then return end
    local p = Mesh.NotePeer(hb.aid, sender, now())
    if not p then return end
    p.hashes = hb.hashes or {}
    p.timerHash = hb.timerHash
    -- Compare advertised segment hashes with what we hold for that account.
    local bucket = Store.GetAccount(hb.aid, false)
    local localH = bucket and Mesh.AccountHashes(bucket) or {}
    local diffs = Mesh.DiffHashes(localH, hb.hashes)
    for i = 1, #diffs do
        Mesh.RequestSync(sender, hb.aid, diffs[i])
    end
    -- Timer divergence -> ask for timer data.
    local localTimerHash = Mesh.HashTimers(Store.GetTimers and Store.GetTimers())
    if hb.timerHash and hb.timerHash ~= localTimerHash then
        Mesh.RequestSync(sender, "timers", "timers")
    end
end

local function handleDiscovery(f, sender, isPing)
    -- payload is a small packed { aid, name }
    local d = Mesh.Unpack(f.payload)
    local aid = d and d.aid
    if aid then Mesh.NotePeer(aid, sender, now()) end
    if isPing then
        Mesh._disco.lastPingRecv = now()
        -- respond with a PONG whisper announcing ourselves
        Mesh.SendDiscovery(OP.PONG, sender)
    else
        Mesh._disco.lastPongRecv = now()
    end
end

local function handleSyncReq(f, sender)
    local req = Mesh.Unpack(f.payload)
    if not req then return end
    if req.area == "timers" then
        Mesh.SendTimers(sender)
    else
        Mesh.SendManifest(sender, req.aid, req.area)
        Mesh.SendSegment(sender, req.aid, req.area)
    end
end

local function handleManifest(f, sender)
    -- Manifests are advisory here: the authoritative merge happens as segment
    -- character records arrive (owner-wins + epoch gate in the store). We keep
    -- the hook so a future wave can pre-diff before pulling full segments.
    local man = Mesh.Unpack(f.payload)
    if man and man.aid then Mesh.NotePeer(man.aid, sender, now()) end
end

local function handleSegment(f, sender)
    local seg = Mesh.Unpack(f.payload)
    if not seg or not seg.aid or not seg.records then return end
    local senderAID = aidForName(sender)
    for nameRealm, rec in pairs(seg.records) do
        Store.WriteInboundCharacter(seg.aid, nameRealm, rec, senderAID)
    end
end

local function handleSettings(f, sender)
    local blob = Mesh.Unpack(f.payload)
    if not blob then return end
    ns:Fire("MESH_SETTINGS_RECEIVED", blob, sender)
    -- ACK back to the sender; blacklist auto-chains on their side after ACK.
    Mesh.SendAck(sender, blob.syncId or "settings")
end

local function handleBlacklist(f, sender)
    local blob = Mesh.Unpack(f.payload)
    if not blob or not blob.blacklist then return end
    -- Union-merge into our blacklist.
    local db = Store.GetSettings()
    db.ui = db.ui or {}
    db.ui.blacklist = db.ui.blacklist or {}
    for nameRealm in pairs(blob.blacklist) do
        db.ui.blacklist[nameRealm] = true
    end
    ns:Fire("MESH_BLACKLIST_MERGED", blob.blacklist, sender)
    Mesh.SendAck(sender, blob.syncId or "blacklist")
end

local function handleAck(f, sender)
    local ack = Mesh.Unpack(f.payload)
    local syncId = ack and ack.syncId
    if not syncId then return end
    local wait = Mesh._ackWait[syncId]
    if wait then
        wait[sender] = nil
        -- Auto-chain: once settings ACKs land, push the blacklist union.
        if ack.kind == "settings" then
            Mesh.SendBlacklist(sender)
        end
    end
end

local function handleTimer(f, sender, isRelay)
    -- Decode via the N2b-registered codec (falls back to Pack/Unpack).
    local evt
    if Mesh._timerCodec and Mesh._timerCodec.decode then
        evt = Mesh._timerCodec.decode(f.payload)
    else
        evt = Mesh.Unpack(f.payload)
    end
    if not evt then return end
    -- Timer dedup on buff:yellNum:epoch.
    local key = evt.dedupKey
    if key and Mesh.TimerSeen(key) then return end
    -- Hand off to the timers layer (N2b) if it registered a handler.
    if Mesh._timerHandler then
        ns:SafeCall(Mesh._timerHandler, evt, sender, isRelay)
    end
    ns:Fire("MESH_TIMER_RECEIVED", evt, sender, isRelay)
    -- Non-originator receivers re-broadcast ONLY to party/raid/yell, never mesh.
    Mesh.RebroadcastTimerLocal(f.payload)
end

-- Central inbound dispatcher.
function Mesh.Dispatch(prefix, frame, sender)
    local f, reason = Mesh.ParseFrame(frame)
    if not f then return end
    -- Dedup + session freshness. Freshness is keyed per (sender, prefix): seqs
    -- come from one global counter, so cross-prefix interleaving must not let a
    -- higher-seq message on one prefix stale out a lower-seq one on another.
    if Mesh.SeenBefore(f.msgId) then return end
    if not Mesh.FreshSeq(sender .. "\1" .. prefix, f.seq) then return end

    local op = f.op
    if op == OP.STATE then          handleState(f, sender, false)
    elseif op == OP.RELAY then      handleState(f, sender, true)
    elseif op == OP.HEARTBEAT then  handleHeartbeat(f, sender)
    elseif op == OP.PING then       handleDiscovery(f, sender, true)
    elseif op == OP.PONG then       handleDiscovery(f, sender, false)
    elseif op == OP.SYNC_REQ then   handleSyncReq(f, sender)
    elseif op == OP.MANIFEST then   handleManifest(f, sender)
    elseif op == OP.SEGMENT then    handleSegment(f, sender)
    elseif op == OP.SETTINGS then   handleSettings(f, sender)
    elseif op == OP.BLACKLIST then  handleBlacklist(f, sender)
    elseif op == OP.ACK then        handleAck(f, sender)
    elseif op == OP.TIMER then      handleTimer(f, sender, true)
    end
end

----------------------------------------------------------------------
-- Outbound builders for the remaining ops
----------------------------------------------------------------------

-- Heartbeat: our self-account hashes + online-character hint + timer hash.
function Mesh.SendHeartbeat()
    if not Mesh.IsEnabled() then return end
    local aid = ns:GetAccountID()
    local bucket = Store.GetAccount(aid, false)
    local hb = {
        aid       = aid,
        hashes    = bucket and Mesh.AccountHashes(bucket) or {},
        timerHash = Mesh.HashTimers(Store.GetTimers and Store.GetTimers()),
        online    = {},   -- online-character hint (Name-Realm list)
    }
    if bucket then
        for nameRealm, rec in pairs(bucket.characters) do
            if rec and rec.lastSeen then hb.online[#hb.online + 1] = nameRealm end
        end
    end
    local payload = Mesh.Pack(hb)
    if not payload then return end
    -- Broadcast to the discovery channel so cross-guild peers hear us.
    local seq = Mesh._outSeq + 1
    local frame = Mesh.BuildFrame(OP.HEARTBEAT, payload, { seq = seq })
    Mesh.BroadcastChannel(Protocol.PREFIX.HEARTBEAT, frame, { op = "heartbeat", seq = seq })
end

-- Discovery ping/pong. `target` nil => broadcast ping to the channel.
function Mesh.SendDiscovery(op, target)
    if not Mesh.IsEnabled() then return end
    local payload = Mesh.Pack({ aid = ns:GetAccountID(), name = selfNameRealm() })
    if not payload then return end
    -- Telemetry: record when we emit a discovery ping/pong (surfaced in debug).
    if op == OP.PING then Mesh._disco.lastPingSent = now()
    elseif op == OP.PONG then Mesh._disco.lastPongSent = now() end
    local frame = Mesh.BuildFrame(op, payload, {})
    if target then
        Mesh.Enqueue(Protocol.PREFIX.HEARTBEAT, frame, {
            op = "discovery", chatType = "WHISPER", target = target,
        })
    else
        Mesh.BroadcastChannel(Protocol.PREFIX.HEARTBEAT, frame, { op = "discovery" })
    end
end

function Mesh.RequestSync(target, aid, area)
    local payload = Mesh.Pack({ aid = aid, area = area })
    if not payload then return end
    local frame = Mesh.BuildFrame(OP.SYNC_REQ, payload, {})
    Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
        op = "sync", chatType = "WHISPER", target = target,
    })
end

function Mesh.SendManifest(target, aid, area)
    local bucket = Store.GetAccount(aid, false)
    if not bucket then return end
    local seg = bucket.segments[area]
    local payload = Mesh.Pack({
        aid = aid, area = area, list = seg,
        hash = Mesh.HashSegment(seg),
        epoch = (bucket.segmentHashes[area] and bucket.segmentHashes[area].epoch) or 0,
    })
    if not payload then return end
    local frame = Mesh.BuildFrame(OP.MANIFEST, payload, {})
    Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
        op = "sync", chatType = "WHISPER", target = target,
    })
end

function Mesh.SendSegment(target, aid, area)
    local bucket = Store.GetAccount(aid, false)
    if not bucket then return end
    local seg = bucket.segments[area] or {}
    local records = {}
    for i = 1, #seg do
        local nameRealm = seg[i]
        if nameRealm ~= "X" and bucket.characters[nameRealm] then
            records[nameRealm] = bucket.characters[nameRealm]
        end
    end
    local payload = Mesh.Pack({ aid = aid, area = area, records = records })
    if not payload then return end
    local seq = Mesh._outSeq + 1
    local frame = Mesh.BuildFrame(OP.SEGMENT, payload, { seq = seq })
    Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
        op = "sync", chatType = "WHISPER", target = target, seq = seq,
    })
end

function Mesh.SendTimers(target)
    local payload = Mesh.Pack({ timers = Store.GetTimers and Store.GetTimers() })
    if not payload then return end
    local seq = Mesh._outSeq + 1
    local frame = Mesh.BuildFrame(OP.SEGMENT, payload, { seq = seq })
    Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
        op = "sync", chatType = "WHISPER", target = target, seq = seq,
    })
end

----------------------------------------------------------------------
-- Settings sync + blacklist union-sync (manual, all-to-all, ACK-tracked)
----------------------------------------------------------------------

-- Push settings to every online peer; track ACKs; blacklist auto-chains.
function Mesh.SyncSettings()
    if not Mesh.IsEnabled() then return end
    local db = Store.GetSettings()
    local syncId = "set-" .. toBase36(Mesh._sessionId) .. "-" .. toBase36(Mesh._outSeq + 1)
    local blob = {
        syncId = syncId, kind = "settings",
        -- Sync the propagatable settings surface (not identity/mesh secrets).
        classColors         = db.classColors,
        coordinateOverrides = db.coordinateOverrides,
        factionSettings     = db.factionSettings,
        timerSettings       = db.timerSettings,
    }
    local payload = Mesh.Pack(blob)
    if not payload then return end
    Mesh._ackWait[syncId] = {}
    for aid, p in pairs(Mesh.peers) do
        if p.online and p.name then
            Mesh._ackWait[syncId][p.name] = true
            local seq = Mesh._outSeq + 1
            local frame = Mesh.BuildFrame(OP.SETTINGS, payload, { seq = seq })
            Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
                op = "settings", chatType = "WHISPER", target = p.name, seq = seq,
            })
        end
    end
    return syncId
end

function Mesh.SendBlacklist(target)
    local db = Store.GetSettings()
    local syncId = "bl-" .. toBase36(Mesh._outSeq + 1)
    local blob = { syncId = syncId, kind = "blacklist",
                   blacklist = (db.ui and db.ui.blacklist) or {} }
    local payload = Mesh.Pack(blob)
    if not payload then return end
    local seq = Mesh._outSeq + 1
    local frame = Mesh.BuildFrame(OP.BLACKLIST, payload, { seq = seq })
    Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
        op = "settings", chatType = "WHISPER", target = target, seq = seq,
    })
end

function Mesh.SendAck(target, syncId, kind)
    local payload = Mesh.Pack({ syncId = syncId, kind = kind or "settings" })
    if not payload then return end
    local frame = Mesh.BuildFrame(OP.ACK, payload, {})
    Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
        op = "ack", chatType = "WHISPER", target = target,
    })
end

----------------------------------------------------------------------
-- Timer transport (DSKN0) + N2b handoff API
--
-- The mesh owns the *transport* for timer/pull events; the timer PAYLOADS and
-- their semantics are produced by the N2b timers agent, which wires in through
-- this documented handoff:
--
--   Mesh.RegisterTimerCodec({ encode = fn(evt) -> string,
--                             decode = fn(string) -> evt })
--       Optional. Lets timers supply a compact binary codec. If absent, the
--       generic LibSerialize path (Mesh.Pack/Unpack) is used. Every event
--       table SHOULD carry evt.dedupKey = "buff:yellNum:epoch" for dedup.
--
--   Mesh.SetTimerHandler(fn(evt, sender, isRelay))
--       Called for every inbound timer event after dedup. The timers layer
--       merges it into its own store and drives bars/alerts.
--
--   Mesh.BroadcastTimer(evt)   -- ORIGINATOR path
--       Timers calls this when THIS client is the source of a detection. Mesh
--       broadcasts to guild + party/raid + yell and whispers cross-group mesh
--       peers with relay assignment.
--
--   Mesh.RebroadcastTimerLocal(payload)  -- internal, receiver path
--       Non-originator receivers re-emit ONLY to party/raid/yell (no mesh
--       whispers) to prevent broadcast storms.
----------------------------------------------------------------------

function Mesh.RegisterTimerCodec(codec)
    Mesh._timerCodec = codec
end

function Mesh.SetTimerHandler(fn)
    Mesh._timerHandler = fn
end

local function encodeTimer(evt)
    if Mesh._timerCodec and Mesh._timerCodec.encode then
        return Mesh._timerCodec.encode(evt)
    end
    return Mesh.Pack(evt)
end

-- ORIGINATOR broadcast: local channels first, then cross-group mesh whispers.
function Mesh.BroadcastTimer(evt)
    if not Mesh.IsEnabled() then return end
    if evt and evt.dedupKey and Mesh.TimerSeen(evt.dedupKey) then return end
    local payload = encodeTimer(evt)
    if not payload then return end

    -- Local group/guild/yell broadcasts (originator only).
    local function localBlast(seqTag)
        local seq = Mesh._outSeq + 1
        local frame = Mesh.BuildFrame(OP.TIMER, payload, { seq = seq })
        if IsInGuild and IsInGuild() then
            Mesh.Enqueue(Protocol.PREFIX.TIMER, frame, { op = "timer", chatType = "GUILD" })
        end
        if IsInRaid and IsInRaid() then
            Mesh.Enqueue(Protocol.PREFIX.TIMER, frame, { op = "timer", chatType = "RAID" })
        elseif IsInGroup and IsInGroup() then
            Mesh.Enqueue(Protocol.PREFIX.TIMER, frame, { op = "timer", chatType = "PARTY" })
        end
        Mesh.Enqueue(Protocol.PREFIX.TIMER, frame, { op = "timer", chatType = "YELL" })
    end
    localBlast()

    -- Cross-group mesh whispers with relay assignment (dedup guards storms).
    local ids = onlinePeerIDs()
    local plan = Mesh.ComputeRelayPlan(ids, Mesh.DIRECT_BUDGET, ns:GetAccountID())
    local function whisper(aid, delegated)
        local name = Mesh.NameForAID(aid)
        if not name then return end
        local seq = Mesh._outSeq + 1
        local relayTo = delegated and buildRelayTo(delegated) or ""
        local frame = Mesh.BuildFrame(OP.TIMER, payload, { seq = seq, relayTo = relayTo })
        Mesh.Enqueue(Protocol.PREFIX.TIMER, frame, {
            op = "timer", chatType = "WHISPER", target = name, seq = seq,
        })
    end
    for i = 1, #plan.direct do whisper(plan.direct[i], plan.relays[plan.direct[i]]) end
    for i = 1, #plan.backups do whisper(plan.backups[i], nil) end
end

-- RECEIVER re-broadcast: party/raid/yell ONLY, never mesh whispers.
function Mesh.RebroadcastTimerLocal(payload)
    if not payload then return end
    local seq = Mesh._outSeq + 1
    local frame = Mesh.BuildFrame(OP.TIMER, payload, { seq = seq })
    if IsInRaid and IsInRaid() then
        Mesh.Enqueue(Protocol.PREFIX.TIMER, frame, { op = "timer", chatType = "RAID" })
    elseif IsInGroup and IsInGroup() then
        Mesh.Enqueue(Protocol.PREFIX.TIMER, frame, { op = "timer", chatType = "PARTY" })
    end
end

----------------------------------------------------------------------
-- Channel broadcast helper (discovery + heartbeats reach cross-guild peers)
----------------------------------------------------------------------

function Mesh.BroadcastChannel(prefix, frame, meta)
    meta = meta or {}
    local chanName = Mesh.GetChannelName()
    local idx = 0
    if chanName and GetChannelName then
        idx = GetChannelName(chanName) or 0
    end
    if idx and idx > 0 then
        meta.chatType = "CHANNEL"
        meta.target = tostring(idx)
        Mesh.Enqueue(prefix, frame, meta)
    else
        -- No channel available (not joined yet): fall back to guild so at least
        -- same-guild mesh members converge.
        if IsInGuild and IsInGuild() then
            meta.chatType = "GUILD"
            meta.target = nil
            Mesh.Enqueue(prefix, frame, meta)
        end
    end
end

----------------------------------------------------------------------
-- Logout flush (final state push, most-recently-seen peer first, wide budget)
----------------------------------------------------------------------

function Mesh.LogoutFlush()
    if not Mesh.IsEnabled() then return end
    local nameRealm = selfNameRealm()
    local rec = Store.GetCharacter and Store.GetCharacter(nameRealm)
    if not rec then return end
    local payload = Protocol.EncodeCharacter(rec)

    -- Order peers by most-recently-seen first.
    local ordered = {}
    for aid, p in pairs(Mesh.peers) do
        if p.online and p.name then ordered[#ordered + 1] = p end
    end
    table.sort(ordered, function(a, b)
        return (a.lastSeen or 0) > (b.lastSeen or 0)
    end)

    -- Expanded budget on logout: whisper ALL peers directly, most-recent first.
    for i = 1, #ordered do
        local seq = Mesh._outSeq + 1
        local frame = Mesh.BuildFrame(OP.STATE, payload, { seq = seq, relayTo = "" })
        Mesh.Enqueue(Protocol.PREFIX.STATE, frame, {
            op = "state", chatType = "WHISPER", target = ordered[i].name, seq = seq,
        })
    end
    -- Drain synchronously-ish: the client flushes the addon-message queue on
    -- logout, so enqueuing is sufficient; we bump the buckets so the first
    -- several go out immediately.
    local s = Mesh._sched[Protocol.PREFIX.STATE]
    if s then s.bucket.tokens = s.bucket.cap end
    Mesh.DrainTick(now())
end

----------------------------------------------------------------------
-- Channel membership lifecycle
--
-- The discovery channel is what lets cross-guild / unguilded mesh accounts
-- find each other: heartbeats + discovery pings ride it (see BroadcastChannel).
-- The catch is timing — JoinTemporaryChannel silently no-ops in the first few
-- seconds after login/reload (the chat system isn't ready), so a one-shot join
-- at PLAYER_LOGIN leaves GetChannelName() == 0 forever and every broadcast
-- falls back to GUILD-only. So we drive the join through a small retry state
-- machine: issue the join, verify via GetChannelName on a widening backoff, and
-- only stop once the index resolves (or we exhaust JOIN_MAX_TRIES).
--
-- The state machine core (NewJoinState + JoinAdvance) is PURE: every game/timer
-- call is injected through `deps`, so it is exercised headless by the self-test.
----------------------------------------------------------------------

-- Fresh join-state for a channel name.
function Mesh.NewJoinState(chanName)
    return {
        chanName     = chanName,
        attempts     = 0,       -- JoinTemporaryChannel calls issued so far
        index        = 0,       -- resolved channel index (0 == not joined)
        joined       = false,
        gaveUp       = false,
        pingedOnJoin = false,
    }
end

-- Advance the join state one tick. Pure: deps = {
--   getIndex = function(chanName) -> number   (GetChannelName wrapper),
--   doJoin   = function(chanName)             (JoinTemporaryChannel wrapper),
--   maxTries = number, delays = { seconds, ... },
-- }
-- Returns an action string plus (for "retry") the delay to the next tick:
--   "joined"  -- index resolved; caller should announce on the channel
--   "retry"   -- join (re)issued; re-check after the returned delay
--   "gaveup"  -- exhausted attempts; guild fallback continues to carry peers
--   "noop"    -- already joined or already gave up
function Mesh.JoinAdvance(st, deps)
    if st.joined or st.gaveUp then return "noop" end
    local idx = deps.getIndex(st.chanName) or 0
    if idx > 0 then
        st.index  = idx
        st.joined = true
        return "joined"
    end
    local maxTries = deps.maxTries or Mesh.JOIN_MAX_TRIES
    if st.attempts >= maxTries then
        st.gaveUp = true
        return "gaveup"
    end
    -- Issue (or re-issue) the join. Re-joining an already-joined channel is
    -- harmless — JoinTemporaryChannel just returns the existing index — so this
    -- is also the /reload-safe path.
    deps.doJoin(st.chanName)
    st.attempts = st.attempts + 1
    local delays = deps.delays or Mesh.JOIN_DELAYS
    local delay  = delays[st.attempts] or delays[#delays] or 5
    return "retry", delay
end

-- Impure wrappers around the two game APIs (verified in the API catalog:
-- GetChannelName / JoinTemporaryChannel are FrameXML globals on this client).
local function getChannelIndex(chanName)
    if chanName and GetChannelName then
        return GetChannelName(chanName) or 0
    end
    return 0
end
local function doJoinChannel(chanName)
    if JoinTemporaryChannel then JoinTemporaryChannel(chanName) end
end

-- Announce ourselves once the channel index first resolves so peers already on
-- the channel (and we, to them) converge immediately rather than waiting for the
-- next 17-23s heartbeat.
function Mesh.OnChannelResolved()
    ns:SafeCall(Mesh.SendDiscovery, OP.PING, nil)
end

-- One tick of the live join loop: advance the state, then schedule the next
-- verification (retry) or fire discovery (joined). `gen` fences the loop so a
-- newer StartJoinSequence (relog / reload / re-enable) cancels stale timers
-- instead of compounding parallel tickers.
function Mesh._runJoinTick(gen)
    if gen ~= Mesh._joinGen then return end   -- superseded by a newer sequence
    local st = Mesh._joinState
    if not st then return end
    local deps = {
        getIndex = getChannelIndex,
        doJoin   = doJoinChannel,
        maxTries = Mesh.JOIN_MAX_TRIES,
        delays   = Mesh.JOIN_DELAYS,
    }
    local action, delay = Mesh.JoinAdvance(st, deps)
    if action == "joined" then
        if not st.pingedOnJoin then
            st.pingedOnJoin = true
            Mesh.OnChannelResolved()
        end
    elseif action == "retry" then
        if C_Timer and C_Timer.After then
            C_Timer.After(delay or 5, function() ns:SafeCall(Mesh._runJoinTick, gen) end)
        end
    end
    -- "gaveup"/"noop": stop the loop. BroadcastChannel's GUILD fallback keeps
    -- same-guild peers converging even without the channel.
end

-- Start (or restart) the join sequence. Idempotent per PLAYER_ENTERING_WORLD:
-- if we are already on the channel (e.g. after /reload) we skip the retry loop
-- and just re-announce; otherwise we kick off a fresh retry sequence. Bumping
-- the generation token retires any retry loop still in flight.
function Mesh.StartJoinSequence()
    if not Mesh.IsEnabled() then return end
    local chanName = Mesh.GetChannelName()
    if not chanName then return end
    Mesh._joinGen = Mesh._joinGen + 1
    if getChannelIndex(chanName) > 0 then
        local st = Mesh.NewJoinState(chanName)
        st.index, st.joined, st.pingedOnJoin = getChannelIndex(chanName), true, true
        Mesh._joinState = st
        Mesh.OnChannelResolved()
        return
    end
    Mesh._joinState = Mesh.NewJoinState(chanName)
    Mesh._runJoinTick(Mesh._joinGen)
end

-- Backwards-compatible one-shot entry (kept for callers/tests); the retry loop
-- is the real path now.
function Mesh.JoinMeshChannel()
    Mesh.StartJoinSequence()
end

-- Leave OUR discovery channel unconditionally on mesh disable / logout. The
-- settings' autoLeaveChannel flag governs the spec'd standard/bond auto-leave
-- list — it does NOT gate teardown of our own mesh channel.
function Mesh.LeaveMeshChannel()
    local chanName = Mesh.GetChannelName()
    if not chanName then return end
    if LeaveChannelByName then
        LeaveChannelByName(chanName)
    end
    Mesh._joinState = nil
    Mesh._joinGen = Mesh._joinGen + 1   -- retire any in-flight retry loop
end

-- Mesh turned off at runtime: leave the channel and halt the join loop.
function Mesh.OnDisable()
    Mesh.LeaveMeshChannel()
end

-- Fired on PLAYER_ENTERING_WORLD (initial login AND every /reload): (re)drive
-- the join. Guarded so a disabled mesh stays dormant.
function Mesh.OnEnteringWorld(isInitialLogin, isReloadingUi)
    if not Mesh.IsEnabled() then return end
    Mesh.StartJoinSequence()
end

-- CHAT_MSG_CHANNEL_JOIN handler: when a peer joins our discovery channel, emit
-- a throttled discovery ping so late arrivals converge fast instead of waiting a
-- full heartbeat cycle. Ignores our own join and joins on unrelated channels.
function Mesh.OnChannelJoinNotice(playerName, channelBaseName)
    if not Mesh.IsEnabled() then return end
    local chanName = Mesh.GetChannelName()
    if not chanName then return end
    local base = channelBaseName and tostring(channelBaseName):lower() or ""
    if base == "" or base ~= chanName:lower() then return end
    if playerName and Mesh.IsSelfSender(playerName) then return end
    local t = now()
    if t - (Mesh._lastJoinPing or 0) < Mesh.JOIN_PING_THROTTLE then return end
    Mesh._lastJoinPing = t
    ns:SafeCall(Mesh.SendDiscovery, OP.PING, nil)
end

----------------------------------------------------------------------
-- Event wiring / lifecycle
----------------------------------------------------------------------

local function onChatMsgAddon(event, prefix, text, channel, sender)
    -- Only our prefixes.
    local ours = false
    for i = 1, #Protocol.PREFIX_LIST do
        if Protocol.PREFIX_LIST[i] == prefix then ours = true break end
    end
    if not ours then return end
    if not Mesh.IsEnabled() then return end
    -- Ignore our own echoes (guild/raid/yell/channel broadcasts loop back). The
    -- `channel` origin arg is NOT filtered here: CHANNEL-distributed addon
    -- messages arrive with channel="CHANNEL" and are dispatched like any other.
    if Mesh.IsSelfSender(sender) then return end
    -- De-envelope, reassemble, then dispatch.
    local env = Mesh.DeEnvelope(text)
    if not env then return end
    local frame = Mesh.FeedChunk(sender, prefix, env, now())
    if frame then
        ns:SafeCall(Mesh.Dispatch, prefix, frame, sender)
    end
end

function Mesh.OnLogin()
    -- Randomise the session id so message ids don't collide across relogs.
    Mesh._sessionId = (math.random and math.random(1, 16777216)) or 1

    -- Subscribe to inbound addon messages.
    ns:RegisterEvent("CHAT_MSG_ADDON", onChatMsgAddon)

    -- PLAYER_ENTERING_WORLD drives the channel join (fires on initial login AND
    -- every /reload; the handler self-guards on IsEnabled). This is the fix for
    -- the "no peers known" bug: a one-shot join at login lands before the chat
    -- system is ready, so we (re)drive a verified retry loop here instead.
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function(_, isInitialLogin, isReloadingUi)
        ns:SafeCall(Mesh.OnEnteringWorld, isInitialLogin, isReloadingUi)
    end)

    -- Newcomer convergence: ping when someone joins our discovery channel.
    -- CHAT_MSG_CHANNEL_JOIN args (1-indexed): text, playerName(2), languageName,
    -- channelName, playerName2, specialFlags, zoneChannelID, channelIndex,
    -- channelBaseName(9).
    ns:RegisterEvent("CHAT_MSG_CHANNEL_JOIN", function(_, ...)
        local playerName      = select(2, ...)
        local channelBaseName = select(9, ...)
        ns:SafeCall(Mesh.OnChannelJoinNotice, playerName, channelBaseName)
    end)

    -- Push live state changes onto the mesh.
    ns:On("STATE_CHANGED", function(nameRealm, record)
        ns:SafeCall(Mesh.PushState, nameRealm, record)
    end)

    -- Final flush on the way out.
    ns:On("LOGOUT", function()
        ns:SafeCall(Mesh.LogoutFlush)
        ns:SafeCall(Mesh.LeaveMeshChannel)
    end)

    if not Mesh.IsEnabled() then
        return   -- mesh disabled / no token / no account id: stay dormant
    end

    -- Kick the join sequence immediately too (idempotent with the PEW path via
    -- the generation token) so we don't wait on a possibly-already-fired PEW.
    Mesh.StartJoinSequence()

    -- Start the 50ms drain ticker.
    if C_Timer and C_Timer.NewTicker then
        Mesh._drainTicker = C_Timer.NewTicker(Mesh.DRAIN_INTERVAL, function()
            ns:SafeCall(Mesh.DrainTick, now())
        end)
    end

    -- Heartbeat loop with 17-23s jitter (reschedules itself).
    local function scheduleHeartbeat()
        local jitter = (math.random and (math.random() * 2 - 1) or 0) * Mesh.HB_JITTER
        local delay = Mesh.HB_BASE + jitter
        if C_Timer and C_Timer.After then
            C_Timer.After(delay, function()
                ns:SafeCall(Mesh.SendHeartbeat)
                scheduleHeartbeat()
            end)
        end
    end
    scheduleHeartbeat()
end

----------------------------------------------------------------------
-- Debug: /dsn debug mesh (peer table, queue depths, bucket levels)
----------------------------------------------------------------------

local function debugMesh()
    ns:Print("mesh: " .. (Mesh.IsEnabled() and "ENABLED" or "disabled")
        .. " | account " .. (ns:GetAccountID() ~= "" and ns:GetAccountID() or "<unset>"))

    -- Channel join diagnostics — the heart of the "no peers known" smoke test.
    local chanName = Mesh.GetChannelName()
    local liveIdx = 0
    if chanName and GetChannelName then liveIdx = GetChannelName(chanName) or 0 end
    local st = Mesh._joinState
    local joinedStr = (liveIdx and liveIdx > 0) and ("index " .. liveIdx) or "NOT JOINED"
    local attempts = st and st.attempts or 0
    local status = ""
    if st and st.gaveUp then status = " (gave up)"
    elseif st and st.joined then status = " (joined)"
    elseif attempts > 0 then status = " (joining)" end
    ns:Print(string.format("  channel: %s | %s | joinAttempts=%d%s",
        chanName or "<none>", joinedStr, attempts, status))

    -- Discovery ping/pong telemetry (0 == never).
    local d = Mesh._disco or {}
    ns:Print(string.format("  discovery: pingSent=%s pongRecv=%s pingRecv=%s pongSent=%s",
        tostring(d.lastPingSent or 0), tostring(d.lastPongRecv or 0),
        tostring(d.lastPingRecv or 0), tostring(d.lastPongSent or 0)))

    local n = 0
    for aid, p in pairs(Mesh.peers) do
        n = n + 1
        ns:Print(string.format("  peer %s (%s) online=%s lastSeen=%s",
            aid, p.name or "?", tostring(p.online), tostring(p.lastSeen or 0)))
    end
    if n == 0 then ns:Print("  no peers known.") end
    for prefix, s in pairs(Mesh._sched) do
        ns:Print(string.format("  prefix %s: queue=%d bucket=%.1f/%d",
            prefix, s.queue:Size(), s.bucket.tokens, s.bucket.cap))
    end
    local seen = 0
    for _ in pairs(Mesh._seenIds) do seen = seen + 1 end
    ns:Print("  dedup entries: " .. seen)
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; registered into /dsn debug selftest)
----------------------------------------------------------------------

local function testRelayPlan()
    -- 6 peers, budget 4: 4 direct, 2 delegated round-robin to first two.
    local peers = { "5", "2", "9", "3", "7", "1" }   -- unsorted on purpose
    local plan = Mesh.ComputeRelayPlan(peers, 4, "8")
    -- sorted ascending numeric: 1,2,3,5,7,9 ; direct = 1,2,3,5
    local expectDirect = { "1", "2", "3", "5" }
    for i = 1, 4 do
        if plan.direct[i] ~= expectDirect[i] then
            return false, "direct[" .. i .. "]=" .. tostring(plan.direct[i])
        end
    end
    -- overflow 7,9 -> delegated to direct[1]=1 then direct[2]=2
    if not (plan.relays["1"] and plan.relays["1"][1] == "7") then
        return false, "expected 7 delegated to peer 1"
    end
    if not (plan.relays["2"] and plan.relays["2"][1] == "9") then
        return false, "expected 9 delegated to peer 2"
    end
    -- backups = top(1) + bottom(9)
    if plan.backups[1] ~= "1" or plan.backups[2] ~= "9" then
        return false, "backups wrong: " .. tostring(plan.backups[1]) .. "," .. tostring(plan.backups[2])
    end
    -- self excluded
    local plan2 = Mesh.ComputeRelayPlan({ "8", "3" }, 4, "8")
    if #plan2.direct ~= 1 or plan2.direct[1] ~= "3" then
        return false, "self not excluded"
    end
    return true
end

local function testHashDiff()
    local a = { segments = { sixties = { "A-R", "B-R" }, summoners = {}, norole = {} } }
    local b = { segments = { sixties = { "A-R", "B-R" }, summoners = { "C-R" }, norole = {} } }
    local ha = Mesh.AccountHashes(a)
    local hb = Mesh.AccountHashes(b)
    local diffs = Mesh.DiffHashes(ha, hb)
    if #diffs ~= 1 or diffs[1] ~= "summoners" then
        return false, "expected only summoners to differ, got " .. table.concat(diffs, ",")
    end
    -- order-sensitivity: reordering a segment changes its hash
    local h1 = Mesh.HashSegment({ "A", "B", "C" })
    local h2 = Mesh.HashSegment({ "C", "B", "A" })
    if h1 == h2 then return false, "segment hash ignored order" end
    -- identical lists hash identical
    if Mesh.HashSegment({ "A", "B" }) ~= Mesh.HashSegment({ "A", "B" }) then
        return false, "identical segments hashed differently"
    end
    return true
end

local function testDedupWindow()
    -- fresh id at t=100 -> not seen; again at t=150 (within 120) -> seen;
    -- again at t=100+121 -> expired -> not seen.
    Mesh._seenIds = {}
    if Mesh.SeenBefore("acct-x", 100) then return false, "first sighting flagged seen" end
    if not Mesh.SeenBefore("acct-x", 150) then return false, "within window not deduped" end
    if Mesh.SeenBefore("acct-x", 100 + Mesh.DEDUP_WINDOW + 1) then
        return false, "expired id still deduped"
    end
    -- timer dedup on buff:yell:epoch
    Mesh._timerSeen = {}
    if Mesh.TimerSeen("rend:2:1785000000", 10) then return false, "first timer flagged seen" end
    if not Mesh.TimerSeen("rend:2:1785000000", 20) then return false, "timer dup not caught" end
    return true
end

local function testFrameRoundTrip()
    -- Build a frame, chunk it, envelope, de-envelope, reassemble, parse.
    local payload = string.rep("XY", 300)   -- 600 bytes -> multi-chunk
    local frame = Mesh.BuildFrame(Mesh.OP.STATE, payload, { seq = 42, relayTo = "Foo-Bar,3" })
    local chunks = Protocol.Chunk.Split(frame, 42, Mesh.CHUNK_DATA_MAX)
    if #chunks < 2 then return false, "expected multiple chunks" end
    Mesh._reasm = {}
    local rebuilt
    for i = 1, #chunks do
        local wire = Mesh.EnvelopeChunk(chunks[i])
        local env = Mesh.DeEnvelope(wire)
        if not env then return false, "de-envelope failed at chunk " .. i end
        rebuilt = Mesh.FeedChunk("Sender-Realm", Protocol.PREFIX.STATE, env, 0)
    end
    if rebuilt ~= frame then return false, "reassembled frame differs" end
    local f = Mesh.ParseFrame(rebuilt)
    if not f then return false, "parse failed" end
    if f.op ~= Mesh.OP.STATE then return false, "op lost" end
    if f.seq ~= "42" then return false, "seq lost: " .. tostring(f.seq) end
    if f.relayTo ~= "Foo-Bar,3" then return false, "relayTo lost: " .. tostring(f.relayTo) end
    if f.payload ~= payload then return false, "payload corrupted" end
    -- version rejection
    local bad = "9" .. frame:sub(2)
    local pf, reason = Mesh.ParseFrame(bad)
    if pf ~= nil then return false, "bad version accepted" end
    return true
end

local function testFreshSeq()
    Mesh._inSeq = {}
    if not Mesh.FreshSeq("S", 5) then return false, "first seq rejected" end
    if Mesh.FreshSeq("S", 5) then return false, "duplicate seq accepted" end
    if Mesh.FreshSeq("S", 4) then return false, "stale seq accepted" end
    if not Mesh.FreshSeq("S", 6) then return false, "newer seq rejected" end
    if not Mesh.FreshSeq("S", 0) then return false, "unsequenced op rejected" end
    return true
end

local function testFailureSkip()
    Mesh._fail = {}
    for _ = 1, Mesh.FAIL_SKIP_COUNT do Mesh.NoteFailure("T", 1000) end
    if not Mesh.TargetSkipped("T", 1001) then return false, "target not skipped after fails" end
    if Mesh.TargetSkipped("T", 1000 + Mesh.FAIL_SKIP_TIME + 1) then
        return false, "skip did not expire"
    end
    return true
end

-- Join-retry state machine: every game/timer call is injected, so the whole
-- machine runs headless here. Covers immediate-resolve (/reload), resolve-after-
-- retries, give-up-after-max, backoff-delay sequencing, and post-terminal inertness.
local function testJoinStateMachine()
    -- Build deps whose getIndex replays a scripted sequence of channel indices
    -- and whose doJoin counts issued joins. maxTries=3 keeps the tables small.
    local function makeDeps(indexSeq)
        local i, joins = 0, 0
        return {
            getIndex = function() i = i + 1; return indexSeq[i] or 0 end,
            doJoin   = function() joins = joins + 1 end,
            maxTries = 3,
            delays   = { 5, 7, 10 },
            _joins   = function() return joins end,
        }
    end

    -- 1. Already on the channel (e.g. after /reload): resolve on the first tick,
    --    no join issued.
    local st = Mesh.NewJoinState("dsnX")
    local deps = makeDeps({ 4 })
    local action = Mesh.JoinAdvance(st, deps)
    if action ~= "joined" then return false, "immediate: expected joined, got " .. tostring(action) end
    if st.index ~= 4 or not st.joined then return false, "immediate: index/joined not set" end
    if deps._joins() ~= 0 then return false, "immediate: should not issue join" end

    -- 2. Two failed verifications, then resolve; backoff delays honoured.
    st = Mesh.NewJoinState("dsnX")
    deps = makeDeps({ 0, 0, 9 })
    local a1, d1 = Mesh.JoinAdvance(st, deps)   -- idx 0 -> join#1, retry 5
    if a1 ~= "retry" or d1 ~= 5 then return false, "tick1: " .. tostring(a1) .. "/" .. tostring(d1) end
    local a2, d2 = Mesh.JoinAdvance(st, deps)   -- idx 0 -> join#2, retry 7
    if a2 ~= "retry" or d2 ~= 7 then return false, "tick2: " .. tostring(a2) .. "/" .. tostring(d2) end
    local a3 = Mesh.JoinAdvance(st, deps)        -- idx 9 -> joined
    if a3 ~= "joined" then return false, "tick3: expected joined, got " .. tostring(a3) end
    if st.index ~= 9 then return false, "resolved index wrong: " .. tostring(st.index) end
    if deps._joins() ~= 2 then return false, "expected 2 joins, got " .. tostring(deps._joins()) end

    -- 3. Never resolves -> give up after exactly maxTries join attempts.
    st = Mesh.NewJoinState("dsnX")
    deps = makeDeps({})   -- getIndex always 0
    local guard, act = 0, nil
    repeat
        act = Mesh.JoinAdvance(st, deps)
        guard = guard + 1
    until act == "gaveup" or guard > 20
    if act ~= "gaveup" then return false, "expected gaveup, got " .. tostring(act) end
    if st.attempts ~= 3 then return false, "expected 3 attempts, got " .. tostring(st.attempts) end
    if deps._joins() ~= 3 then return false, "expected 3 joins, got " .. tostring(deps._joins()) end
    if not st.gaveUp then return false, "gaveUp flag not set" end

    -- 4. Terminal states are inert.
    if Mesh.JoinAdvance(st, deps) ~= "noop" then return false, "post-giveup not noop" end
    local joinedSt = Mesh.NewJoinState("dsnX"); joinedSt.joined = true
    if Mesh.JoinAdvance(joinedSt, makeDeps({ 0 })) ~= "noop" then return false, "post-joined not noop" end

    -- 5. Backoff clamps to the last delay if attempts exceed the table length.
    local delays = { 5, 7 }
    st = Mesh.NewJoinState("dsnX")
    local dd = { getIndex = function() return 0 end, doJoin = function() end,
                 maxTries = 5, delays = delays }
    local _, db1 = Mesh.JoinAdvance(st, dd)   -- attempt1 -> delays[1]=5
    local _, db2 = Mesh.JoinAdvance(st, dd)   -- attempt2 -> delays[2]=7
    local _, db3 = Mesh.JoinAdvance(st, dd)   -- attempt3 -> clamp to 7
    if db1 ~= 5 or db2 ~= 7 or db3 ~= 7 then
        return false, "backoff clamp wrong: " .. tostring(db1) .. "," .. tostring(db2) .. "," .. tostring(db3)
    end

    return true
end

function Mesh.RunSelfTests(verbose)
    local suite = {
        { name = "relay assignment", fn = testRelayPlan },
        { name = "hash diff",        fn = testHashDiff },
        { name = "dedup window",     fn = testDedupWindow },
        { name = "frame round-trip", fn = testFrameRoundTrip },
        { name = "session seq",      fn = testFreshSeq },
        { name = "failure skip",     fn = testFailureSkip },
        { name = "join state machine", fn = testJoinStateMachine },
    }
    local allPass, results = true, {}
    for _, t in ipairs(suite) do
        local ok, why = t.fn()
        results[t.name] = { ok = ok, why = why }
        if not ok then allPass = false end
        if verbose and ns and ns.Print then
            if ok then ns:Print("  PASS mesh/" .. t.name)
            else ns:Print("  FAIL mesh/" .. t.name .. " :: " .. tostring(why)) end
        end
    end
    return allPass, results
end

----------------------------------------------------------------------
-- Registration (subcommand + selftest + debug hooks land at file load)
----------------------------------------------------------------------

if ns.RegisterDebugCommand then
    ns:RegisterDebugCommand("mesh", debugMesh)
end
if ns.RegisterSelfTest then
    ns:RegisterSelfTest("mesh", Mesh.RunSelfTests)
end

-- Register manual sync entry points as subcommands (parity with the spec's
-- "Send Settings to Mesh" / blacklist push; UI buttons call these in N3).
ns:RegisterSubcommand("syncsettings", function()
    if not Mesh.IsEnabled() then ns:Print("mesh is disabled.") return end
    Mesh.SyncSettings()
    ns:Print("settings sync sent to mesh peers.")
end, "push settings to the mesh")

-- Drive login wiring off the existing lifecycle hook.
ns:On("LOGIN", function()
    ns:SafeCall(Mesh.OnLogin)
end)
