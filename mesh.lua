-- Daseeki Nexus — mesh.lua  (WAVE N2a: MESH COMM LAYER)
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
Mesh.DIRECT_BUDGET   = 4            -- FLOOR for direct sends (A10.9: the live
                                    -- token count raises it, never lowers it)
Mesh.PEER_TIMEOUT    = 30           -- A1.3: roster entry expires after 30s silence
Mesh.PEER_SWEEP_INTERVAL = 5        -- A1.3: sweep cadence (spec §2.3)
Mesh.RELAY_MAX_AGE   = 10           -- A10.8: drop relays older than 10s (spec §9.4)
Mesh.CHUNK_DATA_MAX  = 230          -- payload bytes/chunk (255 - envelope room)

-- Logout presence hygiene (see §Logout flush).
--
-- ui_shell.lua's roster reads a remote character as ONLINE from two independent
-- sources: (1) live mesh presence — Mesh.peers[aid].online plus p.name — and,
-- when the mesh has nothing to say, (2) a lastSeen-recency fallback with a 15s
-- window. A logging-out character used to trip BOTH: its final STATE whisper
-- carried a lastSeen stamped microseconds earlier (fallback reads green for the
-- whole window), and any inbound frame from it re-flipped p.online true even
-- after the channel-leave notice had marked it stale (mesh presence reads green
-- until the 30s silence sweep). These two tunables kill both paths.
Mesh.PRESENCE_ONLINE_WINDOW = 15    -- MIRRORS ui_shell.lua ONLINE_WINDOW. Read-only
                                    -- here: mesh never sets the display policy, it
                                    -- only has to backdate PAST it. ui_shell pins
                                    -- its own value at 15 in its self-test.
Mesh.LOGOUT_LASTSEEN_BACKDATE = Mesh.PRESENCE_ONLINE_WINDOW + 1
                                    -- seconds to backdate the lastSeen we ENCODE in
                                    -- the logout flush, so the receiver's recency
                                    -- fallback is already expired when it lands
Mesh.PRESENCE_STALE_HOLD = 30       -- after a leave/logout latch, refuse to clear it
                                    -- from RAW inbound traffic for this long. Sized to
                                    -- PEER_TIMEOUT: past it the silence sweep owns the
                                    -- peer anyway. An identified frame (heartbeat /
                                    -- discovery -> NotePeer) still re-admits instantly,
                                    -- so a genuine relog re-greens without waiting.

-- A10.7 / spec §9.5 — per-target send cooldowns. Divergence detection fires on
-- EVERY heartbeat from EVERY peer, so an N-peer mesh with a churning hash could
-- re-send the same manifest/segment/timer payload to the same target several
-- times a second. These are the reference's numbers.
Mesh.MANIFEST_COOLDOWN   = 5    -- spec §9.5: "one manifest per target per 5 s"
Mesh.SEGMENT_COOLDOWN    = 60   -- spec §9.5: homeless/segment per account+target 60 s
Mesh.TIMERSYNC_COOLDOWN  = 30   -- spec §9.5: timer-state whisper per target 30 s
Mesh.SETTINGS_COOLDOWN   = 10   -- LOCAL (not spec): settings/blacklist are BUTTON-driven
                                -- and fan out to every peer, so mashing the button is
                                -- the only way to storm them. Modest per-target gate.
Mesh.SEND_COOLDOWN_PRUNE = 4    -- prune send-cooldown entries older than N x their window

-- Bookkeeping TTLs: the maps below are keyed by unbounded strings (sync ids,
-- sender names) and had no removal path at all.
Mesh.ACK_WAIT_TTL = 300         -- drop an un-ACKed settings sync after 5 min
Mesh.INSEQ_TTL    = 3600        -- drop a seq high-water for a non-peer after 1 h

-- B5 split-brain: two clients can both believe they are the guild broadcaster
-- (election races a roster change), and both then relay the SAME snapshot. A
-- small random defer plus same-payload cancellation makes the loser drop its
-- copy instead of doubling the guild traffic.
Mesh.BCAST_JITTER_MAX = 4       -- seconds; actual defer is uniform in [0, MAX]

-- Bucket cap / refill per prefix (spec: cap 8, refill 1/s).
Mesh.BUCKET_CAP    = 8
Mesh.BUCKET_REFILL = 1

-- Per-op token cost + max burst (spec op caps: relay <=3, sync/summoner <=5-6).
-- Cost is charged against the prefix bucket per send; MAX_BURST caps how many
-- of that op-class may drain consecutively before yielding the tick to others.
Mesh.OP_COST = {
    timer = 1, state = 1, heartbeat = 1, discovery = 1,
    relay = 1, sync = 1, settings = 1, ack = 1,
    nspayload = 1, nspush = 1, nsreq = 1,
}
Mesh.OP_MAX_BURST = { relay = 3, sync = 6, settings = 6, nspayload = 6, nspush = 4 }

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
    TIMER_SNAP = "n",   -- Nexus merged timer snapshot (request reply / broadcast)
    INSTANCES  = "i",   -- account instance-ledger sync (additive; see §Instances sync)
    NSPAYLOAD  = "y",   -- suite-namespace payload push (Daseeki.Sync v2, wave N5)
    NSREQ      = "u",   -- suite-namespace pull request (heartbeat rev-hash mismatch)
    LOGOUT     = "l",   -- ADDITIVE: "I am logging out" presence notice (empty payload).
                        -- IGNORE-SAFE ON OLD PEERS: Mesh.ParseFrame does not validate
                        -- the op field, and Mesh.Dispatch is an if/elseif chain with NO
                        -- else branch — an unrecognised op falls off the end silently
                        -- (no error, no print, no telemetry). A pre-LOGOUT build
                        -- therefore treats this exactly as it treats any other frame it
                        -- has no handler for: dedup it, stamp the sender's liveness,
                        -- drop it. Same PROTO_VERSION, same frame layout, no
                        -- SCHEMA_VERSION involvement (the payload is empty, so
                        -- protocol.lua is not on this path at all).
}
Mesh.OP = OP

-- Priority tiers (lower = served first). Keyed by the semantic op-name strings
-- carried in a queued item's meta.op (NOT the single-char wire codes).
-- `nspush` vs `nspayload`: SAME WIRE OP (OP.NSPAYLOAD), different urgency. A
-- fresh push of OUR OWN owner is one or two chunks and is what a peer's tooltip
-- is waiting on right now; a pull answer (Mesh.SendNamespace) is every owner we
-- hold — ~70 chunks for a real roster — and is pure backfill. They shared a
-- priority, so a gold change published a few seconds after login queued behind
-- the login-time backfill and, on the SYNC prefix's 1-msg/sec sustained drain,
-- could still be unsent minutes later. The op names are LOCAL SCHEDULER
-- METADATA only (meta.op never reaches the wire), so this is not a protocol
-- change and no peer can tell the difference.
local PRIO = {
    timer = 1, discovery = 2, ack = 2,
    state = 3, heartbeat = 3,
    relay = 4, sync = 4, nsreq = 4, nspush = 4,
    settings = 6, nspayload = 6,
}

-- Read accessor for the scheduling self-test (PRIO stays a file-local so no
-- caller can quietly re-rank the queue at runtime).
function Mesh.PRIO_FOR(op) return PRIO[op] end

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
--
-- `records` (optional, spec §9.6) is the account's nameRealm -> record map. When
-- supplied, each name is folded together with a COARSE CONTENT FINGERPRINT of
-- its record (Mesh.SegmentRecordFingerprint) instead of being hashed by name
-- alone.
--
-- WHY: hashing names only meant the heartbeat's segment hashes answered exactly
-- one question — "do we hold the same SET of characters?" — and nothing else.
-- Two accounts agreed on the hash while one of them held a copy of a character
-- that was hours out of date, so a STATE push that got dropped (a full token
-- bucket, a whisper lost to a zone change, a peer that was offline for the one
-- push that mattered) was never noticed and never healed. Folding the content in
-- makes a stale copy DIVERGE, which trips the segment resync that already
-- exists, is already rate-limited (Mesh.SEGMENT_COOLDOWN / MANIFEST_COOLDOWN,
-- per account+area+target) and already carries whole records.
--
-- Omitting `records` keeps the historic names-only behaviour, which is what the
-- pure list-ordering tests exercise.
function Mesh.HashSegment(list, records)
    if not list or #list == 0 then return "0" end
    if type(records) ~= "table" then
        return fnv1a(joinList(list, "\30"))
    end
    local parts = {}
    for i = 1, #list do
        local nameRealm = list[i]
        parts[i] = tostring(nameRealm) .. "\28"
            .. Mesh.SegmentRecordFingerprint(records[nameRealm])
    end
    return fnv1a(joinList(parts, "\30"))
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

-- Hash an account's instance ledger (the char->entries map) to a short id.
-- Instances are NOT character-segment records, so — like timers — they ride a
-- SEPARATE heartbeat hash field (instancesHash) and a dedicated sync area rather
-- than the AccountHashes segment bundle. Deterministic: nameRealm keys sorted,
-- each entry reduced to t:name:merged so a divergence in any of those trips a sync.
function Mesh.HashInstances(charMap)
    if not charMap then return "0" end
    local names = {}
    for nr in pairs(charMap) do names[#names + 1] = tostring(nr) end
    if #names == 0 then return "0" end
    table.sort(names)
    local parts = {}
    for i = 1, #names do
        local nr = names[i]
        parts[#parts + 1] = nr
        local crec = charMap[nr]
        local entries = (crec and crec.entries) or {}
        for j = 1, #entries do
            local e = entries[j]
            parts[#parts + 1] = tostring(e.t or 0) .. ":" .. tostring(e.name or "")
                .. ":" .. (e.merged and "1" or "0")
        end
    end
    return fnv1a(joinList(parts, "\30"))
end

----------------------------------------------------------------------
-- A10.1 — state-push CHANGE FILTER (spec §3.3 + §9.4)
--
-- THE bug this closes: Tracker.Capture fired STATE_CHANGED unconditionally at
-- the end of every capture, and capture is bound to UNIT_AURA / BAG_UPDATE_* /
-- resting / flags / XP. In a raid that is a continuous stream of full-state
-- whispers to N direct peers PLUS two backup relays, which saturates an
-- 8-token / 1-per-second bucket within seconds and starves the heartbeat behind
-- it. Starved heartbeats are exactly what makes live peers read OFFLINE.
--
-- The filter is a CONTENT hash of the record. Volatile bookkeeping is excluded
-- by construction — no message id, no lastSeen / lastDataUpdate / ownerEpoch —
-- so a capture that changed nothing but the clock hashes identical and is
-- dropped. Durations are COARSENED so a buff ticking down does not re-broadcast
-- every second:
--   * aura durations  DIV 60  (spec §3.3: "duration floor-divided by 60")
--   * cooldowns and raid lockouts DIV 300 (spec §9.6's 5-minute divisor).
--     The reference stores cooldown START EPOCHS (stable); we store REMAINING
--     seconds (A9.1, out of scope here), so the 5-minute divisor is the faithful
--     analogue — it is what stops a decaying hearthstone timer churning the hash.
--
-- OURS (documented divergence): `level` is in the digest. The reference's §3.3
-- list omits it, but a level-up must reach peers and it is a once-per-character
-- event, so it cannot churn. XP / rested XP are deliberately NOT in the digest:
-- they tick constantly while questing and would defeat the whole filter.
----------------------------------------------------------------------

Mesh.AURA_COARSE = 60    -- aura durations round to the minute
Mesh.CD_COARSE   = 300   -- cooldowns / lockouts round to 5 minutes

local function hashBool(v) return v and "1" or "0" end
local function hashCoarse(v, div)
    return tostring(math.floor((tonumber(v) or 0) / div))
end

-- PURE: the canonical digest INPUT for a character record. Exposed separately
-- from the hash so a failing test can print the two strings and diff them.
function Mesh.StateHashInput(rec)
    if type(rec) ~= "table" then return "" end
    local parts = {
        hashBool(rec.chronoboonActive),
        hashBool(rec.dmfInBoon),
        hashBool(rec.dmfCooldownActive),
        hashBool(rec.pvpFlagged),
        hashBool(rec.isResting),
        hashBool(rec.inInstance),
        hashBool(rec.soulstoneReady),
        tostring(rec.location or ""),
        tostring(rec.level or 0),
        tostring(rec.shardCount or 0),
        tostring(rec.boonCount or 0),
        hashCoarse(rec.hearthstoneCD, Mesh.CD_COARSE),
        hashCoarse(rec.itemCooldown, Mesh.CD_COARSE),
    }
    local keys = (Store and Store.RAID_KEYS) or {}
    for i = 1, #keys do
        local expiry = rec.raidLockouts and rec.raidLockouts[keys[i]]
        parts[#parts + 1] = hashCoarse(expiry, Mesh.CD_COARSE)
    end
    local auras = rec.auraStates or {}
    for i = 1, 10 do
        local a = auras[i]
        if a then
            parts[#parts + 1] = i .. ":" .. tostring(a.source or 0)
                .. ":" .. tostring(a.option or 0)
                .. ":" .. hashCoarse(a.duration, Mesh.AURA_COARSE)
        else
            parts[#parts + 1] = i .. ":-"
        end
    end
    return joinList(parts, "\31")
end

-- PURE: 8-hex content hash of a record, or nil for a non-record.
function Mesh.StateHash(rec)
    if type(rec) ~= "table" then return nil end
    return fnv1a(Mesh.StateHashInput(rec))
end

----------------------------------------------------------------------
-- SEGMENT CONTENT FINGERPRINT (spec §9.6) — the input to Mesh.HashSegment.
--
-- THE GOVERNING INVARIANT, and it is not optional:
--
--     every field in here must be (a) transmitted VERBATIM by the binary STATE
--     schema, and (b) already part of Mesh.StateHashInput.
--
-- (a) makes the owner's copy and our copy byte-identical, so equal data hashes
-- equal. (b) means any change that moves this fingerprint ALSO moves the push
-- filter's hash, so the owner pushes and the two sides re-converge. Break either
-- half and the hashes diverge on data that is actually in sync — which is a
-- permanent resync loop, not a one-off.
--
-- Coarsening (same divisors as the push filter, deliberately): aura durations
-- DIV 60, raid lockout expiries DIV 300. A buff ticking down inside its own
-- minute cannot churn the heartbeat.
--
-- EXCLUDED, each for a specific reason:
--
--   itemCooldown / hearthstoneCD   The ONE family of fields the RECEIVER
--     (the legacy remaining-seconds  rewrites. Store.AdoptWireCooldowns re-anchors
--      mirrors)                     them onto our clock at receive time, while
--                                   the owner refreshes its own on every capture.
--                                   Ours is frozen at last receipt, theirs keeps
--                                   moving, so they fall into different DIV-300
--                                   buckets purely with the passage of time —
--                                   guaranteed false divergence, worst on exactly
--                                   the parked characters this is meant to help.
--                                   The cooldown's meaningful transitions are
--                                   still covered, by the PRESENCE bits below.
--   chronoboonCDStart /             Derived, not transmitted: our epoch is the
--   hearthstoneCDStart              owner's plus transit, so a DIV-300 bucket
--                                   boundary can fall between them. Reduced to a
--                                   0/non-0 presence bit, which both sides always
--                                   agree on and which is what actually changes
--                                   when a cooldown starts or ends.
--   xp / xpMax / restedXP           On the wire, but deliberately NOT in
--                                   StateHashInput (they tick constantly while
--                                   questing and would defeat the push filter).
--                                   Including them here would diverge without any
--                                   push to re-converge. Fails invariant (b).
--   lastSeen / lastDataUpdate /     Pure clock. Volatile by definition.
--   ownerEpoch
--   attunements / dmfCooldown       Not in the binary schema. Fails invariant (a):
--   sub-fields                      a peer holding only STATE-pushed data would
--                                   never match one that got a segment.
----------------------------------------------------------------------
function Mesh.SegmentRecordFingerprint(rec)
    if type(rec) ~= "table" then return "-" end
    local parts = {
        hashBool(rec.chronoboonActive),
        hashBool(rec.dmfInBoon),
        hashBool(rec.dmfCooldownActive),
        hashBool(rec.pvpFlagged),
        hashBool(rec.isResting),
        hashBool(rec.inInstance),
        hashBool(rec.soulstoneReady),
        tostring(rec.classTag or ""),
        tostring(rec.faction or ""),
        tostring(rec.location or ""),
        tostring(rec.level or 0),
        tostring(rec.shardCount or 0),
        tostring(rec.boonCount or 0),
        -- Cooldown PRESENCE only (see the exclusion note above).
        hashBool((tonumber(rec.chronoboonCDStart) or 0) > 0),
        hashBool((tonumber(rec.hearthstoneCDStart) or 0) > 0),
    }
    local keys = (Store and Store.RAID_KEYS) or {}
    for i = 1, #keys do
        local expiry = rec.raidLockouts and rec.raidLockouts[keys[i]]
        parts[#parts + 1] = hashCoarse(expiry, Mesh.CD_COARSE)
    end
    local auras = rec.auraStates or {}
    for i = 1, 10 do
        local a = auras[i]
        if a then
            parts[#parts + 1] = i .. ":" .. tostring(a.source or 0)
                .. ":" .. tostring(a.option or 0)
                .. ":" .. hashCoarse(a.duration, Mesh.AURA_COARSE)
        else
            parts[#parts + 1] = i .. ":-"
        end
    end
    return joinList(parts, "\31")
end

-- A10.9 — PURE: direct-send budget from the LIVE state-prefix token count.
-- Spec §9.4: "whispers directly to as many targets as it has tokens for". We
-- keep DIRECT_BUDGET (4) as the FLOOR so a momentarily-drained bucket can never
-- delegate everything, and BUCKET_CAP as the ceiling.
function Mesh.DirectBudget(tokens)
    local n = math.floor(tonumber(tokens) or 0)
    if n < Mesh.DIRECT_BUDGET then n = Mesh.DIRECT_BUDGET end
    if n > Mesh.BUCKET_CAP then n = Mesh.BUCKET_CAP end
    return n
end

-- Compute the hash bundle we advertise for an account bucket.
-- Both sides compute this over the SAME account's data — the owner over its own
-- bucket in SendHeartbeat, the receiver over its local copy in handleHeartbeat —
-- so folding record content into the segment hashes (spec §9.6) makes a stale
-- local copy trip Mesh.DiffHashes and pull a fresh segment.
--
-- `homeless` stays a name-set hash: it is keyed by an unordered map rather than
-- an ordered segment list, and spec §9.6 scopes the fingerprint to segments.
function Mesh.AccountHashes(bucket)
    local seg  = bucket and bucket.segments or {}
    local recs = bucket and bucket.characters or nil
    return {
        sixties   = Mesh.HashSegment(seg.sixties, recs),
        summoners = Mesh.HashSegment(seg.summoners, recs),
        norole    = Mesh.HashSegment(seg.norole, recs),
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
Mesh._ackWaitAt = {}     -- [syncId] = ts the wait set was opened (TTL sweep)
Mesh._sessionId = 0      -- randomised at login to prefix message ids
Mesh._timerCodec = nil   -- N2b handoff codec (see §Timer handoff)
Mesh._timerHandler = nil -- N2b handoff receive callback
Mesh._nsPushPending = {} -- [nsKey.."\1"..ownerKey] = true while a debounced push is queued
Mesh._nsReqSeen = {}     -- [sender.."\1"..nsKey] = expiry (pull-request dedup)

-- Suite-namespace transport tunables (wave N5).
Mesh.NS_PUSH_DEBOUNCE = 3    -- seconds to coalesce rapid MarkDirty pushes
Mesh.NS_REQ_DEDUP     = 15   -- seconds to suppress repeated pull answers to a peer

-- Channel-join retry state machine + discovery telemetry (see §Channel join).
Mesh._joinState = nil    -- { chanName, attempts, index, joined, gaveUp, pingedOnJoin }
Mesh._joinGen   = 0      -- generation token: supersedes stale in-flight retry loops
Mesh._lastSeqStart = 0   -- ts of the last StartJoinSequence (health-check cooldown gate)
Mesh._lastJoinAttempt = 0 -- ts of the last real JoinTemporaryChannel call (debug telemetry)
Mesh._disco = {          -- last discovery ping/pong timestamps (for /dsn debug mesh)
    lastPingSent = 0, lastPingRecv = 0,
    lastPongSent = 0, lastPongRecv = 0,
}

-- Presence discovery state. The derived channel is a PRESENCE beacon only — on
-- this client CHANNEL distribution silently drops addon messages, so discovery
-- pings and heartbeats travel by WHISPER to members we learn from the channel
-- ROSTER and from CHAT_MSG_CHANNEL_JOIN/LEAVE notices (see §Presence roster).
Mesh._lastPeerSweep  = 0    -- ts of the last peer timeout sweep (A1.3)
Mesh._lastPush       = {}   -- [nameRealm] = { hash, peers } of the last push.
                            -- Keyed per character: IsSelfRecord admits ANY
                            -- character in our own bucket, so a single slot
                            -- could let two alts alias each other's hash.
Mesh._pushSuppressed = 0    -- telemetry: change-filter suppressions (debug)
Mesh._relayAgeDrops  = 0    -- telemetry: relays dropped by the 10s age gate
Mesh._pingCooldowns  = {}   -- [name] = ts we last whisper-pinged that name
Mesh._lastRosterSweep = 0   -- ts of the last full roster sweep (debug telemetry)
Mesh._sendCooldowns  = {}   -- [kind\1target(\1scope)] = ts of the last such send (A10.7)
Mesh._sendGated      = 0    -- telemetry: sends suppressed by a per-target cooldown

-- B5 guard state for the guild-broadcaster relay (see Mesh.BroadcastTimers).
Mesh._bcastPending    = nil -- { hash = <payload hash>, at = ts } while a defer is armed
Mesh._bcastCancelled  = 0   -- telemetry: deferred broadcasts dropped as duplicates

-- Join-retry tunables: verify GetChannelName after each attempt on a backoff.
-- Channel joins routinely fail in the first seconds after login, so we issue
-- the join, then re-check on a widening schedule up to JOIN_MAX_TRIES times.
Mesh.JOIN_DELAYS     = { 5, 7, 10, 15, 22 }   -- seconds between verification ticks
Mesh.JOIN_MAX_TRIES  = 5                       -- max join calls before giving up
-- Presence-discovery cadence + anti-storm throttles.
Mesh.ROSTER_SWEEP_INTERVAL = 60   -- min seconds between full roster ping sweeps
Mesh.ROSTER_PING_COOLDOWN  = 30   -- per-name min seconds between whisper pings
Mesh.ROSTER_SCAN_CAP       = 100  -- hard cap on roster indices scanned per sweep
-- Never trust a single membership snapshot. After a tick resolves to "joined"
-- we re-check the LIVE index once more, JOIN_REVERIFY_DELAY seconds later: a
-- /reload briefly reports the PRE-reload channel membership, then drops the
-- temporary channel as the world finalises, so the first snapshot lies. If the
-- re-check finds the index gone we restart a fresh sequence. The heartbeat
-- health check is the continuous backstop against ANY later drop (kick, zone,
-- latency); JOIN_HEALTH_COOLDOWN caps how often it may re-kick a join.
Mesh.JOIN_REVERIFY_DELAY  = 10                 -- s after "joined" to re-verify the live index
Mesh.JOIN_HEALTH_COOLDOWN = 30                 -- min s between health-check-driven rejoins

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

----------------------------------------------------------------------
-- CANONICAL PEER NAMES
--
-- `Mesh.peers[aid].name` is not just a debug label: Dashboard.MeshPresence
-- (ui_shell.lua) publishes it as { [accountID] = nameRealm } and the roster
-- exclusivity pass matches it against the Name-Realm KEYS of the character
-- records. So a peer whose stored name is the bare "Erro" can never match the
-- record "Erro-Whitemane" — that account wins nothing, every one of its
-- characters renders OFFLINE, and its buff durations freeze on screen.
--
-- The NotePeer call sites used to feed the RAW CHAT_MSG_ADDON sender straight
-- in. That field is bare for some paths (the IsSelfSender comment above
-- documents exactly that) while the discovery and heartbeat payloads were
-- already carrying the sender's own canonical Name-Realm — and we threw it away.
--
-- So: prefer the payload's self-declared name, fall back to normalizing the
-- transport sender. The payload is only trusted when its SHORT name agrees with
-- the sender, which is the one thing the transport can vouch for — a peer cannot
-- use its own heartbeat to claim to be somebody else.
----------------------------------------------------------------------

-- Our own realm, whitespace-stripped, exactly as selfNameRealm builds it.
local function selfRealm()
    local realm = (GetRealmName and GetRealmName()) or ""
    return (realm:gsub("%s+", ""))
end
Mesh.SelfRealm = selfRealm

-- PURE-ish: a bare "Name" becomes "Name-<our realm>". Anything already carrying
-- a realm (or arriving when we cannot resolve our own realm) is returned as-is.
-- Character names cannot contain a hyphen in WoW, so the first "-" is always the
-- name/realm separator.
function Mesh.NormalizeSender(sender)
    if type(sender) ~= "string" or sender == "" then return nil end
    if sender:find("-", 1, true) then return sender end
    local realm = selfRealm()
    if realm == "" then return sender end
    return sender .. "-" .. realm
end

-- PURE-ish: the name to store for a peer, given the transport sender and the
-- canonical name its payload advertised (discovery `d.name`, heartbeat
-- `hb.online[1]`). `payloadName` may be nil — manifests carry no name field.
function Mesh.CanonicalPeerName(sender, payloadName)
    local norm = Mesh.NormalizeSender(sender)
    if type(payloadName) == "string" and payloadName ~= ""
       and payloadName:find("-", 1, true) then
        if norm == nil then return payloadName end       -- no sender to check against
        local claimed = payloadName:match("^([^%-]+)")
        local actual  = norm:match("^([^%-]+)")
        if claimed and actual and claimed == actual then
            return payloadName                            -- agrees with the sender
        end
    end
    return norm
end

-- Does this peer entry refer to `name`? Compared CANONICALLY, so a bare sender
-- and its Name-Realm form are recognised as the same peer. Required now that
-- p.name is canonical: CHAT_MSG_CHANNEL_LEAVE hands us a bare player name, and
-- a raw `p.name == name` test would silently stop latching peers offline.
function Mesh.PeerNameMatches(p, name)
    if type(p) ~= "table" then return false end
    local pn = p.name
    if type(pn) ~= "string" or pn == "" then return false end
    if type(name) ~= "string" or name == "" then return false end
    if pn == name then return true end
    return Mesh.NormalizeSender(pn) == Mesh.NormalizeSender(name)
end

function Mesh.MeshSettings()
    local db = Store and Store.GetSettings and Store.GetSettings()
    return db and db.mesh or nil
end

-- Channel-name validation (item 38): the reference requires a user-set channel
-- name of 16+ ALPHANUMERIC characters, case-sensitive. Only surrounding
-- whitespace is trimmed (never internal — the credential must match exactly
-- across accounts, so we do not silently rewrite it). Any internal non-alnum
-- character (incl. a space) rejects the name. Returns the trimmed name or nil.
function Mesh.ValidateChannel(raw)
    if type(raw) ~= "string" then return nil end
    local name = raw:gsub("^%s+", ""):gsub("%s+$", "")
    if #name < 16 then return nil end
    if name:find("[^%w]") then return nil end   -- alphanumeric only (no spaces)
    return name
end

-- Why the mesh is currently down (item 20/38 diagnostics). Returns nil when
-- fully enabled, else a short human reason string for /nexus debug mesh.
function Mesh.DisabledReason()
    local m = Mesh.MeshSettings()
    if not m then return "settings not loaded" end
    if m.optOut then return "opted out" end
    if not m.enabled then return "mesh disabled in settings" end
    if not m.token or m.token == "" then return "token not set" end
    if not Mesh.ValidateChannel(m.channel) then return "channel not set (need 16+ alphanumeric)" end
    local aid = ns:GetAccountID()
    if aid == "" or not ns:IsValidAccountID(aid) then return "account ID not set" end
    return nil
end

-- Mesh is live only with a token, a VALID channel, enabled, not opted out, and a
-- valid AID. The channel is now a REQUIRED user-set credential (item 38): there
-- is no token-derived fallback — accounts must match on BOTH channel + token.
function Mesh.IsEnabled()
    return Mesh.DisabledReason() == nil
end

-- User-set discovery channel name (item 38). No token derivation: returns the
-- validated mesh.channel or nil. Join/health-check logic re-reads this unchanged.
function Mesh.GetChannelName()
    local m = Mesh.MeshSettings()
    if not m then return nil end
    return Mesh.ValidateChannel(m.channel)
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
    -- A peer that answers again clears both offline latches (timeout sweep and
    -- channel-leave notice), exactly as the reference re-admits on any inbound.
    --
    -- NotePeer is only reached from an IDENTIFIED frame — one carrying an account
    -- ID (heartbeat / discovery / manifest). A logging-out client does not emit
    -- those after its leave notice, but a client that logged back IN emits them
    -- immediately, so this path deliberately ignores PRESENCE_STALE_HOLD: a real
    -- relog re-greens at once. The hold lives on the UNidentified raw-receive path
    -- (TouchPeerByName), which is the one the logout flush trips.
    p.timedOut = nil
    p.presenceStale = nil
    p.presenceStaleAt = nil
    return p
end

----------------------------------------------------------------------
-- A1.3 — peer timeout sweep (spec §2.3)
--
-- Before this, `online` was set TRUE in NotePeer and set FALSE in exactly one
-- place: a CHAT_MSG_CHANNEL_LEAVE notice. A peer that crashed, disconnected or
-- lost the channel without a leave notice reaching us stayed "online" FOREVER,
-- so we kept whispering state at a dead target — burning token budget and
-- racking up the 5-failure skip. The reference expires a roster entry after 30s
-- of silence on a 5s sweep; this is that sweep.
----------------------------------------------------------------------

-- PURE (given a peers table + a clock): mark every peer silent for longer than
-- PEER_TIMEOUT offline. Returns the number newly marked.
function Mesh.SweepPeers(t, peers)
    t = t or (Store and Store.Now and Store.Now()) or 0
    peers = peers or Mesh.peers
    local marked = 0
    for _, p in pairs(peers) do
        if type(p) == "table" and p.online
           and (t - (p.lastSeen or 0)) > Mesh.PEER_TIMEOUT then
            p.online = false
            p.timedOut = true
            marked = marked + 1
        end
    end
    return marked
end

-- Spec §2.2: ANY inbound mesh message refreshes the sender's roster timestamp,
-- *before* payload validation. Only heartbeat / discovery / manifest carried an
-- account ID and therefore reached NotePeer, so a peer that was mid-burst on the
-- STATE or SYNC prefix contributed nothing to its own liveness. That was
-- harmless while nothing ever expired a peer — with the 30s sweep above it is
-- not, so every raw receive now stamps a KNOWN peer by name. (Admitting an
-- UNKNOWN sender still requires an account ID; discovery handles that.)
--
-- ...with ONE exception, added with the logout-pip fix. "Evidence of life
-- outranks a stale latch" is only true when the evidence is NEWER than the
-- latch, and on the logout path it is not: LogoutFlush whispers a fan of final
-- STATE frames at the very moment the client drops the presence channel, so
-- those frames routinely LAND AFTER the channel-leave notice that marked the
-- peer stale. Re-greening on them repainted the pip for the rest of the
-- PEER_TIMEOUT window for a character that is provably gone. So a latch set
-- within the last PRESENCE_STALE_HOLD seconds REFUSES to be cleared by raw
-- inbound traffic. Liveness is still stamped (lastSeen is honest data and drives
-- the "seen Ns ago" column); only the online flip is withheld.
function Mesh.StaleLatchHolds(p, t)
    if not p or not p.presenceStale then return false end
    local at = p.presenceStaleAt
    if not at then return false end   -- legacy latch with no stamp: no hold
    return (t - at) < (Mesh.PRESENCE_STALE_HOLD or 0)
end

function Mesh.TouchPeerByName(name, t)
    if not name or name == "" then return nil end
    t = t or (Store and Store.Now and Store.Now()) or 0
    for _, p in pairs(Mesh.peers) do
        if Mesh.PeerNameMatches(p, name) then
            p.lastSeen = t
            if Mesh.StaleLatchHolds(p, t) then
                -- In-flight residue from a peer that just announced it is going
                -- away. Keep the liveness stamp, keep the latch.
                return p
            end
            p.online = true          -- evidence of life outranks a stale latch
            p.timedOut = nil
            p.presenceStale = nil
            p.presenceStaleAt = nil
            return p
        end
    end
    return nil
end

-- Cadence gate for the drain ticker: sweep at most once per PEER_SWEEP_INTERVAL.
function Mesh.MaybeSweepPeers(t)
    t = t or (Store and Store.Now and Store.Now()) or 0
    if (t - (Mesh._lastPeerSweep or 0)) < Mesh.PEER_SWEEP_INTERVAL then return 0 end
    Mesh._lastPeerSweep = t
    return Mesh.SweepPeers(t)
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

-- TTL sweep for the settings/blacklist ACK wait sets.
--
-- _ackWait[syncId] is opened by SyncSettings and emptied one target at a time by
-- handleAck. A peer that never answers (crashed, dropped the whisper, dropped the
-- chunked payload) left its target key — and therefore the whole parent entry —
-- in the table for the rest of the session. handleAck now drops the parent as
-- soon as its member set empties; this is the backstop for the sets that NEVER
-- empty. `_ackWaitAt` carries the open time; an entry with no stamp (defensively:
-- one opened by some other path) is stamped on first sight rather than dropped,
-- so it gets a full TTL rather than being nuked mid-flight.
function Mesh.PruneAckWait(t)
    t = t or now()
    local dropped = 0
    for syncId in pairs(Mesh._ackWait) do
        local at = Mesh._ackWaitAt[syncId]
        if not at then
            Mesh._ackWaitAt[syncId] = t
        elseif (t - at) > Mesh.ACK_WAIT_TTL then
            Mesh._ackWait[syncId] = nil
            Mesh._ackWaitAt[syncId] = nil
            dropped = dropped + 1
        end
    end
    -- Drop orphan stamps whose wait set is already gone.
    for syncId in pairs(Mesh._ackWaitAt) do
        if not Mesh._ackWait[syncId] then Mesh._ackWaitAt[syncId] = nil end
    end
    return dropped
end

-- TTL sweep for the per-(sender,prefix) sequence high-water marks.
--
-- _inSeq is keyed by "<sender>\1<prefix>" and had no removal path: every stranger
-- who ever whispered us a sequenced frame (guild-fallback broadcasts reach
-- non-peers too) kept a record forever. Drop a record only when BOTH hold: its
-- sender is not a peer we currently track, AND it has not been consulted for
-- INSEQ_TTL. Keeping current peers unconditionally is what stops a prune from
-- resetting a live sender's high-water and re-opening the replay window.
function Mesh.PruneInSeq(t)
    t = t or now()
    local peerNames = {}
    for _, p in pairs(Mesh.peers) do
        if type(p) == "table" and p.name then peerNames[p.name] = true end
    end
    local dropped = 0
    for key, rec in pairs(Mesh._inSeq) do
        if type(rec) == "table" then
            local sender = key:match("^([^\1]*)") or key
            if not rec.t then
                rec.t = t                      -- pre-existing record: start its clock
            elseif not peerNames[sender] and (t - rec.t) > Mesh.INSEQ_TTL then
                Mesh._inSeq[key] = nil
                dropped = dropped + 1
            end
        end
    end
    return dropped
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
    for k, exp in pairs(Mesh._nsReqSeen) do
        if exp <= t then Mesh._nsReqSeen[k] = nil end
    end
    Mesh.PruneAckWait(t)
    Mesh.PruneInSeq(t)
end

-- Extract the session component of a message id. MakeMessageId() builds
-- "<aid>-<base36 session>-<base36 seq>" and the account id is always a 1-2 digit
-- number (core.lua ns:IsValidAccountID), so a well-formed id is exactly three
-- dash-delimited tokens with no internal dashes. The middle token identifies the
-- SENDER SESSION; a fresh login/reload randomises it (see Mesh.OnLogin), which is
-- how FreshSeq tells a sender's pre- and post-reload frames apart. Anything that
-- does not match the three-token shape is malformed -> "?" (a shared fallback
-- session slot: the frame still dispatches, it just can't drive a seq reset).
local function sessionOfMsgId(msgId)
    if type(msgId) ~= "string" then return "?" end
    local _, sess, _ = msgId:match("^([^-]+)%-([^-]+)%-([^-]+)$")
    if sess and sess ~= "" then return sess end
    return "?"
end
Mesh._SessionOfMsgId = sessionOfMsgId   -- exposed for the seq self-tests

-- Session-sequence check: reject stale/out-of-order frames from a sender.
-- Returns true if the frame is fresh (and records the new high-water mark).
--
-- `sess` is the sender's session id (from the frame's msgId). The high-water
-- record is stored as { sess=<string>, last=<number> } PER (sender,prefix) key.
-- When the incoming session differs from the stored one the sender has restarted
-- (e.g. a /reload reset its outgoing seq counter back toward 0): we adopt the new
-- session and reset the high-water to 0 before comparing, so the fresh session's
-- low seqs are NOT stale-dropped against the previous session's high-water. This
-- is the core reload wedge fix — without it a reloaded sender's STATE/HEARTBEAT
-- frames are silently dropped until its counter climbs past the old mark.
--
-- `t` is optional and used only for bookkeeping: every consultation restamps
-- rec.t so Mesh.PruneInSeq can tell a live conversation from an abandoned one.
function Mesh.FreshSeq(sender, seq, sess, t)
    seq = tonumber(seq) or 0
    if seq == 0 then return true end   -- unsequenced ops (ping/ack) always pass
    sess = sess or "?"
    local rec = Mesh._inSeq[sender]
    if not rec then
        rec = { sess = sess, last = 0 }
        Mesh._inSeq[sender] = rec
    elseif rec.sess ~= sess then
        -- New sender session: reset the high-water and adopt the new session id.
        rec.sess = sess
        rec.last = 0
    end
    rec.t = t or now()
    if seq <= rec.last then return false end
    rec.last = seq
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

-- TRANSMIT-SAFETY HARD RULE (owner-authorized interop boundary).
-- ShadowNetwork's addon-message prefixes are RECEIVE-ONLY for this suite:
-- snbridge.lua passively decodes SN timer/pull broadcasts as a data source,
-- but this client must NEVER transmit on them (no impersonation of SN). Every
-- mesh send funnels through rawSend, and every queued frame funnels through
-- Enqueue, so gating BOTH here proves no send path can carry an SN prefix.
-- (NWB is different: NovaWorldBuffs data requests ARE allowed, and they ride
-- AceComm's own sender, never this mesh transport — so NWB is not listed.)
local FORBIDDEN_TX = {
    SDWW = true,   -- SN timer broadcasts / pull alerts / timer whispers (+ legacy SNT)
    SNT  = true,   -- SN legacy timer inbound prefix
    SDWZ = true,   -- SN state pushes / relays
    SDWY = true,   -- SN heartbeats / discovery
    SDWX = true,   -- SN handshakes / bulk sync
}
Mesh.FORBIDDEN_TX = FORBIDDEN_TX
Mesh._forbiddenTxBlocked = 0   -- telemetry: guard-fire count (surfaced in debug)

-- PURE guard predicate (harness-testable): is `prefix` a ShadowNetwork prefix
-- this client is forbidden from transmitting on?
function Mesh.IsForbiddenTxPrefix(prefix)
    return FORBIDDEN_TX[prefix] == true
end

-- Low-level send of one already-enveloped wire string. C_ChatInfo returns a
-- SendAddonMessageResult; Success is 0. Treat 0 or nil as delivered, anything
-- else (throttled / invalid target) as a failure for the skip tracker.
local function rawSend(prefix, wire, chatType, target)
    -- HARD GUARD: refuse to ever transmit on a ShadowNetwork prefix.
    if Mesh.IsForbiddenTxPrefix(prefix) then
        Mesh._forbiddenTxBlocked = (Mesh._forbiddenTxBlocked or 0) + 1
        return false
    end
    if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return false end
    local res = C_ChatInfo.SendAddonMessage(prefix, wire, chatType, target)
    return res == nil or res == 0
end
Mesh._rawSend = rawSend   -- exposed for the transmit-safety self-test

-- Enqueue a fully-built frame for a prefix, chunking as needed.
-- meta = { op, chatType, target, priority, cost }
function Mesh.Enqueue(prefix, frame, meta)
    -- Defense in depth: a forbidden SN prefix can never even enter the queue.
    -- (rawSend guards the wire; this guards the scheduler.)
    if Mesh.IsForbiddenTxPrefix(prefix) then
        Mesh._forbiddenTxBlocked = (Mesh._forbiddenTxBlocked or 0) + 1
        return false
    end
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
    -- Additive: true = the frame is queued for the drain ticker. Callers that
    -- need a delivery count (Mesh.PushState) treat this as "confirmed enqueue".
    return true
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
    -- A1.3: expire peers silent for >30s (self-gated to a 5s cadence).
    Mesh.MaybeSweepPeers(t)
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

-- True only when (nameRealm, record) is one of OUR OWN account's characters.
-- Imported / other-account records must NEVER be broadcast as ours — doing so
-- would defeat owner-wins + self-immunity on the receiving peers.
function Mesh.IsSelfRecord(nameRealm, record)
    if type(record) ~= "table" then return false end
    local nr = record.nameRealm or nameRealm
    if type(nr) ~= "string" or nr == "" then return false end
    if nr == selfNameRealm() then return true end   -- our live character
    if Store and Store.GetSelfAccount then
        local selfBucket = Store.GetSelfAccount(false)
        if selfBucket and selfBucket.characters and selfBucket.characters[nr] then
            return true
        end
    end
    return false
end

-- STATE_CHANGED subscriber. Guards the (nameRealm, record) contract: a nil or
-- non-self record (e.g. a stray args-free fire, or an imported other-account
-- record) is ignored so it can never be pushed to peers or crash the encoder.
-- `force` (spec §9.4) bypasses the change filter: teardown/logout, the 1s
-- post-entering-world push, and the max-quiet refresh all set it.
-- `receipt` (optional) is a caller-owned table the transport stamps with
-- `sent = <targets whispered>`. ns:Fire discards listener return values and
-- ns:SafeCall returns pcall's own (ok, err), so a mutable receipt is the only
-- way a delivery count can travel from here back to Tracker.Capture — see the
-- hash-after-send note on Tracker.Capture. A receipt left UNSTAMPED means "no
-- transport was listening at all", which the tracker treats as "don't judge".
function Mesh.OnStateChanged(nameRealm, record, force, receipt)
    if not Mesh.IsSelfRecord(nameRealm, record) then return end
    ns:SafeCall(Mesh.PushState, nameRealm, record, force, receipt)
end

-- PURE: stable key for a set of target account IDs. A newly-discovered peer
-- changes this key, which is what stops the payload-hash suppressor from
-- starving a peer that joined AFTER the last identical push.
function Mesh.PeerSetKey(plan)
    local ids = {}
    for i = 1, #(plan.direct or {}) do ids[#ids + 1] = tostring(plan.direct[i]) end
    for i = 1, #(plan.backups or {}) do ids[#ids + 1] = tostring(plan.backups[i]) end
    table.sort(ids)
    return joinList(ids, ",")
end

-- Push a live character record to the mesh (called on STATE_CHANGED).
--
-- A10.1 belt-and-suspenders: Tracker.Capture already gates the STATE_CHANGED
-- fire on the same content hash, but ANY other caller (an import refresh, a
-- future module, a manual /nexus push) funnels through here, so the suppressor
-- is repeated at the transport edge. It is deliberately keyed on
-- (content hash, target set) so it can never withhold state from a peer that
-- was not in the previous send.
-- A9.1 ENCODE BOUNDARY. protocol.lua carries two u16 REMAINING-SECONDS fields
-- and is frozen; the record carries START EPOCHS. Convert here, on a SHALLOW
-- COPY, so the number on the wire is the remaining as of the moment of
-- transmission — not as of the last capture — and the live Store record is never
-- mutated by the act of sending. See the drift analysis in store.lua.
function Mesh.WireRecord(rec, t)
    if type(rec) ~= "table" then return rec end
    local out = {}
    for k, v in pairs(rec) do out[k] = v end
    if Store and Store.WireItemCd then Store.WireItemCd(out, t or now()) end
    return out
end

-- RETURNS the number of targets this call actually whispered the state to.
--
-- That number is the whole point: Tracker.Capture used to stamp its
-- "last pushed" hash BEFORE firing STATE_CHANGED, so a change captured while we
-- knew zero peers was recorded as delivered and the change filter then
-- suppressed it forever. The state only escaped when something ELSE changed —
-- which is why a peer logging in mid-session saw a frozen character.
--
-- Nothing whispered => 0 => the tracker rolls its stamp back and retries on the
-- next capture (and the new 30s safety ticker guarantees there IS a next one).
-- Every early return below is therefore a 0: mesh off, nothing encodable, no
-- peers, all sends deduped.
--
-- The ONE case that is emphatically not 0 is the payload-hash suppressor: that
-- path means this exact state has ALREADY been delivered to this exact peer set,
-- so it reports the count of the push it is standing in for. Returning 0 there
-- would roll the stamp back on a successful delivery and re-fire STATE_CHANGED
-- on every capture forever, defeating the A10.1 change filter.
function Mesh.PushState(nameRealm, record, force, receipt)
    local function report(n)
        n = n or 0
        if type(receipt) == "table" then receipt.sent = n end
        Mesh._lastPushSent = n
        return n
    end
    if not Mesh.IsEnabled() then return report(0) end
    local payload = Protocol.EncodeCharacter(Mesh.WireRecord(record, now()))
    if not payload then return report(0) end   -- nothing encodable (nil/foreign record)
    local ids = onlinePeerIDs()
    -- A10.9: adapt the direct-send budget to the live token count.
    local sched = Mesh._sched[Protocol.PREFIX.STATE]
    local tokens = sched and sched.bucket and sched.bucket.tokens
    local plan = Mesh.ComputeRelayPlan(ids, Mesh.DirectBudget(tokens),
        ns:GetAccountID())

    local key     = (type(record) == "table" and record.nameRealm) or nameRealm or "?"
    local hash    = Mesh.StateHash(record)
    local peerKey = Mesh.PeerSetKey(plan)
    local prev    = Mesh._lastPush[key]
    if not force and hash and prev and hash == prev.hash and peerKey == prev.peers then
        Mesh._pushSuppressed = (Mesh._pushSuppressed or 0) + 1
        -- Already delivered to exactly this peer set: report that delivery, not 0.
        return report(prev.sent or 0)
    end

    local sent = {}    -- guard against double-whispering a backup
    local delivered = 0
    local function sendDirect(aid, delegated)
        local name = Mesh.NameForAID(aid)
        if not name or sent[name] then return end
        sent[name] = true
        local relayTo = delegated and buildRelayTo(delegated) or ""
        local seq = Mesh._outSeq + 1
        local frame = Mesh.BuildFrame(OP.STATE, payload, { seq = seq, relayTo = relayTo })
        -- Count CONFIRMED ENQUEUE only. Mesh.Enqueue refuses a forbidden prefix,
        -- and a target we cannot name never reaches the queue at all.
        if Mesh.Enqueue(Protocol.PREFIX.STATE, frame, {
            op = "state", chatType = "WHISPER", target = name, seq = seq,
        }) then
            delivered = delivered + 1
        end
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

    -- Record the suppressor key ONLY once something actually went out. A push
    -- that reached nobody must not arm the suppressor against its own retry.
    if delivered > 0 then
        Mesh._lastPush[key] = { hash = hash, peers = peerKey, sent = delivered }
    else
        Mesh._lastPush[key] = nil
    end
    return report(delivered)
end

----------------------------------------------------------------------
-- A10.8 — relay age gate (spec §9.4: "relayed payloads older than 10s are
-- dropped rather than forwarded").
--
-- VERDICT: implementable WITHOUT a wire-format change. The frame header
-- (version / op / msgId / seq / relayTo) carries no send timestamp, and adding
-- one would be a protocol bump — explicitly out of bounds. But the STATE
-- payload already carries the owner's own epochs (lastDataUpdate / ownerEpoch),
-- stamped by Tracker.Capture in the same frame as the push, so the decoded
-- record IS a send timestamp for the only op that is ever relayed. We gate on
-- that. Limitation to note: it measures OWNER-STAMP age, not hop age, so a
-- payload that sat in the originator's own send queue counts that delay too
-- (strictly more conservative than the reference, never less). A record with no
-- usable stamp (all epochs zero) is forwarded rather than silently dropped.
----------------------------------------------------------------------
function Mesh.RelayAgeOK(rec, t)
    if type(rec) ~= "table" then return false end
    local stamp = rec.lastDataUpdate or 0
    if stamp <= 0 then stamp = rec.ownerEpoch or 0 end
    if stamp <= 0 then stamp = rec.lastSeen or 0 end
    if stamp <= 0 then return true end     -- unstamped: forward (fail-open)
    return ((t or 0) - stamp) <= Mesh.RELAY_MAX_AGE
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
        if Mesh.PeerNameMatches(p, name) then return aid end
    end
    return nil
end

----------------------------------------------------------------------
-- THE REPAINT PUMP
--
-- THE REGRESSION this closes: every inbound path wrote peer data into the store
-- and then told NOBODY. The dashboard, the cards and the detail pane all repaint
-- off the callback bus (ui_shell subscribes onEngineChange to STATE_CHANGED and
-- STORE_REFRESHED), and STATE_CHANGED only ever fires for our OWN record, from
-- Tracker.Capture. So a remote character's buffs updated in the SavedVariables
-- and sat there: the open dashboard kept drawing the copy it had, durations
-- froze, and only a local capture (or reopening the window) ever surfaced the
-- new data.
--
-- STORE_REFRESHED is the args-free "bulk store changed" signal ui_shell, timers
-- and the importer already share, so this needs no new plumbing. The mesh
-- IGNORES it by design — it subscribes only to STATE_CHANGED, which is
-- self-record-guarded — so firing it from a receive handler can never loop back
-- out as another push. (Verified: mesh.lua's own testStoreRefreshedIgnored.)
--
-- Fired at most ONCE per received frame, never per record, so a bulk segment
-- adoption is one repaint rather than one per character.
----------------------------------------------------------------------
function Mesh.NoteStoreChanged()
    Mesh._storeRefreshFires = (Mesh._storeRefreshFires or 0) + 1
    ns:Fire("STORE_REFRESHED")
end

local function handleState(f, sender, isRelay)
    local rec, err = Protocol.DecodeCharacter(f.payload)
    if not rec then return end
    -- OWNER ATTRIBUTION IS INFERRED, NOT CARRIED. The binary STATE frame has no
    -- owner-account field, so we guess: first from the record's own name, then
    -- from whoever sent it. Both rungs are lossy and the failure is systematic:
    --   * `aidForName` scans Mesh.peers, and Mesh.CanAdmitPeer refuses to admit
    --     our own account id — so a record about one of OUR OWN characters can
    --     NEVER match rung 1 and always falls through to the sender;
    --   * on a RELAY the sender is the FORWARDER, not the owner, so a
    --     store-and-forwarded record is attributed to the wrong account.
    -- Net effect: a peer relaying our own character files it under the peer's
    -- bucket as a phantom second copy, which then competed with our own capture
    -- for the roster card (Dashboard.RosterCandidateBetter ranks on raw
    -- ownerEpoch, no self preference). Store.RejectInboundOwnCharacter closes
    -- that at the arbitration boundary on OWNERSHIP rather than on epochs —
    -- epochs cannot referee it, because a relayed copy honestly carries the
    -- ORIGINAL capture epoch and therefore ties rather than loses.
    -- Carrying the true owner id (and an owner-vs-relay flag) on the wire is
    -- the schema v3 work; this local rule is its precursor.
    local ownerAID = aidForName(rec.nameRealm) or aidForName(sender) or ""
    -- Owner-wins / epoch / lowest-account-ID tiebreak lives in the store.
    local senderAID = aidForName(sender)
    -- A true return means the record really changed — an older/losing push is
    -- rejected and must NOT cost a repaint. Store.WriteInboundCharacter also
    -- runs the B5 stale-twin reconciliation internally, so a twin retired by
    -- this write is covered by the same signal.
    if Store.WriteInboundCharacter(ownerAID, rec.nameRealm, rec, senderAID) then
        Mesh.NoteStoreChanged()
    end
    -- One-hop forward for genuine (non-relay) pushes carrying a relayTo list.
    -- A10.8: a stale payload is DROPPED, not forwarded — a slow relay must not
    -- resurrect state that the owner has already superseded.
    if not isRelay then
        if Mesh.RelayAgeOK(rec, now()) then
            forwardRelay(f, f.relayTo, f.payload, f.seq)
        elseif f.relayTo and f.relayTo ~= "" then
            Mesh._relayAgeDrops = (Mesh._relayAgeDrops or 0) + 1
        end
    end
end

-- Account-ID conflict detection (item 18): a heartbeat carrying OUR OWN account
-- ID from another character means two accounts share an ID on the mesh. Warn the
-- owner (throttled) and refuse to admit them as a peer.
Mesh._conflictWarned = {}   -- [sender] = ts of last warning
local CONFLICT_WARN_COOLDOWN = 60

function Mesh.CheckAccountConflict(aid, sender, t)
    t = t or now()
    if not aid or aid == "" then return false end
    if aid ~= ns:GetAccountID() then return false end
    if Mesh.IsSelfSender(sender) then return false end   -- our own echo: not a conflict
    local last = Mesh._conflictWarned[sender] or 0
    if (t - last) >= CONFLICT_WARN_COOLDOWN then
        Mesh._conflictWarned[sender] = t
        if ns.Print then
            ns:Print("|cffff4040ACCOUNT ID CONFLICT!|r Account ID '" .. aid ..
                "' is used by both you and " .. tostring(sender) ..
                ". Change your Account ID (/nexus account <n>) so the mesh can tell you apart.")
        end
    end
    return true
end

-- A1.4 — discovery-ping every character a peer advertises as online that we do
-- not already track. Reuses the roster-sweep selector so the SAME per-name
-- cooldown map (ROSTER_PING_COOLDOWN) throttles both paths: a heartbeat every
-- ~20s can never out-run the ping dedup. Returns the names pinged (for tests).
function Mesh.ConsumeOnlineHint(onlineList, t)
    if type(onlineList) ~= "table" or #onlineList == 0 then return {} end
    t = t or now()
    -- Drop self-echoes robustly (short name or Name-Realm) before selecting.
    local candidates = {}
    for i = 1, #onlineList do
        local nm = onlineList[i]
        if type(nm) == "string" and nm ~= "" and not Mesh.IsSelfSender(nm) then
            candidates[#candidates + 1] = nm
        end
    end
    local targets = Mesh.SelectRosterPings(candidates, selfNameRealm(),
        Mesh.KnownPeerNames(), Mesh._pingCooldowns, t, Mesh.ROSTER_PING_COOLDOWN)
    for i = 1, #targets do
        Mesh._pingCooldowns[targets[i]] = t
        ns:SafeCall(Mesh.SendDiscovery, OP.PING, targets[i])
    end
    return targets
end

local function handleHeartbeat(f, sender)
    local hb = Mesh.Unpack(f.payload)
    if not hb or not hb.aid then return end
    -- Two accounts sharing an ID: warn + drop (never admit as a peer).
    if Mesh.CheckAccountConflict(hb.aid, sender, now()) then return end
    -- hb.online[1] is the sender's OWN canonical Name-Realm: a WoW account has
    -- exactly one character logged in, and SendHeartbeat stamps selfNameRealm()
    -- there (see the comment on Mesh.SendHeartbeat). Prefer it over the raw
    -- CHAT_MSG_ADDON sender, which is bare on some paths.
    local p = Mesh.NotePeer(hb.aid,
        Mesh.CanonicalPeerName(sender, hb.online and hb.online[1]), now())
    if not p then return end
    p.hashes = hb.hashes or {}
    p.timerHash = hb.timerHash
    -- A1.4: consume the online-character hint for DISCOVERY ONLY (spec §2.5).
    -- Any advertised character we have never met gets a discovery ping so a
    -- fresh install converges without waiting for a roster sweep. The field is
    -- NEVER used to evict or correct a sibling — that is the reference's own
    -- documented limitation and our per-account exclusivity already covers it.
    Mesh.ConsumeOnlineHint(hb.online, now())
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
    -- Instance-ledger divergence for the SENDER's account -> pull its ledger.
    local localInstHash = Mesh.HashInstances(
        Store.GetInstancesForAID and Store.GetInstancesForAID(hb.aid))
    if hb.instancesHash and hb.instancesHash ~= localInstHash then
        Mesh.RequestSync(sender, hb.aid, "instances")
    end
    -- Suite-namespace divergence (wave N5) -> pull the differing namespaces from
    -- this peer (store-and-forward: whoever advertises the newest serves it).
    local Sync = _G and _G.Daseeki and _G.Daseeki.Sync
    if Sync and Sync.AllNamespaceHashes and type(hb.nsRev) == "table" then
        local nsDiffs = Mesh.DiffNamespaceHashes(Sync.AllNamespaceHashes(), hb.nsRev)
        for i = 1, #nsDiffs do
            Mesh.RequestNamespace(sender, nsDiffs[i])
        end
    end
end

local function handleDiscovery(f, sender, isPing)
    -- payload is a small packed { aid, name }
    local d = Mesh.Unpack(f.payload)
    local aid = d and d.aid
    -- The discovery payload carries the sender's canonical Name-Realm (`d.name`,
    -- stamped by Mesh.SendDiscovery). It used to be decoded and discarded.
    if aid then
        Mesh.NotePeer(aid, Mesh.CanonicalPeerName(sender, d and d.name), now())
    end
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
    elseif req.area == "instances" then
        Mesh.SendInstances(sender, req.aid)
    else
        Mesh.SendManifest(sender, req.aid, req.area)
        Mesh.SendSegment(sender, req.aid, req.area)
    end
end

-- B4 — manifest adoption + GHOST CLEANUP (spec §9.7).
--
-- Manifests used to be purely advisory here: we noted the peer and threw the
-- list away, so the only way a character ever left our roster was the norole
-- eviction cap. An alt deleted or renamed on another account therefore lingered
-- FOREVER — nothing on the wire says "this character is gone" except its absence
-- from a newer manifest.
--
-- All of the "is this allowed" logic (self-immunity, tombstones, unknown
-- account, unsynced segment, strictly-newer epoch, per-record out-of-order
-- protection) lives in Store.AdoptManifest so it is testable without a mesh.
local function handleManifest(f, sender)
    local man = Mesh.Unpack(f.payload)
    if not man or not man.aid then return end
    -- Manifests carry no name field, so all we can do is normalize the sender.
    Mesh.NotePeer(man.aid, Mesh.CanonicalPeerName(sender, nil), now())
    -- B4 ghost cleanup removes characters and adopts homeless ones. That is a
    -- roster change the dashboard has no other way to hear about, so pump the
    -- repaint whenever the adoption actually moved something.
    local applied, info = Store.AdoptManifest(man.aid, man.area, man.list, man.epoch, man.hash)
    if applied and info and (#(info.deleted or {}) > 0 or #(info.adopted or {}) > 0) then
        Mesh.NoteStoreChanged()
    end
end

local function handleSegment(f, sender)
    local seg = Mesh.Unpack(f.payload)
    if not seg or not seg.aid or not seg.records then return end
    local senderAID = aidForName(sender)
    local adopted = 0
    for nameRealm, rec in pairs(seg.records) do
        if Store.WriteInboundCharacter(seg.aid, nameRealm, rec, senderAID) then
            adopted = adopted + 1
        end
    end
    -- One repaint for the whole segment, not one per character.
    if adopted > 0 then Mesh.NoteStoreChanged() end
end

-- Inbound instance ledger for an account. The dedup + ring-cap + self-immunity
-- all live in the instances layer (Instances.MergeInbound), so this is pure
-- transport: unpack and hand off. Guarded so a mesh-only build (instances layer
-- absent) simply drops it.
local function handleInstances(f, sender)
    local seg = Mesh.Unpack(f.payload)
    if not seg or not seg.aid or type(seg.records) ~= "table" then return end
    if ns.Instances and ns.Instances.MergeInbound then
        ns.Instances.MergeInbound(seg.aid, seg.records)
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
        -- Every target answered: drop the parent entry. Without this the syncId
        -- key (and its now-empty member table) survived for the whole session,
        -- one per press of the sync button. Mesh.PruneAckWait is the backstop for
        -- the sets that never empty because a target never answers.
        local empty = true
        for _ in pairs(wait) do empty = false break end
        if empty then
            Mesh._ackWait[syncId] = nil
            Mesh._ackWaitAt[syncId] = nil
        end
    end
end

-- ADDITIVE op (see OP.LOGOUT): the sender is leaving. Latch its peer entry
-- offline NOW instead of waiting for either the channel-leave notice — which
-- never arrives at all for a peer we know only through the guild fallback — or
-- the 30s silence sweep. The latch is timestamped, so the final STATE whispers
-- still in flight behind this notice cannot re-green the pip (see
-- Mesh.StaleLatchHolds).
--
-- Note the ordering this relies on: onChatMsgAddon stamps liveness
-- (TouchPeerByName) BEFORE dispatching, so the touch caused by this very frame
-- happens first and is then overridden here. That is the correct order — the
-- touch is about the transport, the latch is about intent.
local function handleLogout(f, sender)
    Mesh.MarkPresenceStale(sender, now())
end
Mesh._handleAck    = handleAck      -- exposed for the ack-wait self-test
Mesh._handleLogout = handleLogout   -- exposed for the logout-latch self-test

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
    -- higher-seq message on one prefix stale out a lower-seq one on another. The
    -- session token (middle of the msgId) lets a sender's /reload reset its seq
    -- counter without the receiver's stale-water dropping every fresh frame.
    if Mesh.SeenBefore(f.msgId) then return end
    if not Mesh.FreshSeq(sender .. "\1" .. prefix, f.seq, sessionOfMsgId(f.msgId)) then return end

    local op = f.op
    if op == OP.STATE then          handleState(f, sender, false)
    elseif op == OP.RELAY then      handleState(f, sender, true)
    elseif op == OP.HEARTBEAT then  handleHeartbeat(f, sender)
    elseif op == OP.PING then       handleDiscovery(f, sender, true)
    elseif op == OP.PONG then       handleDiscovery(f, sender, false)
    elseif op == OP.SYNC_REQ then   handleSyncReq(f, sender)
    elseif op == OP.MANIFEST then   handleManifest(f, sender)
    elseif op == OP.SEGMENT then    handleSegment(f, sender)
    elseif op == OP.INSTANCES then  handleInstances(f, sender)
    elseif op == OP.SETTINGS then   handleSettings(f, sender)
    elseif op == OP.BLACKLIST then  handleBlacklist(f, sender)
    elseif op == OP.ACK then        handleAck(f, sender)
    elseif op == OP.TIMER then      handleTimer(f, sender, true)
    elseif op == OP.TIMER_SNAP then
        -- Defined later in the chunk (snapshot handoff section); reach it via
        -- the Mesh table so this early closure resolves it at call time.
        if Mesh._handleTimerSnap then Mesh._handleTimerSnap(f, sender) end
    elseif op == OP.NSPAYLOAD then  Mesh.HandleNSPayload(f, sender)
    elseif op == OP.NSREQ then      Mesh.HandleNSReq(f, sender)
    elseif op == OP.LOGOUT then     handleLogout(f, sender)
    end
    -- NOTE (wire compatibility): there is deliberately NO `else` arm. An op this
    -- build does not know is dropped in silence — no error, no print, no counter.
    -- That is the property every additive op relies on to stay safe for peers
    -- running an older build, and it must not be "improved" into a warning.
end

----------------------------------------------------------------------
-- Outbound builders for the remaining ops
----------------------------------------------------------------------

-- Heartbeat: our self-account hashes + online-character hint + timer hash.
function Mesh.SendHeartbeat()
    if not Mesh.IsEnabled() then return end
    local aid = ns:GetAccountID()
    local bucket = Store.GetAccount(aid, false)
    local Sync = _G and _G.Daseeki and _G.Daseeki.Sync
    local hb = {
        aid       = aid,
        hashes    = bucket and Mesh.AccountHashes(bucket) or {},
        timerHash = Mesh.HashTimers(Store.GetTimers and Store.GetTimers()),
        -- Instance-ledger hash for OUR OWN account (additive field; older clients
        -- ignore it, so no protocol version bump). Follows the timerHash pattern.
        instancesHash = Mesh.HashInstances(
            Store.GetInstancesForAID and Store.GetInstancesForAID(aid)),
        -- Per-namespace rev hash (wave N5): peers whose hash differs pull.
        nsRev     = (Sync and Sync.AllNamespaceHashes) and Sync.AllNamespaceHashes() or nil,
        online    = {},   -- online-character hint (Name-Realm list)
    }
    -- A WoW account has exactly ONE character logged in at a time, so the hint
    -- is the character we ARE — not every character in the bucket that carries
    -- a lastSeen (which advertised the entire roster as "online" and matched
    -- the same-account double-green-pip bug the dashboard just fixed).
    -- Wire shape is unchanged (Name-Realm string array), so no SCHEMA_VERSION
    -- bump. A1.4: handleHeartbeat now CONSUMES this field via
    -- Mesh.ConsumeOnlineHint — discovery only, never eviction (spec §2.5).
    local me = selfNameRealm()
    if me and me ~= "" then hb.online[1] = me end
    local payload = Mesh.Pack(hb)
    if not payload then return end
    -- Whisper the heartbeat to every KNOWN peer (the channel is presence-only:
    -- CHANNEL distribution can't carry addon messages on this client). The GUILD
    -- fallback lets same-guild members who aren't known peers yet still hear us.
    local seq = Mesh._outSeq + 1
    local frame = Mesh.BuildFrame(OP.HEARTBEAT, payload, { seq = seq })
    Mesh.WhisperKnownPeers(Protocol.PREFIX.HEARTBEAT, frame, { op = "heartbeat", seq = seq })
    Mesh.GuildBroadcast(Protocol.PREFIX.HEARTBEAT, frame, { op = "heartbeat", seq = seq })
end

-- Discovery ping/pong — ALWAYS a directed WHISPER. `target` is required: the
-- discovery channel is presence-only (CHANNEL distribution silently drops addon
-- messages on this client), so pings go to roster members / join-notice names
-- and pongs go back to the pinger. A nil target is a no-op.
function Mesh.SendDiscovery(op, target)
    if not Mesh.IsEnabled() then return end
    if not target or target == "" then return end
    local payload = Mesh.Pack({ aid = ns:GetAccountID(), name = selfNameRealm() })
    if not payload then return end
    -- Telemetry: record when we emit a discovery ping/pong (surfaced in debug).
    if op == OP.PING then Mesh._disco.lastPingSent = now()
    elseif op == OP.PONG then Mesh._disco.lastPongSent = now() end
    local frame = Mesh.BuildFrame(op, payload, {})
    Mesh.Enqueue(Protocol.PREFIX.HEARTBEAT, frame, {
        op = "discovery", chatType = "WHISPER", target = target,
    })
end

----------------------------------------------------------------------
-- Presence roster: discovery over channel presence + whisper transport
--
-- The derived channel is a PRESENCE beacon; addon data can never ride it on
-- this client. We learn who is present by enumerating the channel ROSTER and
-- by CHAT_MSG_CHANNEL_JOIN/LEAVE notices, then whisper discovery pings to those
-- names. Once a peer answers (PONG) or heartbeats, it becomes a known peer and
-- the heartbeat whisper path keeps it alive.
--
-- Roster enumeration — verified against the API catalog (1.15.9.68808):
--   * C_ChatInfo.GetChannelRosterInfo(channelIndex, rosterIndex)
--         -> name, owner, moderator, guid          (functions.txt:514)
--   * GetNumChannelMembers                          (globals.txt:5333, count
--         fast-path; name-only in the catalog so it is capability-guarded)
--   * GetChannelName                                (globals.txt:4909, already
--         used to resolve our channel index)
-- Shipped path: if GetNumChannelMembers is present we trust its count and read
-- exactly that many roster rows; otherwise we iterate rosterIndex from 1 and
-- stop at the first empty row. Both branches are hard-capped by ROSTER_SCAN_CAP.
----------------------------------------------------------------------

-- Enumerate the members of a resolved channel index -> list of Name(-Realm).
-- Impure (reads live channel state); the ping-SELECTION logic below is pure.
function Mesh.ChannelRoster(channelIndex)
    local out = {}
    if not channelIndex or channelIndex <= 0 then return out end
    local getRoster = C_ChatInfo and C_ChatInfo.GetChannelRosterInfo
    if not getRoster then return out end
    local haveCount = (GetNumChannelMembers ~= nil)
    local count = haveCount and (GetNumChannelMembers(channelIndex) or 0) or 0
    if not haveCount or count <= 0 then count = Mesh.ROSTER_SCAN_CAP end
    if count > Mesh.ROSTER_SCAN_CAP then count = Mesh.ROSTER_SCAN_CAP end
    for r = 1, count do
        local name = getRoster(channelIndex, r)
        if name and name ~= "" then
            out[#out + 1] = name
        elseif not haveCount then
            break   -- iterate-until-empty fallback: first gap ends the roster
        end
    end
    return out
end

-- Set of names we already track as peers (skip-pinging them on a sweep).
local function knownPeerNames()
    local set = {}
    for _, p in pairs(Mesh.peers) do
        if p.name then set[p.name] = true end
    end
    return set
end
-- Public alias: handleHeartbeat (defined ABOVE this local) needs the same set
-- for A1.4 discovery, and a table field resolves at call time.
Mesh.KnownPeerNames = knownPeerNames

-- PURE: per-name cooldown gate. True if `name` may be pinged at nowT.
function Mesh.ShouldPingName(name, cooldowns, nowT, cooldownWin)
    if not name or name == "" then return false end
    cooldownWin = cooldownWin or Mesh.ROSTER_PING_COOLDOWN
    local last = cooldowns and cooldowns[name]
    if last and (nowT - last) < cooldownWin then return false end
    return true
end

-- PURE: given a roster, our self name, the set of already-known peer names, a
-- per-name cooldown map and now, return the names to ping this sweep. Excludes
-- self, already-known peers, and names still inside their cooldown window.
function Mesh.SelectRosterPings(roster, selfName, knownNames, cooldowns, nowT, cooldownWin)
    local out = {}
    for i = 1, #roster do
        local name = roster[i]
        if name and name ~= "" and name ~= selfName
           and not (knownNames and knownNames[name])
           and Mesh.ShouldPingName(name, cooldowns, nowT, cooldownWin) then
            out[#out + 1] = name
        end
    end
    return out
end

----------------------------------------------------------------------
-- A10.7 / spec §9.5 — per-target send cooldowns
--
-- Heartbeat-driven divergence detection is edge-triggered on a HASH COMPARE, and
-- the hash of a busy account changes constantly, so "we diverge -> answer with a
-- manifest/segment" fires on essentially every heartbeat from every peer. With
-- 8 peers heartbeating every ~20s that is a steady drip of redundant bulk sends
-- to the SAME target; the reference caps each kind per target. Settings and
-- blacklist are not on that path at all — they are button-driven — but they fan
-- out to every peer, so they get a modest gate of their own against mashing.
--
-- The key namespaces by KIND and TARGET, plus an optional scope (account+area)
-- where the spec's limit is per-account rather than per-target.
----------------------------------------------------------------------

function Mesh.SendCooldownKey(kind, target, scope)
    return tostring(kind) .. "\1" .. tostring(target or "*")
        .. (scope and ("\1" .. tostring(scope)) or "")
end

-- PURE: may `key` be sent at nowT given `cooldowns` and a window? Mirrors
-- Mesh.ShouldPingName exactly (same shape, same semantics, different map).
function Mesh.ShouldSendTo(key, cooldowns, nowT, win)
    if not key or key == "" then return false end
    if not win or win <= 0 then return true end
    local last = cooldowns and cooldowns[key]
    if last and (nowT - last) < win then return false end
    return true
end

-- Impure convenience used by the senders: check the live map and, when the send
-- is allowed, stamp it. Returns true if the caller may proceed. `t` is injectable
-- for the self-tests.
function Mesh.SendGate(kind, target, scope, win, t)
    t = t or now()
    local key = Mesh.SendCooldownKey(kind, target, scope)
    if not Mesh.ShouldSendTo(key, Mesh._sendCooldowns, t, win) then
        Mesh._sendGated = (Mesh._sendGated or 0) + 1
        return false
    end
    Mesh._sendCooldowns[key] = t
    return true
end

-- Prune cooldown entries older than a few windows so the map can't grow forever.
local function pruneCooldowns(t)
    local horizon = (Mesh.ROSTER_PING_COOLDOWN or 30) * 4
    for name, ts in pairs(Mesh._pingCooldowns) do
        if (t - (ts or 0)) > horizon then Mesh._pingCooldowns[name] = nil end
    end
    -- Send cooldowns are keyed by kind+target(+scope) and so grow with every peer
    -- and every account we ever answer. Age them out against the LONGEST window
    -- in play (times a safety factor): dropping an entry only ever re-permits a
    -- send, and by then the window has long expired anyway.
    local sendHorizon = math.max(Mesh.MANIFEST_COOLDOWN or 0, Mesh.SEGMENT_COOLDOWN or 0,
                                 Mesh.TIMERSYNC_COOLDOWN or 0, Mesh.SETTINGS_COOLDOWN or 0)
                        * (Mesh.SEND_COOLDOWN_PRUNE or 4)
    for key, ts in pairs(Mesh._sendCooldowns) do
        if (t - (ts or 0)) > sendHorizon then Mesh._sendCooldowns[key] = nil end
    end
end
Mesh.PruneCooldowns = pruneCooldowns   -- exposed for the self-tests

-- Live roster sweep: resolve our channel, enumerate the roster, whisper a
-- discovery ping to every eligible member, and record the sweep time.
function Mesh.PingRoster()
    if not Mesh.IsEnabled() then return end
    local chanName = Mesh.GetChannelName()
    if not chanName then return end
    -- Resolve our channel index inline (GetChannelName is a FrameXML global,
    -- catalog globals.txt:4909); the local getChannelIndex wrapper is declared
    -- further down the file, so we can't close over it from here.
    local idx = (chanName and GetChannelName) and (GetChannelName(chanName) or 0) or 0
    local t = now()
    Mesh._lastRosterSweep = t
    if not idx or idx <= 0 then return end   -- not joined yet; nothing to sweep
    local roster = Mesh.ChannelRoster(idx)
    -- Drop self-echoes robustly (roster may report bare Name or Name-Realm).
    local filtered = {}
    for i = 1, #roster do
        if not Mesh.IsSelfSender(roster[i]) then filtered[#filtered + 1] = roster[i] end
    end
    local targets = Mesh.SelectRosterPings(filtered, selfNameRealm(),
        knownPeerNames(), Mesh._pingCooldowns, t, Mesh.ROSTER_PING_COOLDOWN)
    for i = 1, #targets do
        Mesh._pingCooldowns[targets[i]] = t
        Mesh.SendDiscovery(OP.PING, targets[i])
    end
    pruneCooldowns(t)
end

-- Slow periodic sweep gate (piggybacks the heartbeat loop): only sweep once per
-- ROSTER_SWEEP_INTERVAL so an N-member channel can't cause ping storms.
function Mesh.MaybeRosterSweep()
    if not Mesh.IsEnabled() then return end
    if (now() - (Mesh._lastRosterSweep or 0)) < Mesh.ROSTER_SWEEP_INTERVAL then return end
    Mesh.PingRoster()
end

function Mesh.RequestSync(target, aid, area)
    local payload = Mesh.Pack({ aid = aid, area = area })
    if not payload then return end
    local frame = Mesh.BuildFrame(OP.SYNC_REQ, payload, {})
    Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
        op = "sync", chatType = "WHISPER", target = target,
    })
end

-- Spec §9.5: "Manifest sends are rate-limited to one per target per 5 s."
-- The gate is FIRST so a suppressed send costs nothing but a table lookup.
function Mesh.SendManifest(target, aid, area)
    if not Mesh.SendGate("manifest", target, tostring(aid) .. "\2" .. tostring(area),
                         Mesh.MANIFEST_COOLDOWN) then return end
    local bucket = Store.GetAccount(aid, false)
    if not bucket then return end
    local seg = bucket.segments[area]
    local payload = Mesh.Pack({
        aid = aid, area = area, list = seg,
        -- Same content-folded hash the heartbeat advertises, so the manifest's
        -- advisory hash cannot disagree with Mesh.AccountHashes for one account.
        hash = Mesh.HashSegment(seg, bucket.characters),
        epoch = (bucket.segmentHashes[area] and bucket.segmentHashes[area].epoch) or 0,
    })
    if not payload then return end
    local frame = Mesh.BuildFrame(OP.MANIFEST, payload, {})
    Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
        op = "sync", chatType = "WHISPER", target = target,
    })
end

-- Spec §9.5: bulk segment / homeless data is capped per ACCOUNT + TARGET at 60 s
-- (it is the expensive one — a full segment is the whole character set).
function Mesh.SendSegment(target, aid, area)
    if not Mesh.SendGate("segment", target, tostring(aid) .. "\2" .. tostring(area),
                         Mesh.SEGMENT_COOLDOWN) then return end
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

-- Reply to a peer's instance-ledger sync request: pack the whole char->entries
-- map for the requested account and send it on the additive INSTANCES op. Rides
-- the existing SYNC prefix + scheduler (op="sync") exactly like a segment reply.
function Mesh.SendInstances(target, aid)
    local charMap = Store.GetInstancesForAID and Store.GetInstancesForAID(aid)
    if not charMap then return end
    local payload = Mesh.Pack({ aid = aid, records = charMap })
    if not payload then return end
    local seq = Mesh._outSeq + 1
    local frame = Mesh.BuildFrame(OP.INSTANCES, payload, { seq = seq })
    Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
        op = "sync", chatType = "WHISPER", target = target, seq = seq,
    })
end

-- Reply to a peer's timer-sync request with a merged Nexus snapshot. Prefers
-- the registered provider (Timers.GetSnapshot) so the reply routes through the
-- receiver's Timers.ApplySnapshot; falls back to the legacy raw-store payload
-- when no provider is registered (provider-less build stays functional).
-- Spec §9.5: the timer-hash mismatch reply is capped at one per target per 30 s.
function Mesh.SendTimers(target)
    if not Mesh.SendGate("timersync", target, nil, Mesh.TIMERSYNC_COOLDOWN) then return end
    local snap
    if Mesh._snapProvider then
        snap = Mesh._snapProvider()
    end
    if type(snap) ~= "table" then
        snap = { legacyTimers = (Store.GetTimers and Store.GetTimers()) or {} }
    end
    local payload = Mesh.Pack(snap)
    if not payload then return end
    local seq = Mesh._outSeq + 1
    local frame = Mesh.BuildFrame(OP.TIMER_SNAP, payload, { seq = seq })
    Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
        op = "sync", chatType = "WHISPER", target = target, seq = seq,
    })
end

----------------------------------------------------------------------
-- Suite-namespace transport (DSKN3 SYNC prefix, wave N5)
--
-- Carries the payloads other suite addons publish through Daseeki.Sync v2
-- (Bags today). Each frame is one owner's payload for one namespace:
--   NSPAYLOAD blob = { ns=<nsKey>, o=<ownerKey>, r=<rev>, d=<payload table> }
-- The payload is LibSerialize+LibDeflate-packed and chunked like every other
-- SYNC frame (these are KBs). Propagation is revision-gated and store-and-
-- forward: MarkDirty pushes to online peers; heartbeats advertise a per-
-- namespace rev hash, and a peer whose hash differs pulls (NSREQ) so whoever
-- holds the newest rev serves it when a peer appears. Owner-wins-by-rev + the
-- frame dedup guards keep it from looping.
--
-- Op-letter note (re-land deviation): the original branch used "n" for
-- NSPAYLOAD, but current main reassigned "n" to TIMER_SNAP, so NSPAYLOAD is "y"
-- here (NSREQ stays "u"). Purely a wire-code assignment; additive op, older
-- clients ignore the unknown op, so no protocol version bump -- same discipline
-- the INSTANCES op followed.
----------------------------------------------------------------------

local function suiteSync()
    return _G and _G.Daseeki and _G.Daseeki.Sync or nil
end

-- Build + enqueue one owner's namespace payload to a single target. `opName` is
-- the SCHEDULER class only ("nspush" for a fresh local delta, "nspayload" for
-- bulk backfill); the wire op is OP.NSPAYLOAD either way.
local function sendNSPayloadTo(target, nsKey, ownerKey, opName)
    if not target then return false end
    local Sync = suiteSync()
    local S = Store
    if not (Sync and S and S.SyncNSGet) then return false end
    local entry = S.SyncNSGet(nsKey, ownerKey)
    if not entry then return false end
    local payload = Mesh.Pack({ ns = nsKey, o = ownerKey, r = entry.rev, d = entry.data })
    if not payload then return false end
    local seq = Mesh._outSeq + 1
    local frame = Mesh.BuildFrame(OP.NSPAYLOAD, payload, { seq = seq })
    Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
        op = opName or "nspayload", chatType = "WHISPER", target = target, seq = seq,
    })
    return true
end
Mesh._sendNSPayloadTo = sendNSPayloadTo   -- exposed for the scheduling self-test

-- Push one owner's namespace payload to every online peer, debounced so a burst
-- of MarkDirty calls coalesces into one propagation.
function Mesh.PushNamespace(nsKey, ownerKey)
    if not Mesh.IsEnabled() then return end
    local pendKey = tostring(nsKey) .. "\1" .. tostring(ownerKey)
    if Mesh._nsPushPending[pendKey] then return end
    Mesh._nsPushPending[pendKey] = true
    local function flush()
        Mesh._nsPushPending[pendKey] = nil
        if not Mesh.IsEnabled() then return end
        for _, p in pairs(Mesh.peers) do
            if p.online and p.name then
                sendNSPayloadTo(p.name, nsKey, ownerKey, "nspush")
            end
        end
    end
    if C_Timer and C_Timer.After then
        C_Timer.After(Mesh.NS_PUSH_DEBOUNCE, function() ns:SafeCall(flush) end)
    else
        flush()   -- headless / no timer: push immediately
    end
end

-- Answer a peer's pull for a namespace: send every owner entry we hold for it
-- (the receiver rev-gates + dedups). Guarded by a short per-(sender,ns) window
-- so repeated heartbeat mismatches don't re-blast the whole namespace.
function Mesh.SendNamespace(target, nsKey)
    if not Mesh.IsEnabled() or not target then return end
    local S = Store
    if not (S and S.SyncNSAll) then return end
    for ownerKey in pairs(S.SyncNSAll(nsKey)) do
        sendNSPayloadTo(target, nsKey, ownerKey)
    end
end

-- Request a namespace from a peer whose advertised rev hash diverged from ours.
function Mesh.RequestNamespace(target, nsKey)
    if not Mesh.IsEnabled() or not target then return end
    local payload = Mesh.Pack({ ns = nsKey })
    if not payload then return end
    local frame = Mesh.BuildFrame(OP.NSREQ, payload, {})
    Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
        op = "nsreq", chatType = "WHISPER", target = target,
    })
end

-- PURE: given our namespace hashes and a peer's advertised hashes, return the
-- namespace keys whose hashes differ (so we should pull them from that peer).
function Mesh.DiffNamespaceHashes(localH, remoteH)
    local diffs = {}
    if type(remoteH) ~= "table" then return diffs end
    for nsKey, rhash in pairs(remoteH) do
        if (localH and localH[nsKey] or "0") ~= rhash then
            diffs[#diffs + 1] = nsKey
        end
    end
    return diffs
end

-- Table methods (not file-locals) so the earlier Dispatch can reach them
-- regardless of definition order.
function Mesh.HandleNSPayload(f, sender)
    local blob = Mesh.Unpack(f.payload)
    if not blob or type(blob.ns) ~= "string" or type(blob.o) ~= "string" then return end
    local Sync = suiteSync()
    if not (Sync and Sync.ApplyInbound) then return end
    Sync.ApplyInbound(blob.ns, blob.o, blob.r, blob.d, now())
    -- No re-broadcast on receive: the next heartbeat advertises our updated rev
    -- hash and any still-stale peer pulls from us (store-and-forward), which
    -- avoids the fan-out storm a naive relay would cause.
end

function Mesh.HandleNSReq(f, sender)
    local req = Mesh.Unpack(f.payload)
    if not req or type(req.ns) ~= "string" then return end
    local dkey = sender .. "\1" .. req.ns
    local t = now()
    local exp = Mesh._nsReqSeen[dkey]
    if exp and exp > t then return end   -- already answered this peer recently
    Mesh._nsReqSeen[dkey] = t + Mesh.NS_REQ_DEDUP
    Mesh.SendNamespace(sender, req.ns)
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
        --
        -- SETTINGS REWORK: classColors and coordinateOverrides are NO LONGER SENT.
        -- Both are retired features (the palette is fixed; custom locations are
        -- tombstoned by Store.RetireLocations), so shipping them would be a way
        -- for one account to push retired records at another. auraRules — the one
        -- global class-rule table — takes their place as the buff configuration.
        auraRules           = db.auraRules,
        factionSettings     = db.factionSettings,
        timerSettings       = db.timerSettings,
    }
    local payload = Mesh.Pack(blob)
    if not payload then return end
    local t = now()
    local wait, sent = {}, 0
    for aid, p in pairs(Mesh.peers) do
        -- Anti-mash gate (local policy, not spec): this is a BUTTON that fans a
        -- multi-chunk payload out to every peer at once, so an impatient double-
        -- press used to be an N-peer duplicate broadcast. A gated target is
        -- skipped entirely — it is NOT added to the ACK wait set, because we
        -- never sent it anything to acknowledge.
        if p.online and p.name
           and Mesh.SendGate("settings", p.name, nil, Mesh.SETTINGS_COOLDOWN, t) then
            wait[p.name] = true
            sent = sent + 1
            local seq = Mesh._outSeq + 1
            local frame = Mesh.BuildFrame(OP.SETTINGS, payload, { seq = seq })
            Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, {
                op = "settings", chatType = "WHISPER", target = p.name, seq = seq,
            })
        end
    end
    -- Only open a wait set we actually populated: an empty one would sit in
    -- _ackWait until the TTL sweep with nothing that could ever clear it.
    if sent == 0 then return nil end
    Mesh._ackWait[syncId] = wait
    Mesh._ackWaitAt[syncId] = t
    return syncId
end

function Mesh.SendBlacklist(target)
    -- Anti-mash gate (local policy, not spec): the blacklist push is both a
    -- button action and an auto-chain off every settings ACK.
    if not Mesh.SendGate("blacklist", target, nil, Mesh.SETTINGS_COOLDOWN) then return end
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

----------------------------------------------------------------------
-- Nexus merged-snapshot handoff (N2 round 2)
--
-- Round-1 shipped a broken timer-sync reply (SendTimers packed the raw store
-- table on OP.SEGMENT, which handleSegment drops for lack of aid/records).
-- Round 2 replaces it with a first-class snapshot channel so a peer request
-- (or the guild-broadcaster relay) round-trips a Timers.GetSnapshot() through
-- Timers.ApplySnapshot on the receiver:
--
--   Mesh.RegisterSnapshotProvider(fn)  -- fn() -> snapshot table (merged timers)
--   Mesh.SetSnapshotHandler(fn)        -- fn(snap, sender) applied on receipt
--
-- Both are optional; without a provider SendTimers falls back to the legacy
-- raw-store payload so a provider-less build still answers (harmlessly).
----------------------------------------------------------------------

Mesh._snapProvider = nil
Mesh._snapHandler  = nil

function Mesh.RegisterSnapshotProvider(fn)
    Mesh._snapProvider = fn
end

function Mesh.SetSnapshotHandler(fn)
    Mesh._snapHandler = fn
end

-- Inbound merged snapshot (request reply or guild-broadcaster relay).
local function handleTimerSnap(f, sender)
    -- B5: if we have a broadcast of this EXACT payload armed but not yet sent,
    -- somebody beat us to it — drop ours rather than doubling the guild traffic.
    -- Checked on the raw payload bytes before decode, so it costs nothing.
    Mesh.CancelPendingBroadcast(Mesh.BroadcastPayloadHash(f.payload))
    local snap = Mesh.Unpack(f.payload)
    if type(snap) ~= "table" then return end
    if Mesh._snapHandler then
        ns:SafeCall(Mesh._snapHandler, snap, sender)
    end
    ns:Fire("MESH_TIMERSNAP_RECEIVED", snap, sender)
end
Mesh._handleTimerSnap = handleTimerSnap

-- Ask peers (and, as a fallback, same-guild members we don't know yet) for a
-- merged Nexus timer snapshot. Peers answer via handleSyncReq -> SendTimers.
-- The 60s button cooldown lives in the timers layer; this is the transport.
-- Returns the number of request sends emitted.
function Mesh.RequestTimers()
    if not Mesh.IsEnabled() then return 0 end
    local sent = 0
    for _, p in pairs(Mesh.peers) do
        if p.online and p.name then
            Mesh.RequestSync(p.name, "timers", "timers")
            sent = sent + 1
        end
    end
    -- Guild fallback so members not yet in our peer table also answer.
    if IsInGuild and IsInGuild() then
        local payload = Mesh.Pack({ aid = "timers", area = "timers" })
        if payload then
            local frame = Mesh.BuildFrame(OP.SYNC_REQ, payload, {})
            Mesh.Enqueue(Protocol.PREFIX.SYNC, frame, { op = "sync", chatType = "GUILD" })
            sent = sent + 1
        end
    end
    return sent
end

----------------------------------------------------------------------
-- Guild-broadcaster relay of a merged snapshot (the <=1/min rate gate and the
-- broadcaster election both live in the timers layer; this only transports).
--
-- B5 SPLIT-BRAIN JITTER
-- ---------------------
-- The election picks the lowest account id among online peers, but each client
-- evaluates it against ITS OWN roster. Two clients whose rosters disagree for a
-- moment — a peer mid-timeout on one and still live on the other — both elect
-- themselves and both relay the same snapshot to the same guild. The dedup window
-- stops the RECEIVERS double-applying it, but the traffic is already spent, and
-- on a full guild that is two multi-chunk payloads where one would do.
--
-- Fix, entirely on the transport side: defer the send by a uniform random 0-4s
-- and drop it if an identical payload arrives from anyone else while we wait.
-- The loser of the race sees the winner's copy and cancels. Deferring is free
-- here — the caller already rate-limits itself to once a minute, and a world-buff
-- snapshot is not latency-sensitive at second granularity.
----------------------------------------------------------------------

-- Content hash of a packed snapshot. Same rolling hash the segment/state hashes
-- use, so "identical payload" means identical BYTES, not merely equal-looking
-- tables — two independently packed copies of the same snapshot serialize
-- identically, which is what makes the comparison sound.
function Mesh.BroadcastPayloadHash(payload)
    return fnv1a(payload or "")
end

-- Drop an armed broadcast whose payload hash matches. Returns true if it fired.
function Mesh.CancelPendingBroadcast(hash)
    local pend = Mesh._bcastPending
    if pend and hash and pend.hash == hash then
        Mesh._bcastPending = nil
        Mesh._bcastCancelled = (Mesh._bcastCancelled or 0) + 1
        return true
    end
    return false
end

-- The actual transport (what BroadcastTimers used to do inline).
function Mesh.SendTimerSnapshot(payload)
    if not payload then return end
    local seq = Mesh._outSeq + 1
    local frame = Mesh.BuildFrame(OP.TIMER_SNAP, payload, { seq = seq })
    if IsInGuild and IsInGuild() then
        Mesh.Enqueue(Protocol.PREFIX.SYNC, frame,
            { op = "sync", chatType = "GUILD", seq = seq })
    end
    for _, p in pairs(Mesh.peers) do
        if p.online and p.name then
            Mesh.Enqueue(Protocol.PREFIX.SYNC, frame,
                { op = "sync", chatType = "WHISPER", target = p.name, seq = seq })
        end
    end
end

-- Fire the armed broadcast, unless it was cancelled or superseded while waiting.
-- Returns true if anything went on the wire.
function Mesh.FlushPendingBroadcast(hash)
    local pend = Mesh._bcastPending
    if not pend then return false end                    -- cancelled by an inbound copy
    if hash and pend.hash ~= hash then return false end  -- superseded by a newer snapshot
    Mesh._bcastPending = nil
    Mesh.SendTimerSnapshot(pend.payload)
    return true
end

function Mesh.BroadcastTimers(snap)
    if not Mesh.IsEnabled() then return false end
    if type(snap) ~= "table" then return false end
    local payload = Mesh.Pack(snap)
    if not payload then return false end
    local hash = Mesh.BroadcastPayloadHash(payload)
    -- Re-asked to broadcast a payload we already have armed: that IS the
    -- duplicate. Keep the armed one, drop this request.
    if Mesh._bcastPending and Mesh._bcastPending.hash == hash then
        Mesh._bcastCancelled = (Mesh._bcastCancelled or 0) + 1
        return false
    end
    Mesh._bcastPending = { hash = hash, payload = payload, at = now() }
    local jitter = (math.random and (math.random() * (Mesh.BCAST_JITTER_MAX or 0))) or 0
    if C_Timer and C_Timer.After and jitter > 0 then
        C_Timer.After(jitter, function()
            ns:SafeCall(Mesh.FlushPendingBroadcast, hash)
        end)
    else
        -- No scheduler (headless / jitter disabled): behave exactly as before.
        Mesh.FlushPendingBroadcast(hash)
    end
    return true
end

-- Online mesh peers as broadcaster-election rows. The timers layer picks the
-- lowest account id among these (plus self) as the guild broadcaster.
function Mesh.GetGuildRoster()
    local out = {}
    for aid, p in pairs(Mesh.peers) do
        if p.online then out[#out + 1] = { accountID = aid, name = p.name } end
    end
    return out
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
-- Broadcast helpers (whisper fan-out + guild fallback)
--
-- BroadcastChannel is retired: CHANNEL distribution can never carry addon
-- messages on this client, so there is no channel send path left. What used to
-- ride the channel (discovery pings + heartbeats) now fans out over whispers to
-- known peers; the GUILD fallback below is retained so same-guild members who
-- aren't known peers yet still converge.
----------------------------------------------------------------------

-- Whisper an already-built frame to every known ONLINE peer (broadcast-by-
-- whisper; all recipients share the frame's seq — each sees one send from us).
function Mesh.WhisperKnownPeers(prefix, frame, meta)
    meta = meta or {}
    for _, p in pairs(Mesh.peers) do
        if p.online and p.name then
            Mesh.Enqueue(prefix, frame, {
                op = meta.op, chatType = "WHISPER", target = p.name, seq = meta.seq,
            })
        end
    end
end

-- GUILD fallback broadcast: only same-guild members hear it, but it lets guildies
-- who aren't yet known peers pick us up before the roster sweep does.
function Mesh.GuildBroadcast(prefix, frame, meta)
    meta = meta or {}
    if IsInGuild and IsInGuild() then
        Mesh.Enqueue(prefix, frame, {
            op = meta.op, chatType = "GUILD", target = nil, seq = meta.seq,
        })
    end
end

----------------------------------------------------------------------
-- Logout flush (final state push, most-recently-seen peer first, wide budget)
--
-- THE GREEN-PIP BUG THIS SOLVES
-- -----------------------------
-- The flush exists so peers get our final numbers (boons, cooldowns, lockouts)
-- before we vanish. But the record it shipped had just had `lastSeen` stamped to
-- "now" by the tracker, and the receiver stores the record WHOLESALE. On the
-- receiving client the logged-out character therefore read ONLINE from both of
-- ui_shell's sources:
--   * the lastSeen recency fallback, for the full 15s ONLINE_WINDOW; and
--   * live mesh presence, because these whispers land around (often after) the
--     channel-leave notice and every raw receive re-flipped p.online true —
--     stretching the green pip to 30-35s.
-- Two changes close both, and neither touches the frame layout or the schema:
--   1. the record we ENCODE is a copy whose lastSeen is backdated past the
--      receiver's presence window, so the recency fallback is born expired.
--      ownerEpoch and lastDataUpdate are left alone, so the store's owner-wins
--      epoch guard (Store.WriteInboundCharacter) still accepts the record and
--      "last updated" reporting stays truthful;
--   2. a LOGOUT notice op precedes the fan-out, latching the peer offline on the
--      receiver so the STATE frames behind it cannot re-green it.
----------------------------------------------------------------------

-- PURE: the record to put on the wire at logout. Shallow copy — Protocol.
-- EncodeCharacter reads top-level fields plus nested tables by reference, and
-- the live Store record must NOT be mutated (it is what we reload from).
function Mesh.LogoutRecord(rec, t)
    if type(rec) ~= "table" then return rec end
    local out = {}
    for k, v in pairs(rec) do out[k] = v end
    local backdated = (t or now()) - (Mesh.LOGOUT_LASTSEEN_BACKDATE or 0)
    if backdated < 0 then backdated = 0 end
    -- Only ever move lastSeen BACKWARDS: a record that is already older than the
    -- window is left exactly as it is.
    if (out.lastSeen or 0) > backdated then out.lastSeen = backdated end
    return out
end

function Mesh.LogoutFlush()
    if not Mesh.IsEnabled() then return end
    local nameRealm = selfNameRealm()
    local rec = Store.GetCharacter and Store.GetCharacter(nameRealm)
    if not rec then return end
    local t = now()
    -- A9.1: LogoutRecord already shallow-copies; WireRecord copies again and
    -- stamps the send-time remaining onto the frozen u16 fields.
    local payload = Protocol.EncodeCharacter(Mesh.WireRecord(Mesh.LogoutRecord(rec, t), t))
    if not payload then return end

    -- Order peers by most-recently-seen first.
    local ordered = {}
    for aid, p in pairs(Mesh.peers) do
        if p.online and p.name then ordered[#ordered + 1] = p end
    end
    table.sort(ordered, function(a, b)
        return (a.lastSeen or 0) > (b.lastSeen or 0)
    end)

    -- Pass 1: the LOGOUT notice, to every peer, BEFORE any state. Same prefix and
    -- priority as the state fan-out, and the scheduler is FIFO within a priority,
    -- so all notices are on the wire ahead of all state frames. Unsequenced
    -- (seq 0) so Mesh.FreshSeq can never stale-drop the one frame whose whole job
    -- is to arrive. Peers running a build without OP.LOGOUT ignore it silently.
    for i = 1, #ordered do
        local frame = Mesh.BuildFrame(OP.LOGOUT, "", { seq = 0 })
        Mesh.Enqueue(Protocol.PREFIX.STATE, frame, {
            op = "state", chatType = "WHISPER", target = ordered[i].name, seq = 0,
        })
    end

    -- Pass 2: expanded budget on logout — whisper ALL peers directly, most-recent
    -- first, with the backdated record.
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
-- find each other: it is a PRESENCE beacon whose roster + JOIN/LEAVE notices
-- drive our whisper discovery (see §Presence roster). The catch is timing —
-- JoinTemporaryChannel silently no-ops in the first few seconds after
-- login/reload (the chat system isn't ready), so a one-shot join at
-- PLAYER_LOGIN leaves GetChannelName() == 0 forever and we never see the
-- roster. So we drive the join through a small retry state
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

-- Post-joined re-verification (pure). A tick that returned "joined" may have
-- trusted a stale pre-reload snapshot; re-read the LIVE index once more:
--   "ok"      -- index still resolves; membership is real, refresh st.index
--   "dropped" -- index is gone; caller must restart a fresh join sequence
--   "noop"    -- state is not in the joined phase (nothing to verify)
function Mesh.JoinReverify(st, deps)
    if not st or not st.joined then return "noop" end
    local idx = deps.getIndex(st.chanName) or 0
    if idx > 0 then
        st.index = idx
        return "ok"
    end
    return "dropped"
end

-- Continuous health-check decision (pure). Should the heartbeat loop re-kick a
-- join? Only when the live channel is gone, no retry loop is already working it,
-- and we are past the cooldown since the last sequence start (so a persistently
-- dead channel is re-attempted at most once per cooldown, never hammered).
function Mesh.ShouldHealthRejoin(liveIdx, inFlight, nowT, lastSeqStart, cooldown)
    if liveIdx and liveIdx > 0 then return false end   -- channel healthy
    if inFlight then return false end                  -- a live loop owns it
    cooldown = cooldown or Mesh.JOIN_HEALTH_COOLDOWN
    if (nowT or 0) - (lastSeqStart or 0) < cooldown then return false end
    return true
end

-- A join sequence is "in flight" while its state exists and is neither resolved
-- (joined) nor exhausted (gaveUp) — i.e. the retry loop is still ticking.
function Mesh.SeqInFlight()
    local st = Mesh._joinState
    return st ~= nil and not st.joined and not st.gaveUp
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
    Mesh._lastJoinAttempt = now()
    if JoinTemporaryChannel then JoinTemporaryChannel(chanName) end
end

-- Announce ourselves once the channel index first resolves: sweep the roster and
-- whisper a discovery ping to everyone already present, so we converge with peers
-- who joined before us instead of waiting for the next 17-23s heartbeat.
function Mesh.OnChannelResolved()
    ns:SafeCall(Mesh.PingRoster)
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
        -- Never trust the single snapshot that flipped us to "joined": schedule
        -- one re-verification. On a /reload the index we just read is the stale
        -- pre-reload membership and will drop within seconds; the re-check
        -- restarts a fresh sequence if the channel is actually gone.
        if C_Timer and C_Timer.After then
            C_Timer.After(Mesh.JOIN_REVERIFY_DELAY,
                function() ns:SafeCall(Mesh._reverifyJoin, gen) end)
        end
    elseif action == "retry" then
        if C_Timer and C_Timer.After then
            C_Timer.After(delay or 5, function() ns:SafeCall(Mesh._runJoinTick, gen) end)
        end
    end
    -- "gaveup"/"noop": stop the loop. The heartbeat GUILD fallback keeps
    -- same-guild peers converging even without the channel; the heartbeat health
    -- check (Mesh.HealthCheckChannel) re-attempts a dead channel on a cooldown.
end

-- Re-verify a state that reached "joined". Fenced by generation so a newer
-- sequence cancels a stale re-check. If the live index has dropped to 0 (the
-- classic /reload race, or a mid-session kick), restart a fresh sequence.
function Mesh._reverifyJoin(gen)
    if gen ~= Mesh._joinGen then return end   -- superseded by a newer sequence
    local st = Mesh._joinState
    local result = Mesh.JoinReverify(st, {
        getIndex = getChannelIndex,
        doJoin   = doJoinChannel,
    })
    if result == "dropped" then
        Mesh.StartJoinSequence()
    end
end

-- Continuous self-healing: called each heartbeat tick. If the mesh is live but
-- the discovery channel index has fallen to 0 and no retry loop is currently
-- working it, re-drive the join — but no more than once per JOIN_HEALTH_COOLDOWN
-- so a genuinely dead channel is retried gently, not hammered.
function Mesh.HealthCheckChannel()
    if not Mesh.IsEnabled() then return end
    local chanName = Mesh.GetChannelName()
    if not chanName then return end
    local liveIdx = getChannelIndex(chanName)
    if Mesh.ShouldHealthRejoin(liveIdx, Mesh.SeqInFlight(), now(),
                               Mesh._lastSeqStart, Mesh.JOIN_HEALTH_COOLDOWN) then
        Mesh.StartJoinSequence()
    end
end

-- Start (or restart) the join sequence. Bumping the generation token retires
-- any retry loop OR pending re-verification still in flight, so parallel loops
-- can never compound. We ALWAYS run the verified tick loop now — the old fast
-- path that trusted a single getChannelIndex>0 snapshot and marked us
-- permanently joined was the /reload trap: during the loading screen the client
-- reports the stale pre-reload membership, so that snapshot lied and the retry
-- loop never ran. The tick's own getIndex check still resolves the genuinely-
-- still-joined case in one step, and the post-joined re-verification (scheduled
-- by _runJoinTick) catches the stale-snapshot case and restarts.
function Mesh.StartJoinSequence()
    if not Mesh.IsEnabled() then return end
    local chanName = Mesh.GetChannelName()
    if not chanName then return end
    Mesh._joinGen = Mesh._joinGen + 1
    Mesh._lastSeqStart = now()
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

-- Return true if `channelBaseName` names OUR discovery channel.
local function isOurChannel(channelBaseName)
    local chanName = Mesh.GetChannelName()
    if not chanName then return false end
    local base = channelBaseName and tostring(channelBaseName):lower() or ""
    return base ~= "" and base == chanName:lower()
end

-- CHAT_MSG_CHANNEL_JOIN handler: a specific character just joined our presence
-- channel. Whisper THEM a discovery ping directly (the join notice hands us the
-- name), throttled by the per-name cooldown so a flapping joiner can't storm us.
-- Ignores our own join and joins on unrelated channels.
function Mesh.OnChannelJoinNotice(playerName, channelBaseName)
    if not Mesh.IsEnabled() then return end
    if not isOurChannel(channelBaseName) then return end
    if not playerName or playerName == "" then return end
    if Mesh.IsSelfSender(playerName) then return end
    local t = now()
    if not Mesh.ShouldPingName(playerName, Mesh._pingCooldowns, t, Mesh.ROSTER_PING_COOLDOWN) then
        return
    end
    Mesh._pingCooldowns[playerName] = t
    ns:SafeCall(Mesh.SendDiscovery, OP.PING, playerName)
end

-- CHAT_MSG_CHANNEL_LEAVE handler: a character left our presence channel. Mark
-- any peer with that name offline (presence-driven offline detection augmenting
-- the heartbeat timeout). Ignores our own leave and unrelated channels.
function Mesh.OnChannelLeaveNotice(playerName, channelBaseName)
    if not Mesh.IsEnabled() then return end
    if not isOurChannel(channelBaseName) then return end
    if not playerName or playerName == "" then return end
    if Mesh.IsSelfSender(playerName) then return end
    Mesh.MarkPresenceStale(playerName)
end

-- Flag every peer matching `name` as offline (presence gone). Best-effort name
-- match against the peer table; the heartbeat path (NotePeer) re-flips it online
-- on return. `presenceStaleAt` stamps WHEN the latch was set so TouchPeerByName
-- can refuse to clear it from frames that were already in flight when it landed
-- (see Mesh.StaleLatchHolds). Returns the number of peer entries latched.
function Mesh.MarkPresenceStale(name, t)
    t = t or now()
    local n = 0
    for _, p in pairs(Mesh.peers) do
        if Mesh.PeerNameMatches(p, name) then
            p.online = false
            p.presenceStale = true
            p.presenceStaleAt = t
            n = n + 1
        end
    end
    return n
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
    -- Ignore our own echoes (guild/raid/yell/whisper sends can loop back). All
    -- mesh data now arrives by WHISPER (channel="WHISPER") or guild fallback;
    -- the presence channel carries no addon data, so there is no CHANNEL path.
    if Mesh.IsSelfSender(sender) then return end
    -- Spec §2.2: stamp the sender's liveness on RAW RECEIVE, before any framing
    -- or payload validation — a chunk that never completes still proves the peer
    -- is alive and must not be swept by the 30s timeout.
    Mesh.TouchPeerByName(sender, now())
    -- De-envelope, reassemble, then dispatch.
    local env = Mesh.DeEnvelope(text)
    if not env then return end
    local frame = Mesh.FeedChunk(sender, prefix, env, now())
    if frame then
        ns:SafeCall(Mesh.Dispatch, prefix, frame, sender)
    end
end

function Mesh.OnLogin()
    -- Session id prefixes every message id (MakeMessageId) and now DRIVES the
    -- per-session seq reset in FreshSeq, so two consecutive sessions producing the
    -- same id would defeat the reload fix. Pure random(1,2^24) had a small but real
    -- birthday collision chance across relogs; mix wall-clock seconds with a random
    -- jitter so the common rapid-reload case can never collide (time advances) and
    -- sub-second reloads are separated by the jitter. No determinism need here — the
    -- id is intentionally unique-per-session, never reproduced. Product stays well
    -- under 2^53 so toBase36 is exact (time ~1.8e9 * 8192 + jitter < 1.5e13).
    local t = math.floor(((Store and Store.Now and Store.Now())
        or (time and time()) or 0))
    local jitter = (math.random and math.random(0, 8191)) or 0
    Mesh._sessionId = t * 8192 + jitter
    if Mesh._sessionId <= 0 then Mesh._sessionId = jitter + 1 end

    -- Subscribe to inbound addon messages.
    ns:RegisterEvent("CHAT_MSG_ADDON", onChatMsgAddon)

    -- PLAYER_ENTERING_WORLD drives the channel join (fires on initial login AND
    -- every /reload; the handler self-guards on IsEnabled). This is the fix for
    -- the "no peers known" bug: a one-shot join at login lands before the chat
    -- system is ready, so we (re)drive a verified retry loop here instead.
    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function(_, isInitialLogin, isReloadingUi)
        ns:SafeCall(Mesh.OnEnteringWorld, isInitialLogin, isReloadingUi)
    end)

    -- Newcomer convergence: whisper-ping whoever joins our presence channel.
    -- CHAT_MSG_CHANNEL_JOIN / _LEAVE args (1-indexed): text, playerName(2),
    -- languageName, channelName, playerName2, specialFlags, zoneChannelID,
    -- channelIndex, channelBaseName(9). (catalog events.txt:246/247)
    ns:RegisterEvent("CHAT_MSG_CHANNEL_JOIN", function(_, ...)
        local playerName      = select(2, ...)
        local channelBaseName = select(9, ...)
        ns:SafeCall(Mesh.OnChannelJoinNotice, playerName, channelBaseName)
    end)

    -- Presence-driven offline detection: mark peers stale when they leave.
    ns:RegisterEvent("CHAT_MSG_CHANNEL_LEAVE", function(_, ...)
        local playerName      = select(2, ...)
        local channelBaseName = select(9, ...)
        ns:SafeCall(Mesh.OnChannelLeaveNotice, playerName, channelBaseName)
    end)

    -- Push live state changes onto the mesh (self-record-guarded).
    ns:On("STATE_CHANGED", function(nameRealm, record, force, receipt)
        Mesh.OnStateChanged(nameRealm, record, force, receipt)
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
                -- Self-heal channel membership against any drop (reload race,
                -- server kick, zone transition) before we advertise on it.
                ns:SafeCall(Mesh.HealthCheckChannel)
                -- Slow presence sweep (gated to ROSTER_SWEEP_INTERVAL) catches
                -- members whose JOIN notice we missed; then heartbeat known peers.
                ns:SafeCall(Mesh.MaybeRosterSweep)
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
    local reason = Mesh.DisabledReason()
    ns:Print("mesh: " .. (reason == nil and "ENABLED" or ("disabled — " .. reason))
        .. " | account " .. (ns:GetAccountID() ~= "" and ns:GetAccountID() or "<unset>"))

    -- Same-faction constraint (item 20): custom chat channels are faction-bound,
    -- so only same-faction characters can converge on the mesh channel. This is
    -- the clear answer to "why aren't my other accounts meshing?" for a
    -- cross-faction login — no error, they simply never share the channel.
    local myFaction = (UnitFactionGroup and UnitFactionGroup("player")) or "?"
    ns:Print("  faction: " .. tostring(myFaction)
        .. " | mesh is SAME-FACTION only (custom channels are faction-bound — log"
        .. " same-faction characters to mesh accounts together)")

    -- Channel mode (item 38): the channel is a required user-set credential; it
    -- is printed plainly (masking is a UI concern).
    local m = Mesh.MeshSettings() or {}
    local rawChan = m.channel or ""
    ns:Print("  channel-cred: " .. (rawChan ~= "" and rawChan or "<not set>")
        .. (Mesh.ValidateChannel(rawChan) and " (valid)" or " (INVALID — need 16+ alphanumeric)"))

    -- Channel join diagnostics — the heart of the "no peers known" smoke test.
    -- The LIVE index is the single source of truth for "joined" so this line can
    -- no longer self-contradict; the state machine's phase is reported SEPARATELY
    -- (a stale loop can say "joined" while the live channel is gone — that
    -- mismatch is exactly what we want to see, not paper over).
    local chanName = Mesh.GetChannelName()
    local liveIdx = 0
    if chanName and GetChannelName then liveIdx = GetChannelName(chanName) or 0 end
    local st = Mesh._joinState
    local liveStr = (liveIdx and liveIdx > 0) and ("index " .. liveIdx) or "NOT JOINED"
    local loop
    if not st then loop = "idle"
    elseif st.gaveUp then loop = "gaveup"
    elseif st.joined then loop = "joined"
    elseif (st.attempts or 0) > 0 then loop = "joining(" .. st.attempts .. ")"
    else loop = "idle" end
    ns:Print(string.format("  channel: %s | live=%s | loop=%s | lastJoinAttempt=%s",
        chanName or "<none>", liveStr, loop, tostring(Mesh._lastJoinAttempt or 0)))

    -- Discovery ping/pong telemetry (0 == never).
    local d = Mesh._disco or {}
    ns:Print(string.format("  discovery: pingSent=%s pongRecv=%s pingRecv=%s pongSent=%s",
        tostring(d.lastPingSent or 0), tostring(d.lastPongRecv or 0),
        tostring(d.lastPingRecv or 0), tostring(d.lastPongSent or 0)))

    -- Presence roster: live channel members (up to 5 names) + last sweep time.
    local roster = {}
    if liveIdx and liveIdx > 0 then roster = Mesh.ChannelRoster(liveIdx) end
    local shown = {}
    for i = 1, math.min(5, #roster) do shown[i] = roster[i] end
    ns:Print(string.format("  roster: members=%d [%s] lastSweep=%s",
        #roster, table.concat(shown, ", "), tostring(Mesh._lastRosterSweep or 0)))

    local n = 0
    for aid, p in pairs(Mesh.peers) do
        n = n + 1
        local why = p.timedOut and " (30s-timeout)"
            or (p.presenceStale and " (left/logout)") or ""
        -- Show whether the stale latch is still HOLDING: that is the difference
        -- between "this pip is grey and will stay grey" and "the next frame from
        -- them re-greens it", which is the whole logout-pip question.
        if p.presenceStale and Mesh.StaleLatchHolds(p, now()) then
            why = why .. string.format(" holding %.0fs",
                (p.presenceStaleAt or 0) + Mesh.PRESENCE_STALE_HOLD - now())
        end
        ns:Print(string.format("  peer %s (%s) online=%s%s lastSeen=%s silent=%ss",
            aid, p.name or "?", tostring(p.online), why,
            tostring(p.lastSeen or 0), tostring(now() - (p.lastSeen or 0))))
    end
    if n == 0 then ns:Print("  no peers known.") end
    -- A10.1 / A10.8 / A1.3 telemetry: how much traffic the filters removed.
    ns:Print(string.format(
        "  filters: pushSuppressed=%d capturesFiltered=%d relayAgeDrops=%d lastPeerSweep=%s",
        Mesh._pushSuppressed or 0,
        (ns.Tracker and ns.Tracker._capturesFiltered) or 0,
        Mesh._relayAgeDrops or 0, tostring(Mesh._lastPeerSweep or 0)))
    for prefix, s in pairs(Mesh._sched) do
        ns:Print(string.format("  prefix %s: queue=%d bucket=%.1f/%d",
            prefix, s.queue:Size(), s.bucket.tokens, s.bucket.cap))
    end
    local seen = 0
    for _ in pairs(Mesh._seenIds) do seen = seen + 1 end
    -- Bookkeeping-map sizes: these three used to grow without bound, so their
    -- counts are the cheapest proof the sweeps are running.
    local inSeqN, ackN, cdN = 0, 0, 0
    for _ in pairs(Mesh._inSeq) do inSeqN = inSeqN + 1 end
    for _ in pairs(Mesh._ackWait) do ackN = ackN + 1 end
    for _ in pairs(Mesh._sendCooldowns) do cdN = cdN + 1 end
    ns:Print(string.format(
        "  maps: dedup=%d inSeq=%d ackWait=%d sendCooldowns=%d | sendsGated=%d bcastCancelled=%d",
        seen, inSeqN, ackN, cdN, Mesh._sendGated or 0, Mesh._bcastCancelled or 0))
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

-- Instance-ledger hash: order-independent over characters, deterministic over
-- entries, and sensitive to a divergence in t / name / merged (so a heartbeat
-- mismatch trips the instances sync). Empty/absent -> "0".
local function testInstancesHash()
    if Mesh.HashInstances(nil) ~= "0" then return false, "nil ledger not '0'" end
    if Mesh.HashInstances({}) ~= "0" then return false, "empty ledger not '0'" end
    local a = { ["A-R"] = { entries = { { t = 1, name = "MC", merged = false } } },
                ["B-R"] = { entries = { { t = 2, name = "ZG", merged = true  } } } }
    -- Same content, characters inserted in the other order -> identical hash.
    local b = { ["B-R"] = { entries = { { t = 2, name = "ZG", merged = true  } } },
                ["A-R"] = { entries = { { t = 1, name = "MC", merged = false } } } }
    if Mesh.HashInstances(a) ~= Mesh.HashInstances(b) then
        return false, "char-order changed the hash"
    end
    -- A merged-flag flip must change the hash.
    local c = { ["A-R"] = { entries = { { t = 1, name = "MC", merged = true } } },
                ["B-R"] = { entries = { { t = 2, name = "ZG", merged = true } } } }
    if Mesh.HashInstances(a) == Mesh.HashInstances(c) then
        return false, "merged-flag flip not detected"
    end
    -- A new entry must change the hash.
    local d = { ["A-R"] = { entries = { { t = 1, name = "MC", merged = false },
                                        { t = 3, name = "MC", merged = false } } },
                ["B-R"] = { entries = { { t = 2, name = "ZG", merged = true } } } }
    if Mesh.HashInstances(a) == Mesh.HashInstances(d) then
        return false, "added entry not detected"
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
    -- (a) Same-session ordering: duplicate + stale rejected, newer accepted,
    -- unsequenced (seq 0) always passes. sess held constant = "A".
    Mesh._inSeq = {}
    if not Mesh.FreshSeq("S", 5, "A") then return false, "first seq rejected" end
    if Mesh.FreshSeq("S", 5, "A") then return false, "duplicate seq accepted" end
    if Mesh.FreshSeq("S", 4, "A") then return false, "stale seq accepted" end
    if not Mesh.FreshSeq("S", 6, "A") then return false, "newer seq rejected" end
    if not Mesh.FreshSeq("S", 0, "A") then return false, "unsequenced op rejected" end
    -- (a) explicit: seq 5 then 3 within one session -> the 3 must drop.
    Mesh._inSeq = {}
    if not Mesh.FreshSeq("S", 5, "A") then return false, "seq5 rejected" end
    if Mesh.FreshSeq("S", 3, "A") then return false, "stale seq3 accepted after 5" end

    -- (b) Sender SESSION RESTART: a high seq on session A, then seq 1 on session B
    -- (a /reload reset the sender's counter) MUST be accepted, not stale-dropped.
    -- This is the exact wedge the fix targets.
    Mesh._inSeq = {}
    if not Mesh.FreshSeq("S", 900, "A") then return false, "sessA seq900 rejected" end
    if not Mesh.FreshSeq("S", 1, "B") then return false, "sessB seq1 stale-dropped (the bug)" end
    -- ...and ordering resumes within the new session.
    if not Mesh.FreshSeq("S", 2, "B") then return false, "sessB seq2 rejected" end
    if Mesh.FreshSeq("S", 1, "B") then return false, "sessB seq1 replay accepted" end
    -- A late straggler from the OLD session (higher seq, old sess) is treated as a
    -- session switch back and accepted once — acceptable: sessions don't interleave
    -- in practice, and the alternative (tracking every past session) is unbounded.
    if not Mesh.FreshSeq("S", 950, "A") then return false, "session switch not adopted" end

    -- (c) Cross-prefix independence: Dispatch keys FreshSeq by sender.."\1"..prefix,
    -- so a low seq on one prefix must not be staled by a high seq on another.
    Mesh._inSeq = {}
    if not Mesh.FreshSeq("Sndr\1P1", 10, "A") then return false, "prefix1 seq rejected" end
    if not Mesh.FreshSeq("Sndr\1P2", 4, "A") then return false, "prefix2 low seq wrongly staled" end
    if Mesh.FreshSeq("Sndr\1P1", 4, "A") then return false, "prefix1 stale accepted" end
    if not Mesh.FreshSeq("Sndr\1P2", 5, "A") then return false, "prefix2 newer rejected" end
    return true
end

-- (d) A malformed msgId must not crash Dispatch and must still route to its
-- handler. Also covers the session-token extractor directly.
local function testMalformedMsgId()
    if Mesh._SessionOfMsgId("7-a-b") ~= "a" then return false, "session token misparsed" end
    if Mesh._SessionOfMsgId("12-zz-1") ~= "zz" then return false, "2-digit aid misparsed" end
    if Mesh._SessionOfMsgId("garbage") ~= "?" then return false, "no-dash id not '?'" end
    if Mesh._SessionOfMsgId(nil) ~= "?" then return false, "nil id not '?'" end
    if Mesh._SessionOfMsgId("7-a-b-c") ~= "?" then return false, "overlong id not '?'" end
    if Mesh._SessionOfMsgId("7--b") ~= "?" then return false, "empty session not '?'" end

    -- Hand-build a SETTINGS frame with a deliberately malformed msgId and dispatch
    -- it; the handler fires MESH_SETTINGS_RECEIVED, giving an observable hook.
    local got = false
    ns:On("MESH_SETTINGS_RECEIVED", function() got = true end)
    Mesh._inSeq = {}; Mesh._seenIds = {}
    local payload = Mesh.Pack({ syncId = "mal-test" })
    if not payload then return false, "pack unavailable (harness lib gap)" end
    local frame = table.concat({
        Mesh.PROTO_VERSION, Mesh.OP.SETTINGS, "garbage", "1", "", payload
    }, "\t")
    local ok = pcall(Mesh.Dispatch, Protocol.PREFIX.SYNC, frame, "Mal-Sender")
    if not ok then return false, "Dispatch crashed on malformed msgId" end
    if not got then return false, "malformed-id frame did not dispatch" end
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

-- Reload race: the first membership snapshot is the STALE pre-reload channel
-- (index > 0) and every read afterwards is 0 as the temporary channel drops.
-- Prove the machine does NOT get stuck "joined": the post-joined re-verification
-- detects the drop and a fresh sequence re-issues the join until a real index
-- resolves. Drives the pure JoinAdvance + JoinReverify exactly as the live
-- _runJoinTick / _reverifyJoin wrappers do, minus the C_Timer scheduling.
local function testReloadRace()
    -- Scripted live-index reads, in call order:
    --   1) 4  -> tick1 trusts stale pre-reload membership -> "joined" (no join)
    --   2) 0  -> re-verify: channel dropped -> "dropped" -> restart
    --   3) 0  -> new tick1: still not ready -> issue join#1, retry
    --   4) 7  -> new tick2: real index resolves -> "joined"
    local seq, i, joins = { 4, 0, 0, 7 }, 0, 0
    local deps = {
        getIndex = function() i = i + 1; return seq[i] or 0 end,
        doJoin   = function() joins = joins + 1 end,
        maxTries = 3, delays = { 5, 7, 10 },
    }

    local st = Mesh.NewJoinState("dsnX")
    local a1 = Mesh.JoinAdvance(st, deps)          -- reads 4
    if a1 ~= "joined" then return false, "race tick1: expected joined, got " .. tostring(a1) end
    if joins ~= 0 then return false, "race tick1: should not have issued a join" end
    if not st.joined then return false, "race tick1: joined flag not set" end

    local rv = Mesh.JoinReverify(st, deps)         -- reads 0
    if rv ~= "dropped" then return false, "race reverify: expected dropped, got " .. tostring(rv) end

    -- Restart (what _reverifyJoin does on "dropped"): fresh state, same deps.
    st = Mesh.NewJoinState("dsnX")
    local b1 = Mesh.JoinAdvance(st, deps)          -- reads 0 -> join#1
    if b1 ~= "retry" then return false, "race re-tick1: expected retry, got " .. tostring(b1) end
    if joins ~= 1 then return false, "race re-tick1: expected 1 join, got " .. tostring(joins) end
    local b2 = Mesh.JoinAdvance(st, deps)          -- reads 7 -> joined
    if b2 ~= "joined" then return false, "race re-tick2: expected joined, got " .. tostring(b2) end
    if st.index ~= 7 then return false, "race: resolved index wrong: " .. tostring(st.index) end

    -- And a re-verify on the REAL join confirms it stays put (no false restart).
    local seq2, j = { 7 }, 0
    local okDeps = { getIndex = function() j = j + 1; return seq2[j] or 7 end, doJoin = function() end }
    if Mesh.JoinReverify(st, okDeps) ~= "ok" then return false, "race: genuine join falsely dropped" end

    return true
end

-- Mid-session drop: the channel index falls to 0 long after login (server kick,
-- zone transition). Prove the heartbeat health check re-kicks a join — but only
-- when nothing else is working it and only once per cooldown. Pure decision fn,
-- so no timers needed.
local function testHealthCheck()
    local CD = Mesh.JOIN_HEALTH_COOLDOWN
    -- Healthy channel (index up) -> never rejoin.
    if Mesh.ShouldHealthRejoin(3, false, 1000, 900, CD) then
        return false, "health: rejoined a healthy channel"
    end
    -- Dropped, idle loop, cooldown elapsed -> rejoin (the recovery case).
    if not Mesh.ShouldHealthRejoin(0, false, 1000, 1000 - CD, CD) then
        return false, "health: failed to recover a mid-session drop"
    end
    -- Dropped but a retry loop is already in flight -> don't stomp it.
    if Mesh.ShouldHealthRejoin(0, true, 5000, 0, CD) then
        return false, "health: stomped an in-flight sequence"
    end
    -- Dropped but still inside the cooldown window -> hold off (no hammering).
    if Mesh.ShouldHealthRejoin(0, false, 1000, 1000 - (CD - 1), CD) then
        return false, "health: rejoined inside the cooldown window"
    end
    -- SeqInFlight reflects the live state machine phases.
    local saved = Mesh._joinState
    Mesh._joinState = nil
    if Mesh.SeqInFlight() then return false, "inFlight: nil state should be false" end
    Mesh._joinState = { attempts = 2, joined = false, gaveUp = false }
    if not Mesh.SeqInFlight() then return false, "inFlight: mid-retry should be true" end
    Mesh._joinState = { joined = true }
    if Mesh.SeqInFlight() then return false, "inFlight: joined should be false" end
    Mesh._joinState = { gaveUp = true }
    if Mesh.SeqInFlight() then return false, "inFlight: gaveUp should be false" end
    Mesh._joinState = saved
    return true
end

-- Roster ping-selection: given a channel roster, our name, the known-peer set
-- and per-name cooldowns, prove we ping exactly the eligible strangers and skip
-- self, known peers, cooled-down names, and empty rows.
local function testRosterPingSelection()
    local roster = { "Self-R", "Ally-R", "Ally2-R", "Known-R", "" }
    local known = { ["Known-R"] = true }
    local cooldowns = { ["Ally2-R"] = 100 }
    -- now=110, window=30: self out, known out, Ally2 in cooldown (10<30) -> Ally-R only.
    local sel = Mesh.SelectRosterPings(roster, "Self-R", known, cooldowns, 110, 30)
    if #sel ~= 1 or sel[1] ~= "Ally-R" then
        return false, "sweep1 wrong: " .. table.concat(sel, ",")
    end
    -- now=140: Ally2 cooldown expired (40>=30) -> Ally-R then Ally2-R (roster order).
    local sel2 = Mesh.SelectRosterPings(roster, "Self-R", known, cooldowns, 140, 30)
    if #sel2 ~= 2 or sel2[1] ~= "Ally-R" or sel2[2] ~= "Ally2-R" then
        return false, "sweep2 wrong: " .. table.concat(sel2, ",")
    end
    -- empty roster -> nothing.
    if #Mesh.SelectRosterPings({}, "Self-R", known, cooldowns, 200, 30) ~= 0 then
        return false, "empty roster produced pings"
    end
    -- nil cooldown map -> every stranger eligible (self + known still excluded).
    local sel3 = Mesh.SelectRosterPings(roster, "Self-R", known, nil, 0, 30)
    if #sel3 ~= 2 then return false, "nil-cooldown count wrong: " .. #sel3 end
    return true
end

-- Join-notice throttle: the per-name cooldown gate that fires on CHANNEL_JOIN.
local function testJoinNoticeThrottle()
    local cd = {}
    if not Mesh.ShouldPingName("New-R", cd, 100, 30) then return false, "first ping blocked" end
    cd["New-R"] = 100   -- record as the live handler does after pinging
    if Mesh.ShouldPingName("New-R", cd, 120, 30) then return false, "cooldown not honoured" end
    if not Mesh.ShouldPingName("New-R", cd, 130, 30) then return false, "cooldown edge blocked" end
    if Mesh.ShouldPingName("", cd, 200, 30) then return false, "empty name pinged" end
    if Mesh.ShouldPingName(nil, cd, 200, 30) then return false, "nil name pinged" end
    return true
end

-- TRANSMIT-SAFETY: the SN prefixes must be un-sendable through every path.
local function testTransmitSafety()
    -- Predicate covers all five SN prefixes (+ legacy SNT), rejects ours + NWB.
    for _, p in ipairs({ "SDWW", "SNT", "SDWZ", "SDWY", "SDWX" }) do
        if not Mesh.IsForbiddenTxPrefix(p) then
            return false, "SN prefix not forbidden: " .. p
        end
    end
    for _, p in ipairs({ "DSKN0", "DSKN1", "DSKN2", "DSKN3", "NWB", "D5" }) do
        if Mesh.IsForbiddenTxPrefix(p) then
            return false, "non-SN prefix wrongly forbidden: " .. p
        end
    end
    -- rawSend refuses an SN prefix and never reaches C_ChatInfo (increments
    -- the block counter; returns false as a "did-not-send" to callers).
    local before = Mesh._forbiddenTxBlocked or 0
    local sent = Mesh._rawSend("SDWW", "any-wire", "GUILD", nil)
    if sent ~= false then return false, "rawSend did not refuse SDWW" end
    if (Mesh._forbiddenTxBlocked or 0) ~= before + 1 then
        return false, "block telemetry did not advance on rawSend"
    end
    -- Enqueue drops an SN prefix before it can reach any scheduler queue.
    Mesh.Enqueue("SDWZ", "1\tz\tmid\t0\t\tpayload", { op = "timer" })
    if Mesh._sched["SDWZ"] then return false, "SN prefix created a scheduler" end
    return true
end

-- Snapshot request reply routes a peer snapshot into the registered handler.
-- The wire (de)serialization is LibDeflate's responsibility and is exercised
-- in-game; here we isolate the handoff dispatch by feeding the snapshot table
-- straight through Unpack, so the test validates OUR routing under any VM.
local function testSnapshotHandoff()
    local captured
    local savedHandler, savedUnpack = Mesh._snapHandler, Mesh.Unpack
    Mesh.SetSnapshotHandler(function(snap, sender) captured = { snap = snap, sender = sender } end)
    local snap = { buffs = { rend = { lastPop = 1500000000, trust = "local" } },
                   flower = { [1] = 1500000123 }, tuber = {}, at = 1500000200 }
    Mesh.Unpack = function() return snap end
    Mesh._handleTimerSnap({ payload = "wire" }, "Peer-Realm")
    Mesh.Unpack, Mesh._snapHandler = savedUnpack, savedHandler
    if not captured then return false, "handler not invoked" end
    if captured.sender ~= "Peer-Realm" then return false, "sender not passed" end
    if not (captured.snap and captured.snap.buffs and captured.snap.buffs.rend
            and captured.snap.buffs.rend.lastPop == 1500000000) then
        return false, "snapshot not delivered"
    end
    if captured.snap.flower[1] ~= 1500000123 then return false, "flower epoch lost" end
    return true
end

-- STATE_CHANGED contract guard: nil/foreign records must not push or crash.
local function testStateChangedGuard()
    -- Encoder defends against non-table input (the import.lua crash root cause).
    if Protocol.EncodeCharacter(nil) ~= nil then return false, "EncodeCharacter(nil) not nil" end
    if Protocol.EncodeCharacter("import") ~= nil then return false, "EncodeCharacter(string) not nil" end
    -- IsSelfRecord rejects nil and other-account records.
    if Mesh.IsSelfRecord("import", nil) ~= false then return false, "nil record judged self" end
    if Mesh.IsSelfRecord("Foreign-Realm", { nameRealm = "Foreign-Realm" }) ~= false then
        return false, "foreign record judged self"
    end
    -- OnStateChanged must not push a nil or foreign record (spy on PushState).
    local pushed = 0
    local savedPush = Mesh.PushState
    Mesh.PushState = function() pushed = pushed + 1 end
    Mesh.OnStateChanged("import", nil)                                     -- stray args-free fire
    Mesh.OnStateChanged("Foreign-Realm", { nameRealm = "Foreign-Realm" })  -- other-account record
    Mesh.PushState = savedPush
    if pushed ~= 0 then return false, "nil/foreign record was pushed to mesh" end
    -- STORE_REFRESHED is a distinct, args-free signal the mesh ignores but the
    -- callback bus still delivers (dashboard/HUD subscribe to repaint).
    local refreshed = 0
    ns:On("STORE_REFRESHED", function() refreshed = refreshed + 1 end)
    ns:Fire("STORE_REFRESHED")
    if refreshed ~= 1 then return false, "STORE_REFRESHED not delivered by the bus" end
    return true
end

-- Channel-credential gating (item 38): validation + enable-matrix over
-- no-channel / short-channel / valid-channel while token + AID are present.
local function testChannelGating()
    -- Pure validator.
    if Mesh.ValidateChannel("shorty") ~= nil then return false, "short channel accepted" end
    if Mesh.ValidateChannel("has space innit here") ~= nil then return false, "spaced channel accepted" end
    if Mesh.ValidateChannel("bad!channel!name!!") ~= nil then return false, "non-alnum accepted" end
    if Mesh.ValidateChannel("MyGuildBuffChannel") ~= "MyGuildBuffChannel" then
        return false, "valid channel rejected"
    end
    -- Enable-matrix via a stubbed MeshSettings + AID.
    local savedMS, savedAID = Mesh.MeshSettings, ns.GetAccountID
    ns.GetAccountID = function() return "1" end
    local ms = { enabled = true, optOut = false, token = "tok" }
    Mesh.MeshSettings = function() return ms end
    ms.channel = ""
    local ok1 = (Mesh.DisabledReason() ~= nil) and not Mesh.IsEnabled()
    ms.channel = "tooshort"
    local ok2 = (Mesh.DisabledReason() ~= nil) and not Mesh.IsEnabled()
    ms.channel = "MyGuildBuffChannel"
    local ok3 = Mesh.IsEnabled() and (Mesh.DisabledReason() == nil)
    Mesh.MeshSettings, ns.GetAccountID = savedMS, savedAID
    if not ok1 then return false, "empty channel should disable mesh" end
    if not ok2 then return false, "short channel should disable mesh" end
    if not ok3 then return false, "valid channel + token + AID should enable mesh" end
    return true
end

----------------------------------------------------------------------
-- A9.1 — the wire boundary, end to end through the REAL binary codec.
--
-- protocol.lua is frozen: two u16 REMAINING-SECONDS fields, SCHEMA_VERSION
-- untouched. This proves the epoch model survives that round trip, that the
-- drift is exactly the transit delay, and that nothing about the frame changed.
----------------------------------------------------------------------
local function testItemCdWireBoundary()
    local T = 1785000500

    local live = Store.NewCharacterRecord("Daseeki-Faerlina")
    live.level, live.faction = 60, "Horde"
    live.lastSeen, live.lastDataUpdate, live.ownerEpoch = T, T, T
    live.hearthstoneCDStart = T - 1200          -- 40 min in: 2400 left
    live.chronoboonCDStart  = T - 3000          -- 50 min in:  600 left
    live.hearthstoneCD, live.itemCooldown = 0, 0   -- mirrors deliberately stale

    -- ENCODE at T+300, i.e. 5 minutes after the last capture.
    local SEND = T + 300
    local wire = Mesh.WireRecord(live, SEND)
    if live.hearthstoneCD ~= 0 or live.itemCooldown ~= 0 then
        return false, "WireRecord mutated the live Store record"
    end
    if wire.hearthstoneCD ~= 2100 then
        return false, "encode: hearth remaining not computed at SEND time (" .. tostring(wire.hearthstoneCD) .. ")"
    end
    if wire.itemCooldown ~= 300 then
        return false, "encode: chrono remaining not computed at SEND time (" .. tostring(wire.itemCooldown) .. ")"
    end

    local bytes = Protocol.EncodeCharacter(wire)
    if not bytes then return false, "wire record failed to encode" end
    local dec = Protocol.DecodeCharacter(bytes)
    if not dec then return false, "wire record failed to decode" end
    if dec.hearthstoneCD ~= 2100 or dec.itemCooldown ~= 300 then
        return false, "the u16 remaining fields did not survive the real codec"
    end

    -- DECODE with 4 s of transit. Store.WriteInboundCharacter is the real entry
    -- point; call the conversion it performs directly at a controlled clock.
    local RECV = SEND + 4
    Store.AdoptWireCooldowns(dec, RECV)
    if dec.hearthstoneCDStart ~= (T - 1200) + 4 then
        return false, "decode: reconstructed epoch is not late by exactly the transit delay"
    end
    -- The reconstructed countdown reads HIGH by the transit delay, and by
    -- nothing else — no clock skew can enter, because neither side trusts the
    -- other's epoch, only the duration arithmetic.
    local drift = Store.ItemCdRemaining(dec, "hearthstone", SEND) - 2100
    if drift ~= 4 then
        return false, "drift is not bounded by transit (" .. tostring(drift) .. "s)"
    end
    -- And it does not accumulate: the next push re-anchors from the owner again.
    local wire2 = Mesh.WireRecord(live, SEND + 600)
    local dec2 = Protocol.DecodeCharacter(Protocol.EncodeCharacter(wire2))
    Store.AdoptWireCooldowns(dec2, SEND + 600 + 4)
    if dec2.hearthstoneCDStart ~= (T - 1200) + 4 then
        return false, "drift accumulated across pushes"
    end

    -- A peer running the OLD build sends only the mirrors (no epoch fields at
    -- all) — it must still land as a usable local epoch.
    local oldPeer = { nameRealm = "Old-Realm", hearthstoneCD = 1800, itemCooldown = 0,
                      lastSeen = T, lastDataUpdate = T, ownerEpoch = T, level = 60 }
    local decOld = Protocol.DecodeCharacter(Protocol.EncodeCharacter(oldPeer))
    Store.AdoptWireCooldowns(decOld, T)
    if decOld.hearthstoneCDStart ~= T - 1800 then
        return false, "an old-build peer's remaining did not convert to an epoch"
    end

    -- A record with no cooldown at all round-trips as no cooldown.
    local idle = Store.NewCharacterRecord("Idle-Realm")
    idle.level, idle.lastSeen, idle.lastDataUpdate, idle.ownerEpoch = 60, T, T, T
    local decIdle = Protocol.DecodeCharacter(Protocol.EncodeCharacter(Mesh.WireRecord(idle, T)))
    Store.AdoptWireCooldowns(decIdle, T)
    if decIdle.hearthstoneCDStart ~= 0 or decIdle.hearthstoneCD ~= 0 then
        return false, "an idle record invented a cooldown at the boundary"
    end

    -- The SCHEMA is untouched: same version byte, same field order, same length
    -- for the same content.
    if Protocol.SCHEMA_VERSION ~= string.byte(bytes, 1) then
        return false, "encoded schema version byte does not match Protocol.SCHEMA_VERSION"
    end
    return true
end

----------------------------------------------------------------------
-- B4 — the manifest actually reaches the store's ghost cleanup.
-- (The rule matrix itself is tested in store.lua; this is the wiring.)
----------------------------------------------------------------------
local function testManifestWiring()
    local T = 1785000500
    local savedAccounts = Store.data.accounts
    local savedDeleted  = Store.data.deletedAIDs
    local savedPeers    = Store.data and Mesh.peers
    local savedLog      = Store._ghostLog
    Store._ghostLog = {}
    Mesh.peers = {}
    Store.data.deletedAIDs = {}
    Store.data.accounts = {
        ["9"] = { isSelf = false,
                  characters = { ["Keeper-R"] = { level = 60, ownerEpoch = T - 100 },
                                 ["Ghost-R"]  = { level = 60, ownerEpoch = T - 100 } },
                  segments = { sixties = {}, summoners = {}, norole = {} },
                  segmentHashes = { sixties = { epoch = T - 1000 } },
                  homeless = {} },
    }

    local payload = Mesh.Pack({ aid = "9", area = "sixties", list = { "Keeper-R" },
                                hash = "deadbeef", epoch = T })
    if not payload then
        Store.data.accounts, Store.data.deletedAIDs = savedAccounts, savedDeleted
        Mesh.peers, Store._ghostLog = savedPeers, savedLog
        return false, "manifest payload failed to pack"
    end
    local frame = Mesh.BuildFrame(Mesh.OP.MANIFEST, payload, {})
    local okCall, err = pcall(Mesh.Dispatch, Protocol.PREFIX.SYNC, frame, "Peer-Realm")

    local chars = Store.data.accounts["9"].characters
    local gone  = (chars["Ghost-R"] == nil)
    local kept  = (chars["Keeper-R"] ~= nil)
    local epoch = Store.data.accounts["9"].segmentHashes.sixties.epoch
    local logged = #Store._ghostLog

    Store.data.accounts, Store.data.deletedAIDs = savedAccounts, savedDeleted
    Mesh.peers, Store._ghostLog = savedPeers, savedLog

    if not okCall then return false, "manifest dispatch errored: " .. tostring(err) end
    if not gone then return false, "a received manifest did not ghost-clean the absent character" end
    if not kept then return false, "a received manifest deleted a character it names" end
    if epoch ~= T then return false, "the received manifest epoch was not stored" end
    if logged ~= 1 then return false, "the deletion was not written to the debug log" end
    return true
end

-- Account-ID conflict detection (item 18).
local function testAccountConflict()
    local savedAID, savedSelf = ns.GetAccountID, Mesh.IsSelfSender
    ns.GetAccountID = function() return "3" end
    Mesh.IsSelfSender = function(s) return s == "Me-Realm" end
    Mesh._conflictWarned = {}
    -- Peer heartbeat carrying OUR id from a different character => conflict.
    if not Mesh.CheckAccountConflict("3", "Other-Realm", 1000) then
        Mesh.GetAccountID = savedAID; return false, "shared AID not flagged"
    end
    -- Different id => no conflict.
    if Mesh.CheckAccountConflict("4", "Other-Realm", 1000) then
        ns.GetAccountID, Mesh.IsSelfSender = savedAID, savedSelf
        return false, "distinct AID wrongly flagged"
    end
    -- Our own echo of our id => not a conflict.
    if Mesh.CheckAccountConflict("3", "Me-Realm", 1000) then
        ns.GetAccountID, Mesh.IsSelfSender = savedAID, savedSelf
        return false, "self echo flagged as conflict"
    end
    ns.GetAccountID, Mesh.IsSelfSender = savedAID, savedSelf
    return true
end

-- Suite-namespace hash diff (wave N5): pull exactly the namespaces whose
-- advertised hash differs from ours; ignore matches and missing-local keys.
local function testNamespaceDiff()
    local localH  = { bags = "aaa", cfg = "bbb" }
    local remoteH = { bags = "aaa", cfg = "ZZZ", extra = "qqq" }
    local diffs = Mesh.DiffNamespaceHashes(localH, remoteH)
    -- cfg differs, extra is remote-only (local "0" != "qqq"), bags matches.
    local set = {}
    for _, k in ipairs(diffs) do set[k] = true end
    if set.bags then return false, "bags matched but flagged" end
    if not set.cfg then return false, "cfg divergence missed" end
    if not set.extra then return false, "remote-only namespace missed" end
    if #diffs ~= 2 then return false, "unexpected diff count " .. #diffs end
    -- identical bundles -> no diffs
    if #Mesh.DiffNamespaceHashes(localH, localH) ~= 0 then
        return false, "identical bundles produced diffs"
    end
    -- non-table remote -> empty
    if #Mesh.DiffNamespaceHashes(localH, nil) ~= 0 then
        return false, "nil remote produced diffs"
    end
    return true
end

-- A fresh push of our OWN owner must outrank bulk namespace backfill in the
-- scheduler. They share the wire op (OP.NSPAYLOAD) and used to share a
-- priority, so a gold change published just after login queued behind the
-- login-time backfill -- ~70 chunks on a real roster, draining at the SYNC
-- prefix's sustained 1 msg/sec. Both classes must still be known to the
-- bucket/burst tables, or DrainTick would charge them a default cost.
local function testNSPushPriority()
    local push, bulk = Mesh.PRIO_FOR("nspush"), Mesh.PRIO_FOR("nspayload")
    if not push or not bulk then return false, "nspush/nspayload priority missing" end
    if not (push < bulk) then
        return false, string.format("a fresh push (%d) does not outrank backfill (%d)", push, bulk)
    end
    -- ...but it must not jump ahead of presence/state traffic: a peer that does
    -- not know we are online has nowhere to put the payload.
    if push < Mesh.PRIO_FOR("heartbeat") then
        return false, "a fresh push outranks the heartbeat"
    end
    if not Mesh.OP_COST.nspush then return false, "nspush has no token cost" end
    if not Mesh.OP_MAX_BURST.nspush then return false, "nspush has no burst cap" end
    return true
end

-- A10.1 — the change-filter hash recipe. Everything the reference calls a data
-- change must move the hash; everything it calls volatile must NOT.
local function testStateHash()
    local function rec(over)
        local r = {
            location = "Orgrimmar", level = 60, shardCount = 12, boonCount = 1,
            isResting = true, inInstance = false, pvpFlagged = false,
            chronoboonActive = false, dmfInBoon = false, dmfCooldownActive = false,
            soulstoneReady = true,
            hearthstoneCD = 1000, itemCooldown = 0,   -- 1000 -> 5-min bucket 3
            raidLockouts = { MC = 1700100000, ZG = 0 },
            auraStates = {
                [1] = { duration = 3630, option = 0, source = 0 },  -- minute 60
                [4] = { duration = 900,  option = 0, source = 0 },
            },
            -- Volatile bookkeeping the filter MUST ignore.
            lastSeen = 1700000000, lastDataUpdate = 1700000000,
            ownerEpoch = 1700000000, msgId = "1-abc-1",
        }
        for k, v in pairs(over or {}) do r[k] = v end
        return r
    end

    if Mesh.StateHash(nil) ~= nil then return false, "non-record must hash nil" end
    if Mesh.StateHash("x") ~= nil then return false, "string must hash nil" end

    local base = Mesh.StateHash(rec())
    if Mesh.StateHash(rec()) ~= base then return false, "identical records hashed differently" end

    -- 1) VOLATILE-ONLY change -> identical hash (this is the whole point).
    local vol = rec({ lastSeen = 1700009999, lastDataUpdate = 1700009999,
                      ownerEpoch = 1700009999, msgId = "1-abc-77" })
    if Mesh.StateHash(vol) ~= base then
        return false, "epoch-only change moved the hash"
    end

    -- 2) An aura ticking WITHIN the same minute -> identical hash.
    local same = rec()
    same.auraStates[1].duration = 3601             -- 3630 -> 3601, both minute 60
    if Mesh.StateHash(same) ~= base then
        return false, "sub-minute aura tick moved the hash"
    end

    -- 3) Crossing the minute boundary -> hash MUST move.
    local tick = rec()
    tick.auraStates[1].duration = 3599             -- minute 60 -> 59
    if Mesh.StateHash(tick) == base then
        return false, "aura minute boundary did not move the hash"
    end

    -- 4) Cooldowns coarsen at 5 minutes (we store REMAINING, not an epoch).
    if Mesh.StateHash(rec({ hearthstoneCD = 901 })) ~= base then
        return false, "sub-5-minute cooldown tick moved the hash"
    end
    if Mesh.StateHash(rec({ hearthstoneCD = 899 })) == base then
        return false, "5-minute cooldown boundary did not move the hash"
    end

    -- 5) Every genuine §3.3 field moves the hash.
    local moves = {
        { "location", "The Barrens" }, { "level", 59 }, { "shardCount", 11 },
        { "boonCount", 0 }, { "isResting", false }, { "inInstance", true },
        { "pvpFlagged", true }, { "chronoboonActive", true }, { "dmfInBoon", true },
        { "dmfCooldownActive", true }, { "soulstoneReady", false },
        { "itemCooldown", 3600 },
    }
    for i = 1, #moves do
        if Mesh.StateHash(rec({ [moves[i][1]] = moves[i][2] })) == base then
            return false, "field " .. moves[i][1] .. " did not move the hash"
        end
    end

    -- 6) Raid lockouts (deep) and aura source/variant.
    local lock = rec(); lock.raidLockouts = { MC = 1700100000 + 400, ZG = 0 }
    if Mesh.StateHash(lock) == base then return false, "raid lockout change missed" end
    local src = rec(); src.auraStates[4].source = 1
    if Mesh.StateHash(src) == base then return false, "aura source change missed" end
    local opt = rec(); opt.auraStates[4].option = 3
    if Mesh.StateHash(opt) == base then return false, "aura variant change missed" end
    -- 7) Losing a slot entirely.
    local lost = rec(); lost.auraStates[4] = nil
    if Mesh.StateHash(lost) == base then return false, "lost aura slot missed" end
    return true
end

-- A1.3 — peer timeout sweep. Runs entirely on a LOCAL peers table so it can
-- never disturb the live Mesh.peers other suites read.
local function testPeerSweep()
    local T = 1700000000
    local peers = {
        ["2"] = { aid = "2", name = "Alive-R",  online = true, lastSeen = T - 29 },
        ["3"] = { aid = "3", name = "Crashed-R", online = true, lastSeen = T - 31 },
        ["4"] = { aid = "4", name = "Gone-R",   online = false, lastSeen = T - 999 },
    }
    local marked = Mesh.SweepPeers(T, peers)
    if marked ~= 1 then return false, "expected 1 newly offline, got " .. marked end
    if peers["2"].online ~= true then return false, "29s-silent peer wrongly expired" end
    if peers["3"].online ~= false then return false, "31s-silent peer still online" end
    if peers["3"].timedOut ~= true then return false, "timeout latch not set" end
    -- Idempotent: a second sweep marks nothing new.
    if Mesh.SweepPeers(T, peers) ~= 0 then return false, "second sweep re-marked" end
    -- Exactly at the boundary (30s) is still alive; 30.5s is not.
    peers["2"].lastSeen = T - 30
    if Mesh.SweepPeers(T, peers) ~= 0 then return false, "30s boundary expired early" end

    -- The 5s cadence gate. Save/restore the real sweep clock.
    local savedTs, savedPeers = Mesh._lastPeerSweep, Mesh.peers
    Mesh.peers = { ["9"] = { aid = "9", name = "Z-R", online = true, lastSeen = T - 60 } }
    Mesh._lastPeerSweep = 0
    local ok, why = true, nil
    if Mesh.MaybeSweepPeers(T) ~= 1 then ok, why = false, "first gated sweep did not run" end
    Mesh.peers["9"].online = true
    if ok and Mesh.MaybeSweepPeers(T + 4) ~= 0 then
        ok, why = false, "sweep ran again inside the 5s cadence"
    end
    if ok and Mesh.MaybeSweepPeers(T + 5) ~= 1 then
        ok, why = false, "sweep did not run at the 5s cadence"
    end
    Mesh.peers, Mesh._lastPeerSweep = savedPeers, savedTs
    if not ok then return false, why end

    -- Spec §2.2: a raw receive from a KNOWN peer refreshes it and un-expires it,
    -- so an actively-pushing peer can never be swept just because a heartbeat
    -- was dropped. An unknown sender is NOT admitted (that needs an account ID).
    local sp = Mesh.peers
    Mesh.peers = {
        ["5"] = { aid = "5", name = "Busy-R", online = false, timedOut = true,
                  presenceStale = true, lastSeen = T - 99 },
    }
    local touched = Mesh.TouchPeerByName("Busy-R", T)
    local tOk, tWhy = true, nil
    if not touched then tOk, tWhy = false, "known sender not stamped"
    elseif Mesh.peers["5"].lastSeen ~= T then tOk, tWhy = false, "lastSeen not refreshed"
    elseif Mesh.peers["5"].online ~= true then tOk, tWhy = false, "peer not re-admitted"
    elseif Mesh.peers["5"].timedOut then tOk, tWhy = false, "timeout latch not cleared"
    elseif Mesh.peers["5"].presenceStale then tOk, tWhy = false, "leave latch not cleared"
    elseif Mesh.TouchPeerByName("Nobody-R", T) ~= nil then
        tOk, tWhy = false, "unknown sender was admitted"
    elseif Mesh.TouchPeerByName(nil, T) ~= nil then
        tOk, tWhy = false, "nil sender was admitted"
    end
    -- And a peer kept alive this way survives the very next sweep.
    if tOk and Mesh.SweepPeers(T + 10) ~= 0 then
        tOk, tWhy = false, "freshly-stamped peer was swept"
    end
    Mesh.peers = sp
    if not tOk then return false, tWhy end
    return true
end

-- A10.9 — direct-send budget tracks the live token count, floored at
-- DIRECT_BUDGET and capped at BUCKET_CAP.
local function testDirectBudget()
    local cases = {
        { 0, 4 }, { 3.9, 4 }, { 4, 4 }, { 5, 5 }, { 6.9, 6 }, { 8, 8 }, { 99, 8 },
        { nil, 4 },
    }
    for i = 1, #cases do
        local got = Mesh.DirectBudget(cases[i][1])
        if got ~= cases[i][2] then
            return false, "tokens=" .. tostring(cases[i][1]) .. " -> " .. got
                .. " (want " .. cases[i][2] .. ")"
        end
    end
    -- A full bucket must let a 6-peer mesh go all-direct (the old fixed 4
    -- delegated 2 even with tokens to spare).
    local plan = Mesh.ComputeRelayPlan({ "1", "2", "3", "4", "5", "6" },
        Mesh.DirectBudget(8), "9")
    if #plan.direct ~= 6 then
        return false, "full bucket still delegated: direct=" .. #plan.direct
    end
    return true
end

-- A10.8 — relayed payloads older than 10s are dropped, not forwarded.
local function testRelayAgeGate()
    local T = 1700000000
    if not Mesh.RelayAgeOK({ lastDataUpdate = T - 9 }, T) then
        return false, "9s-old payload wrongly dropped"
    end
    if not Mesh.RelayAgeOK({ lastDataUpdate = T - 10 }, T) then
        return false, "exactly 10s wrongly dropped (gate is > 10)"
    end
    if Mesh.RelayAgeOK({ lastDataUpdate = T - 11 }, T) then
        return false, "11s-old payload was forwarded"
    end
    -- Falls back through ownerEpoch then lastSeen.
    if Mesh.RelayAgeOK({ lastDataUpdate = 0, ownerEpoch = T - 60 }, T) then
        return false, "stale ownerEpoch fallback forwarded"
    end
    if Mesh.RelayAgeOK({ lastDataUpdate = 0, ownerEpoch = 0, lastSeen = T - 60 }, T) then
        return false, "stale lastSeen fallback forwarded"
    end
    -- Fail-open: an entirely unstamped record still forwards.
    if not Mesh.RelayAgeOK({ lastDataUpdate = 0, ownerEpoch = 0, lastSeen = 0 }, T) then
        return false, "unstamped record must fail open"
    end
    -- Clock skew (stamp in the future) must not drop.
    if not Mesh.RelayAgeOK({ lastDataUpdate = T + 5 }, T) then
        return false, "future stamp dropped"
    end
    if Mesh.RelayAgeOK(nil, T) then return false, "nil record must not forward" end
    return true
end

-- A1.4 — the heartbeat's online-character hint drives DISCOVERY, honouring the
-- existing per-name ping cooldown.
local function testOnlineHintDiscovery()
    local T = 1700000000
    local savedPeers, savedCd = Mesh.peers, Mesh._pingCooldowns
    Mesh.peers = { ["2"] = { aid = "2", name = "Known-R", online = true, lastSeen = T } }
    Mesh._pingCooldowns = {}
    local ok, why = true, nil

    -- Unknown character advertised as online -> pinged. Known peer -> skipped.
    local got = Mesh.ConsumeOnlineHint({ "Known-R", "Stranger-R" }, T)
    if #got ~= 1 or got[1] ~= "Stranger-R" then
        ok, why = false, "expected only Stranger-R, got " .. table.concat(got, ",")
    end
    -- Dedup: the same hint one heartbeat later (well inside the cooldown) is a
    -- no-op, so a 20s heartbeat can never out-run the ping throttle.
    if ok then
        local again = Mesh.ConsumeOnlineHint({ "Stranger-R" }, T + 20)
        if #again ~= 0 then ok, why = false, "ping dedup not respected" end
    end
    -- Past the cooldown it may ping again.
    if ok then
        local later = Mesh.ConsumeOnlineHint({ "Stranger-R" },
            T + Mesh.ROSTER_PING_COOLDOWN + 1)
        if #later ~= 1 then ok, why = false, "cooldown never expired" end
    end
    -- Empty / absent / non-table hints are safe no-ops.
    if ok and #Mesh.ConsumeOnlineHint(nil, T) ~= 0 then ok, why = false, "nil hint pinged" end
    if ok and #Mesh.ConsumeOnlineHint({}, T) ~= 0 then ok, why = false, "empty hint pinged" end

    Mesh.peers, Mesh._pingCooldowns = savedPeers, savedCd
    if not ok then return false, why end
    return true
end

-- A10.1 belt-and-suspenders: PushState's own payload-hash suppressor, and the
-- peer-set key that stops it starving a newly-discovered peer.
local function testPushSuppressor()
    local a = { direct = { "1", "2" }, backups = { "1", "2" } }
    local b = { direct = { "2", "1" }, backups = { "2", "1" } }
    if Mesh.PeerSetKey(a) ~= Mesh.PeerSetKey(b) then
        return false, "peer-set key is order-sensitive"
    end
    local c = { direct = { "1", "2", "3" }, backups = { "1", "3" } }
    if Mesh.PeerSetKey(a) == Mesh.PeerSetKey(c) then
        return false, "a new peer did not change the peer-set key"
    end
    if Mesh.PeerSetKey({}) ~= "" then return false, "empty plan key not empty" end
    return true
end

----------------------------------------------------------------------
-- THE REPAINT PUMP: inbound data must announce itself.
--
-- Drives real frames through Mesh.Dispatch and counts STORE_REFRESHED fires.
-- This is the regression test for "remote characters' buffs never update".
----------------------------------------------------------------------
local function testInboundRepaintPump()
    local T = 1785000500
    local savedAccounts = Store.data.accounts
    local savedPeers    = Mesh.peers
    local savedAID      = ns.GetAccountID
    local savedSeen, savedFresh = Mesh.SeenBefore, Mesh.FreshSeq

    ns.GetAccountID = function() return "1" end
    Mesh.peers = { ["9"] = { aid = "9", name = "Peer-R", online = true, lastSeen = T } }
    Store.data.accounts = {
        ["9"] = { isSelf = false, characters = {}, homeless = {},
                  segments = { sixties = {}, summoners = {}, norole = {} },
                  segmentHashes = {} },
    }
    -- Every test frame is hand-built, so bypass the replay/freshness guards.
    Mesh.SeenBefore = function() return false end
    Mesh.FreshSeq   = function() return true end

    local fires = 0
    ns:On("STORE_REFRESHED", function() fires = fires + 1 end)

    local function stateFrame(nameRealm, epoch)
        local rec = Store.NewCharacterRecord(nameRealm)
        rec.level = 60
        rec.ownerEpoch, rec.lastDataUpdate, rec.lastSeen = epoch, epoch, epoch
        return Mesh.BuildFrame(OP.STATE, Protocol.EncodeCharacter(rec), { seq = 1 })
    end

    local ok, why = true, nil
    local function ck(c, m) if ok and not c then ok, why = false, m end end

    -- 1) An accepted inbound STATE push fires exactly one repaint.
    pcall(Mesh.Dispatch, Protocol.PREFIX.STATE, stateFrame("Peer-R", T), "Peer-R")
    ck(fires == 1, "an accepted inbound STATE push did not fire STORE_REFRESHED")
    ck(Store.data.accounts["9"].characters["Peer-R"] ~= nil, "inbound record was not stored")

    -- 2) A LOSING push (older epoch) is rejected, so it must NOT cost a repaint.
    fires = 0
    pcall(Mesh.Dispatch, Protocol.PREFIX.STATE, stateFrame("Peer-R", T - 500), "Peer-R")
    ck(fires == 0, "a rejected (stale-epoch) push still fired a repaint")

    -- 3) A SEGMENT adoption fires ONCE for the whole batch, not once per record.
    fires = 0
    local recs = {}
    for _, nm in ipairs({ "Alt1-R", "Alt2-R", "Alt3-R" }) do
        local r = Store.NewCharacterRecord(nm)
        r.level, r.ownerEpoch, r.lastDataUpdate = 60, T + 10, T + 10
        recs[nm] = r
    end
    local segPayload = Mesh.Pack({ aid = "9", area = "sixties", records = recs })
    if segPayload then
        pcall(Mesh.Dispatch, Protocol.PREFIX.SYNC,
            Mesh.BuildFrame(OP.SEGMENT, segPayload, { seq = 2 }), "Peer-R")
    end
    ck(fires == 1, "a 3-record segment fired " .. fires .. " repaints (expected exactly 1)")
    ck(Store.data.accounts["9"].characters["Alt2-R"] ~= nil, "segment records were not adopted")

    -- 4) A segment that adopts NOTHING (every record loses on epoch) is silent.
    fires = 0
    local stale = {}
    for _, nm in ipairs({ "Alt1-R", "Alt2-R" }) do
        local r = Store.NewCharacterRecord(nm)
        r.level, r.ownerEpoch, r.lastDataUpdate = 60, T - 900, T - 900
        stale[nm] = r
    end
    local stalePayload = Mesh.Pack({ aid = "9", area = "sixties", records = stale })
    if stalePayload then
        pcall(Mesh.Dispatch, Protocol.PREFIX.SYNC,
            Mesh.BuildFrame(OP.SEGMENT, stalePayload, { seq = 3 }), "Peer-R")
    end
    ck(fires == 0, "a segment that adopted nothing still fired a repaint")

    Store.data.accounts = savedAccounts
    Mesh.peers          = savedPeers
    ns.GetAccountID     = savedAID
    Mesh.SeenBefore, Mesh.FreshSeq = savedSeen, savedFresh
    return ok, why
end

----------------------------------------------------------------------
-- OWN-ACCOUNT AUTHORITY, at the wire.
--
-- Drives REAL frames through Mesh.Dispatch, because the whole defect lived in
-- the gap between what the frame says and what the store is asked to do:
-- handleState infers the owner account from the peer table, so a peer relaying
-- one of OUR characters gets it filed under the PEER's bucket and the old
-- self-immunity check (which asks about the destination bucket) never fired.
--
-- Also pins the honest-epoch property that makes newest-wins safe for third
-- parties: a forwarded record must carry the ORIGINAL capture epoch, never a
-- fresh send-time stamp.
----------------------------------------------------------------------
local function testOwnAccountAuthorityWire()
    local savedAccounts = Store.data.accounts
    local savedPeers    = Mesh.peers
    local savedAID      = ns.GetAccountID
    local savedSeen     = Mesh.SeenBefore
    local savedFresh    = Mesh.FreshSeq
    local savedEnqueue  = Mesh.Enqueue
    local savedNameFor  = Mesh.NameForAID
    local savedAuth     = Store._ownAuthority
    local T = 1700000000

    ns.GetAccountID = function() return "1" end
    Mesh.peers = { ["9"] = { aid = "9", name = "Peer-R", online = true, lastSeen = T } }
    Mesh.SeenBefore = function() return false end
    Mesh.FreshSeq   = function() return true end
    Store._ownAuthority = { drops = 0, names = {} }

    local function newBucket(isSelf)
        return { isSelf = isSelf or false, characters = {}, homeless = {},
                 segments = { sixties = {}, summoners = {}, norole = {} }, segmentHashes = {} }
    end
    local function rec(nameRealm, epoch, boon)
        local r = Store.NewCharacterRecord(nameRealm)
        r.level = 60
        r.ownerEpoch, r.lastDataUpdate, r.lastSeen = epoch, epoch, epoch
        r.boonCount = boon or 0
        return r
    end

    Store.data.accounts = { ["1"] = newBucket(true), ["9"] = newBucket(false) }
    Store.data.accounts["1"].characters["Mine-R"] = rec("Mine-R", T, 7)

    local ok, why = true, nil
    local function ck(c, m) if ok and not c then ok, why = false, m end end

    -- 1) THE BUG, end to end. Peer "9" relays OUR OWN character back at us with a
    --    FRESHER epoch and no buffs. handleState will address it to bucket "9".
    local frame = Mesh.BuildFrame(OP.STATE, Protocol.EncodeCharacter(rec("Mine-R", T + 5000, 0)), { seq = 1 })
    pcall(Mesh.Dispatch, Protocol.PREFIX.STATE, frame, "Peer-R")
    ck(Store.data.accounts["9"].characters["Mine-R"] == nil,
        "a peer's relayed copy of OUR OWN character became a phantom under the peer's bucket")
    ck(Store.data.accounts["1"].characters["Mine-R"].boonCount == 7,
        "our own capture was altered by a relayed copy")
    ck(Store.data.accounts["1"].characters["Mine-R"].ownerEpoch == T,
        "our own record's epoch was moved by a relayed copy")

    -- 2) The SEGMENT (bulk) path obeys the same rule, and only for our own
    --    characters — the peer's genuine records in the same batch still land.
    local recs = { ["Mine-R"] = rec("Mine-R", T + 9000, 0), ["Theirs-R"] = rec("Theirs-R", T + 10, 3) }
    local segPayload = Mesh.Pack({ aid = "9", area = "sixties", records = recs })
    if segPayload then
        pcall(Mesh.Dispatch, Protocol.PREFIX.SYNC,
            Mesh.BuildFrame(OP.SEGMENT, segPayload, { seq = 2 }), "Peer-R")
    end
    ck(Store.data.accounts["9"].characters["Mine-R"] == nil,
        "the bulk SEGMENT path let a copy of our own character through")
    ck(Store.data.accounts["9"].characters["Theirs-R"] ~= nil,
        "the authority rule wrongly dropped the peer's OWN record from the same segment")
    ck((Store._ownAuthority.drops or 0) >= 2,
        "wire-path drops were not counted")

    -- 3) HONEST EPOCHS on store-and-forward. A relayed frame must re-emit the
    --    ORIGINAL capture epoch; if the forwarder re-stamped it at send time,
    --    every third-party observer's newest-wins would pick the relay over the
    --    owner's own fresher data. Capture what the forward actually enqueues.
    local captured = nil
    Mesh.NameForAID = function(aid) local p = Mesh.peers[aid]; return p and p.name or nil end
    Mesh.Enqueue = function(prefix, fr, meta)
        if meta and meta.op == "relay" then captured = fr end
        return true
    end
    local CAPTURE_EPOCH = T + 1234
    local relayFrame = Mesh.BuildFrame(OP.STATE,
        Protocol.EncodeCharacter(rec("Theirs-R", CAPTURE_EPOCH, 3)),
        { seq = 3, relayTo = "Third-R" })
    pcall(Mesh.Dispatch, Protocol.PREFIX.STATE, relayFrame, "Peer-R")
    ck(captured ~= nil, "the relay hop enqueued nothing to forward")
    if captured then
        local pf = Mesh.ParseFrame(captured)
        local decoded = pf and Protocol.DecodeCharacter(pf.payload)
        ck(decoded ~= nil, "the forwarded relay frame did not decode")
        if decoded then
            ck(decoded.ownerEpoch == CAPTURE_EPOCH,
                "RELAY RE-STAMPED THE EPOCH: forwarded ownerEpoch=" ..
                tostring(decoded.ownerEpoch) .. " expected the original " .. tostring(CAPTURE_EPOCH))
            ck(decoded.lastDataUpdate == CAPTURE_EPOCH,
                "relay re-stamped lastDataUpdate instead of preserving the capture stamp")
        end
    end

    Store.data.accounts = savedAccounts
    Mesh.peers          = savedPeers
    ns.GetAccountID     = savedAID
    Mesh.SeenBefore, Mesh.FreshSeq = savedSeen, savedFresh
    Mesh.Enqueue        = savedEnqueue
    Mesh.NameForAID     = savedNameFor
    Store._ownAuthority = savedAuth
    return ok, why
end

----------------------------------------------------------------------
-- HASH-AFTER-SEND: Mesh.PushState must report how many targets it reached.
----------------------------------------------------------------------
local function testPushDeliveryCount()
    local savedPeers    = Mesh.peers
    local savedEnabled  = Mesh.IsEnabled
    local savedAID      = ns.GetAccountID
    local savedLastPush = Mesh._lastPush
    local savedNameFor  = Mesh.NameForAID
    local savedEnqueue  = Mesh.Enqueue

    ns.GetAccountID = function() return "1" end
    Mesh.IsEnabled  = function() return true end
    Mesh._lastPush  = {}
    local enqueued = 0
    Mesh.Enqueue = function() enqueued = enqueued + 1 return true end
    Mesh.NameForAID = function(aid)
        local p = Mesh.peers[aid]; return p and p.name or nil
    end

    local ok, why = true, nil
    local function ck(c, m) if ok and not c then ok, why = false, m end end

    local rec = Store.NewCharacterRecord("Me-R")
    rec.level = 60

    -- 1) ZERO known peers -> zero targets. This is the case that used to stamp
    --    the tracker's hash as delivered and suppress the change forever.
    Mesh.peers = {}
    local receipt = {}
    local n = Mesh.PushState("Me-R", rec, false, receipt)
    ck(n == 0, "a push with no peers reported " .. tostring(n) .. " targets (expected 0)")
    ck(receipt.sent == 0, "the receipt was not stamped with 0")

    -- 2) A peer appears -> the same unchanged record must still go out. The
    --    suppressor must NOT have been armed by the zero-target attempt.
    Mesh.peers = { ["2"] = { aid = "2", name = "Peer-R", online = true } }
    enqueued, receipt = 0, {}
    n = Mesh.PushState("Me-R", rec, false, receipt)
    ck(n >= 1, "an unchanged record did not re-push when a peer appeared (got " .. tostring(n) .. ")")
    ck(receipt.sent == n, "receipt disagrees with the return value")
    ck(enqueued == n, "reported count does not match confirmed enqueues")
    local firstCount = n

    -- 3) Re-pushing the SAME state to the SAME peer set is suppressed — but it
    --    must report the delivery it stands in for, never 0, or the tracker
    --    would roll back a stamp for state the peer already has.
    receipt = {}
    n = Mesh.PushState("Me-R", rec, false, receipt)
    ck(n == firstCount, "the suppressed path reported " .. tostring(n) ..
        " (expected the standing delivery count " .. tostring(firstCount) .. ")")

    -- 4) Mesh disabled -> 0 targets.
    Mesh.IsEnabled = function() return false end
    receipt = {}
    n = Mesh.PushState("Me-R", rec, false, receipt)
    ck(n == 0, "a push with the mesh disabled reported " .. tostring(n))
    Mesh.IsEnabled = function() return true end

    -- 5) A record the encoder refuses is 0, not nil.
    receipt = {}
    n = Mesh.PushState("Me-R", nil, false, receipt)
    ck(n == 0, "an unencodable record reported " .. tostring(n))

    -- 6) Mesh.Enqueue confirms the queue-up (the count's definition of "sent").
    Mesh.Enqueue = savedEnqueue
    ck(Mesh.Enqueue(Protocol.PREFIX.STATE,
        Mesh.BuildFrame(OP.STATE, "x", { seq = 1 }),
        { op = "state", chatType = "WHISPER", target = "Peer-R", seq = 1 }) == true,
        "Mesh.Enqueue did not confirm a legitimate enqueue")

    Mesh.peers, Mesh.IsEnabled = savedPeers, savedEnabled
    ns.GetAccountID, Mesh._lastPush = savedAID, savedLastPush
    Mesh.NameForAID, Mesh.Enqueue = savedNameFor, savedEnqueue
    return ok, why
end

----------------------------------------------------------------------
-- SEGMENT CONTENT FINGERPRINT (spec §9.6).
----------------------------------------------------------------------
local function testSegmentFingerprint()
    local ok, why = true, nil
    local function ck(c, m) if ok and not c then ok, why = false, m end end

    local list = { "A-R", "B-R" }
    local function mk()
        local a = Store.NewCharacterRecord("A-R")
        a.level, a.location = 60, "Orgrimmar"
        -- 3610 sits INSIDE the DIV-60 bucket 60 (not on its boundary), so the
        -- tick/minute cases below are unambiguous.
        a.auraStates = { [1] = { duration = 3610, option = 1, source = 0 } }
        a.raidLockouts = { MC = 1785200000 }
        local b = Store.NewCharacterRecord("B-R")
        b.level = 60
        return { ["A-R"] = a, ["B-R"] = b }
    end

    -- Backwards compatible: no records -> the historic names-only hash.
    ck(Mesh.HashSegment(list) == Mesh.HashSegment({ "A-R", "B-R" }),
        "names-only hashing changed")
    ck(Mesh.HashSegment(list) ~= Mesh.HashSegment(list, mk()),
        "passing records did not change the hash at all")
    ck(Mesh.HashSegment(nil, mk()) == "0", "empty list must still hash to 0")

    -- Deterministic: identical content hashes identically.
    ck(Mesh.HashSegment(list, mk()) == Mesh.HashSegment(list, mk()),
        "the fingerprint is not deterministic")

    -- STABLE across the volatile fields — this is the anti-resync-loop property.
    -- Each of these changes on the owner WITHOUT a state push, so folding any of
    -- them in would diverge the two copies permanently.
    local volatile = mk()
    volatile["A-R"].lastSeen       = 999999999
    volatile["A-R"].lastDataUpdate = 999999999
    volatile["A-R"].ownerEpoch     = 999999999
    volatile["A-R"].xp             = 123456
    volatile["A-R"].xpMax          = 999999
    volatile["A-R"].restedXP       = 54321
    volatile["A-R"].itemCooldown   = 3599     -- receiver-rewritten mirror
    volatile["A-R"].hearthstoneCD  = 1234     -- receiver-rewritten mirror
    volatile["A-R"]._srcAID        = "7"
    ck(Mesh.HashSegment(list, mk()) == Mesh.HashSegment(list, volatile),
        "the fingerprint moved on a volatile/receiver-rewritten field")

    -- Sub-minute aura decay must NOT move it (3610 and 3601 are both bucket 60).
    local tick = mk()
    tick["A-R"].auraStates[1].duration = 3601
    ck(Mesh.HashSegment(list, mk()) == Mesh.HashSegment(list, tick),
        "a sub-minute aura tick moved the fingerprint")

    -- ...but crossing a minute boundary MUST, so a lost push is detectable
    -- (3610 -> bucket 60, 3599 -> bucket 59).
    local minute = mk()
    minute["A-R"].auraStates[1].duration = 3599
    ck(Mesh.HashSegment(list, mk()) ~= Mesh.HashSegment(list, minute),
        "an aura MINUTE change did not move the fingerprint")

    -- Meaningful content changes move it.
    local flag = mk(); flag["A-R"].chronoboonActive = true
    ck(Mesh.HashSegment(list, mk()) ~= Mesh.HashSegment(list, flag),
        "a key flag did not move the fingerprint")
    local loc = mk(); loc["A-R"].location = "Blackrock Depths"
    ck(Mesh.HashSegment(list, mk()) ~= Mesh.HashSegment(list, loc),
        "location did not move the fingerprint")
    local lock = mk(); lock["A-R"].raidLockouts.MC = 1785200000 + 3600
    ck(Mesh.HashSegment(list, mk()) ~= Mesh.HashSegment(list, lock),
        "a raid lockout hour did not move the fingerprint")
    local cd = mk(); cd["A-R"].chronoboonCDStart = 1785000000
    ck(Mesh.HashSegment(list, mk()) ~= Mesh.HashSegment(list, cd),
        "a cooldown starting did not move the fingerprint")
    -- ...but a cooldown DRIFTING (same presence, different epoch) does not,
    -- because our synthesized epoch is the owner's plus transit.
    local cd2 = mk(); cd2["A-R"].chronoboonCDStart = 1785000000
    local cd3 = mk(); cd3["A-R"].chronoboonCDStart = 1785000004
    ck(Mesh.HashSegment(list, cd2) == Mesh.HashSegment(list, cd3),
        "cooldown epoch transit jitter moved the fingerprint")

    -- A missing record is distinguishable from a present one.
    local partial = mk(); partial["B-R"] = nil
    ck(Mesh.HashSegment(list, mk()) ~= Mesh.HashSegment(list, partial),
        "a missing record hashed the same as a present one")

    -- DiffHashes semantics are UNCHANGED: still a per-area string comparison
    -- over exactly the four area names, absent reading as "0".
    local d = Mesh.DiffHashes({ sixties = "a", summoners = "b", norole = "c", homeless = "d" },
                              { sixties = "a", summoners = "Z", norole = "c", homeless = "d" })
    ck(#d == 1 and d[1] == "summoners", "DiffHashes no longer isolates the differing area")
    ck(#Mesh.DiffHashes({}, {}) == 0, "DiffHashes on two empty bundles must be empty")
    ck(#Mesh.DiffHashes({ sixties = "a" }, {}) == 1,
        "DiffHashes: an absent remote area must read as '0' and differ")
    ck(#Mesh.DiffHashes(nil, nil) == 0, "DiffHashes must tolerate nil bundles")

    -- AccountHashes feeds the records through (both sides of the heartbeat).
    local bucket = { segments = { sixties = list, summoners = {}, norole = {} },
                     characters = mk(), homeless = {} }
    local h1 = Mesh.AccountHashes(bucket)
    bucket.characters["A-R"].level = 59
    local h2 = Mesh.AccountHashes(bucket)
    ck(h1.sixties ~= h2.sixties, "AccountHashes is not folding record content in")
    ck(h1.homeless == h2.homeless, "the homeless set hash must be unaffected")
    return ok, why
end

----------------------------------------------------------------------
-- CANONICAL PEER NAMES: p.name must be a Name-Realm, or MeshPresence cannot
-- match it against a record key and every remote character reads offline.
----------------------------------------------------------------------
local function testCanonicalPeerNames()
    local ok, why = true, nil
    local function ck(c, m) if ok and not c then ok, why = false, m end end
    local savedRealm = _G.GetRealmName
    _G.GetRealmName = function() return "Whitemane" end

    -- Bare sender normalization (the IsSelfSender comment documents bare senders
    -- as real, so this is not a hypothetical).
    ck(Mesh.NormalizeSender("Erro") == "Erro-Whitemane", "bare sender not normalized")
    ck(Mesh.NormalizeSender("Erro-Faerlina") == "Erro-Faerlina",
        "an explicit realm must be preserved")
    ck(Mesh.NormalizeSender("") == nil, "empty sender must be nil")
    ck(Mesh.NormalizeSender(nil) == nil, "nil sender must be nil")

    -- A realm with a space is stripped, matching selfNameRealm's own gsub.
    _G.GetRealmName = function() return "Blade's Edge" end
    ck(Mesh.NormalizeSender("Erro") == "Erro-Blade'sEdge", "realm whitespace not stripped")
    _G.GetRealmName = function() return "Whitemane" end

    -- The payload's canonical name is PREFERRED over a bare sender.
    ck(Mesh.CanonicalPeerName("Erro", "Erro-Whitemane") == "Erro-Whitemane",
        "the payload's canonical name was not preferred")
    -- ...and over a cross-realm sender that agrees on the short name.
    ck(Mesh.CanonicalPeerName("Puunyx", "Puunyx-Faerlina") == "Puunyx-Faerlina",
        "a cross-realm payload name was not preferred")
    -- A payload name that DISAGREES with the sender is refused: a peer cannot
    -- use its own heartbeat to claim to be another character.
    ck(Mesh.CanonicalPeerName("Erro", "Someoneelse-Whitemane") == "Erro-Whitemane",
        "a disagreeing payload name was trusted")
    -- Junk payloads fall back to the normalized sender.
    ck(Mesh.CanonicalPeerName("Erro", nil) == "Erro-Whitemane", "nil payload name")
    ck(Mesh.CanonicalPeerName("Erro", "") == "Erro-Whitemane", "empty payload name")
    ck(Mesh.CanonicalPeerName("Erro", "Erro") == "Erro-Whitemane",
        "a bare payload name must not be taken as canonical")
    ck(Mesh.CanonicalPeerName("Erro", 42) == "Erro-Whitemane", "non-string payload name")

    -- Matching is canonical in BOTH directions, which is what keeps the
    -- CHAT_MSG_CHANNEL_LEAVE latch (a bare player name) working now that
    -- p.name is stored as Name-Realm.
    local p = { name = "Erro-Whitemane" }
    ck(Mesh.PeerNameMatches(p, "Erro"), "canonical peer did not match a bare name")
    ck(Mesh.PeerNameMatches(p, "Erro-Whitemane"), "canonical peer did not match itself")
    ck(not Mesh.PeerNameMatches(p, "Erro-Faerlina"), "matched a different realm")
    ck(not Mesh.PeerNameMatches(p, "Other"), "matched a different name")
    ck(not Mesh.PeerNameMatches({ name = "" }, "Erro"), "a nameless peer must not match")
    ck(not Mesh.PeerNameMatches(nil, "Erro"), "a nil peer must not match")

    -- End to end: a heartbeat from a BARE sender must leave a Name-Realm behind,
    -- which is exactly what Dashboard.MeshPresence publishes.
    local savedPeers, savedAID = Mesh.peers, ns.GetAccountID
    local savedSeen, savedFresh = Mesh.SeenBefore, Mesh.FreshSeq
    Mesh.peers = {}
    ns.GetAccountID = function() return "1" end
    Mesh.SeenBefore = function() return false end
    Mesh.FreshSeq   = function() return true end
    local hbPayload = Mesh.Pack({ aid = "9", hashes = {}, online = { "Erro-Whitemane" } })
    if hbPayload then
        pcall(Mesh.Dispatch, Protocol.PREFIX.HEARTBEAT,
            Mesh.BuildFrame(OP.HEARTBEAT, hbPayload, { seq = 1 }), "Erro")
    end
    ck(Mesh.peers["9"] and Mesh.peers["9"].name == "Erro-Whitemane",
        "a heartbeat from a bare sender did not store the canonical name (got "
        .. tostring(Mesh.peers["9"] and Mesh.peers["9"].name) .. ")")

    -- A discovery ping does the same via d.name.
    Mesh.peers = {}
    local dPayload = Mesh.Pack({ aid = "8", name = "Puunyx-Whitemane" })
    if dPayload then
        pcall(Mesh.Dispatch, Protocol.PREFIX.HEARTBEAT,
            Mesh.BuildFrame(OP.PONG, dPayload, { seq = 2 }), "Puunyx")
    end
    ck(Mesh.peers["8"] and Mesh.peers["8"].name == "Puunyx-Whitemane",
        "discovery did not store the payload's canonical name")

    -- ...and the leave notice still latches that peer offline from a BARE name.
    Mesh.MarkPresenceStale("Puunyx", 1785000500)
    ck(Mesh.peers["8"].online == false,
        "a bare leave notice no longer latches a canonically-named peer offline")

    Mesh.peers, ns.GetAccountID = savedPeers, savedAID
    Mesh.SeenBefore, Mesh.FreshSeq = savedSeen, savedFresh
    _G.GetRealmName = savedRealm
    return ok, why
end

----------------------------------------------------------------------
-- Mesh-hygiene batch self-tests
----------------------------------------------------------------------

-- LOGOUT RE-STAMP: the record we put on the wire at logout must decode with a
-- lastSeen that is ALREADY outside the receiver's presence window, so the
-- roster's recency fallback reads the character offline the instant it lands.
local function testLogoutRestamp()
    local T = 1785000500
    local src = {
        nameRealm = "Daseeki-Faerlina", classTag = "WARLOCK", faction = "Horde",
        level = 60, boonCount = 3, shardCount = 12,
        lastSeen = T, lastDataUpdate = T, ownerEpoch = T,
    }
    local out = Mesh.LogoutRecord(src, T)
    -- 1) the SOURCE record is untouched (it is what we reload from).
    if src.lastSeen ~= T then return false, "LogoutRecord mutated the live record" end
    -- 2) backdated past the window the roster uses.
    if out.lastSeen >= T - Mesh.PRESENCE_ONLINE_WINDOW then
        return false, "lastSeen not backdated past PRESENCE_ONLINE_WINDOW"
    end
    -- 3) the epoch fields the store's owner-wins guard reads are NOT backdated,
    --    or the receiver would reject the final push as stale.
    if out.ownerEpoch ~= T or out.lastDataUpdate ~= T then
        return false, "logout copy disturbed ownerEpoch/lastDataUpdate"
    end
    -- 4) end-to-end through the real codec: what a peer DECODES is out of window.
    local bytes = Protocol.EncodeCharacter(out)
    if not bytes then return false, "logout record failed to encode" end
    local dec = Protocol.DecodeCharacter(bytes)
    if not dec then return false, "logout record failed to decode" end
    if (T - (dec.lastSeen or 0)) <= Mesh.PRESENCE_ONLINE_WINDOW then
        return false, "DECODED lastSeen still inside the online window"
    end
    if dec.ownerEpoch ~= T then return false, "decoded ownerEpoch not preserved" end
    -- 5) monotonic: an already-stale record is not dragged further back.
    local old = Mesh.LogoutRecord({ lastSeen = T - 9999 }, T)
    if old.lastSeen ~= T - 9999 then return false, "already-old lastSeen was moved" end
    -- 6) non-table input is passed through, never indexed.
    if Mesh.LogoutRecord(nil, T) ~= nil then return false, "LogoutRecord(nil) not nil" end
    return true
end

-- STALE LATCH: a presence latch set moments ago must survive raw inbound frames
-- (the logout flush lands AFTER the leave notice), but must not outlive its hold,
-- and must never block a genuine relog announcing itself through NotePeer.
local function testStaleLatch()
    local saved = Mesh.peers
    Mesh.peers = { ["7"] = { aid = "7", name = "Shalk-R", online = true, lastSeen = 100 } }
    local ok, why = true, nil
    local p = Mesh.peers["7"]
    local T = 1000

    Mesh.MarkPresenceStale("Shalk-R", T)
    if p.online ~= false or p.presenceStale ~= true then
        ok, why = false, "leave notice did not latch the peer offline"
    end
    if ok and p.presenceStaleAt ~= T then ok, why = false, "latch was not timestamped" end

    -- In-flight STATE whisper arriving 5s later: liveness stamped, latch HELD.
    if ok then
        Mesh.TouchPeerByName("Shalk-R", T + 5)
        if p.online ~= false then ok, why = false, "in-flight frame re-greened a latched peer" end
        if ok and p.lastSeen ~= T + 5 then ok, why = false, "liveness stamp was withheld" end
        if ok and p.presenceStale ~= true then ok, why = false, "latch flag was cleared" end
    end
    -- Right at the boundary the hold is still in force...
    if ok then
        Mesh.TouchPeerByName("Shalk-R", T + Mesh.PRESENCE_STALE_HOLD - 1)
        if p.online ~= false then ok, why = false, "hold expired early" end
    end
    -- ...and past it the normal "evidence of life" rule resumes.
    if ok then
        Mesh.TouchPeerByName("Shalk-R", T + Mesh.PRESENCE_STALE_HOLD + 1)
        if p.online ~= true then ok, why = false, "peer never recovered after the hold" end
        if ok and p.presenceStaleAt ~= nil then ok, why = false, "stale stamp not cleared" end
    end
    -- A relog inside the hold window: an IDENTIFIED frame (NotePeer) re-admits at
    -- once, so a /reload never costs the owner a grey pip.
    if ok then
        Mesh.MarkPresenceStale("Shalk-R", T + 100)
        Mesh.NotePeer("7", "Shalk-R", T + 101)
        if p.online ~= true then ok, why = false, "NotePeer did not re-admit inside the hold" end
        if ok and p.presenceStale then ok, why = false, "NotePeer left the latch set" end
    end
    -- The LOGOUT op latches without any channel-leave notice at all (the case a
    -- guild-fallback peer could never hit before).
    if ok then
        p.online, p.presenceStale, p.presenceStaleAt = true, nil, nil
        Mesh._handleLogout({ payload = "" }, "Shalk-R")
        if p.online ~= false or not p.presenceStale then
            ok, why = false, "LOGOUT op did not latch the peer offline"
        end
    end
    -- A legacy latch with no timestamp must NOT hold (old saved state).
    if ok then
        if Mesh.StaleLatchHolds({ presenceStale = true }, T) then
            ok, why = false, "untimestamped latch wrongly held"
        end
    end
    Mesh.peers = saved
    return ok, why
end

-- UNKNOWN OP: the property the additive LOGOUT op depends on. A frame carrying
-- an op this build has no handler for must be swallowed in total silence.
local function testUnknownOpIgnored()
    local savedPeers = Mesh.peers
    Mesh.peers = {}
    local frame = Mesh.BuildFrame("\255", "whatever", { seq = 0 })
    local okCall, err = pcall(Mesh.Dispatch, Protocol.PREFIX.STATE, frame, "Stranger-R")
    Mesh.peers = savedPeers
    if not okCall then return false, "unknown op errored: " .. tostring(err) end
    -- Frame layout is unchanged: an old peer still parses our LOGOUT frame fine,
    -- it simply has no arm for the op.
    local lf = Mesh.BuildFrame(Mesh.OP.LOGOUT, "", { seq = 0 })
    local parsed = Mesh.ParseFrame(lf)
    if not parsed then return false, "LOGOUT frame does not parse" end
    if parsed.version ~= Mesh.PROTO_VERSION then return false, "LOGOUT frame changed the version byte" end
    if parsed.op ~= "l" then return false, "LOGOUT op code drifted" end
    if parsed.payload ~= "" then return false, "LOGOUT payload is not empty" end
    return true
end

-- PER-TARGET COOLDOWNS (A10.7 / spec §9.5): one send per target per window, for
-- each kind, with the spec's numbers — plus the prune that keeps the map bounded.
local function testSendCooldowns()
    -- Spec numbers, pinned.
    if Mesh.MANIFEST_COOLDOWN ~= 5 then return false, "manifest cooldown must be 5s" end
    if Mesh.SEGMENT_COOLDOWN ~= 60 then return false, "segment cooldown must be 60s" end
    if Mesh.TIMERSYNC_COOLDOWN ~= 30 then return false, "timer-sync cooldown must be 30s" end

    local savedCd, savedEnq = Mesh._sendCooldowns, Mesh.Enqueue
    local savedPeers, savedGet = Mesh.peers, Store.GetAccount
    Mesh._sendCooldowns = {}
    local ok, why = true, nil

    -- PURE gate: first send allowed, repeat inside the window refused, and the
    -- window is exclusive at its edge.
    local cds, K = {}, Mesh.SendCooldownKey("manifest", "Bob-R", "9\2sixties")
    if not Mesh.ShouldSendTo(K, cds, 100, 5) then ok, why = false, "first send refused" end
    cds[K] = 100
    if ok and Mesh.ShouldSendTo(K, cds, 104, 5) then ok, why = false, "repeat inside window allowed" end
    if ok and not Mesh.ShouldSendTo(K, cds, 105, 5) then ok, why = false, "send refused at window edge" end
    -- Different target / different account+area are independent keys.
    if ok and not Mesh.ShouldSendTo(Mesh.SendCooldownKey("manifest", "Amy-R", "9\2sixties"), cds, 101, 5) then
        ok, why = false, "cooldown leaked across targets"
    end
    if ok and not Mesh.ShouldSendTo(Mesh.SendCooldownKey("manifest", "Bob-R", "9\2summoners"), cds, 101, 5) then
        ok, why = false, "cooldown leaked across segments"
    end

    -- SendGate stamps on success and refuses (and counts) on the repeat.
    if ok then
        local gated = Mesh._sendGated or 0
        if not Mesh.SendGate("timersync", "Bob-R", nil, 30, 200) then ok, why = false, "gate refused a first send" end
        if ok and Mesh.SendGate("timersync", "Bob-R", nil, 30, 210) then ok, why = false, "gate allowed a repeat" end
        if ok and (Mesh._sendGated or 0) ~= gated + 1 then ok, why = false, "gate telemetry did not advance" end
        if ok and Mesh.SendGate("timersync", "Bob-R", nil, 30, 231) ~= true then
            ok, why = false, "gate never reopened"
        end
    end

    -- The senders actually consult it. Count enqueues with the real functions.
    if ok then
        local sends = 0
        Mesh.Enqueue = function() sends = sends + 1 end
        Mesh.peers = {}
        -- Blacklist: button-mash guard. Two back-to-back calls, one send.
        Mesh._sendCooldowns = {}
        Mesh.SendBlacklist("Bob-R")
        Mesh.SendBlacklist("Bob-R")
        if sends ~= 1 then ok, why = false, "SendBlacklist fanned out twice (" .. sends .. ")" end
        -- Timer snapshot reply: same shape, 30s window.
        if ok then
            sends = 0
            Mesh._sendCooldowns = {}
            Mesh.SendTimers("Bob-R")
            Mesh.SendTimers("Bob-R")
            if sends ~= 1 then ok, why = false, "SendTimers replied twice (" .. sends .. ")" end
        end
        -- Manifest: gate runs BEFORE any store work, so a suppressed send is free.
        if ok then
            sends = 0
            local looked = 0
            Store.GetAccount = function() looked = looked + 1 return nil end
            Mesh._sendCooldowns = {}
            Mesh.SendManifest("Bob-R", "9", "sixties")
            Mesh.SendManifest("Bob-R", "9", "sixties")
            if looked ~= 1 then ok, why = false, "gated manifest still hit the store" end
            if ok then
                Mesh.SendSegment("Bob-R", "9", "sixties")
                Mesh.SendSegment("Bob-R", "9", "sixties")
                if looked ~= 2 then ok, why = false, "gated segment still hit the store" end
            end
        end
        Store.GetAccount = savedGet
        Mesh.Enqueue = savedEnq
        Mesh.peers = savedPeers
    end

    -- Prune drops entries older than the horizon and keeps fresh ones. (Ping
    -- cooldowns are parked too: PruneCooldowns sweeps both maps, and a self-test
    -- run in-game must not disturb the live roster-ping throttle.)
    if ok then
        local horizon = 60 * (Mesh.SEND_COOLDOWN_PRUNE or 4)
        local savedPing = Mesh._pingCooldowns
        Mesh._pingCooldowns = {}
        Mesh._sendCooldowns = { old = 0, fresh = horizon }
        Mesh.PruneCooldowns(horizon + 1)
        Mesh._pingCooldowns = savedPing
        if Mesh._sendCooldowns.old ~= nil then ok, why = false, "stale cooldown not pruned" end
        if ok and Mesh._sendCooldowns.fresh == nil then ok, why = false, "live cooldown was pruned" end
    end

    Mesh._sendCooldowns, Mesh.Enqueue = savedCd, savedEnq
    Mesh.peers, Store.GetAccount = savedPeers, savedGet
    return ok, why
end

-- _ackWait must not accumulate: the parent entry goes when its member set
-- empties, and a set that never empties expires on a TTL.
local function testAckWaitCleanup()
    local savedWait, savedAt = Mesh._ackWait, Mesh._ackWaitAt
    local savedUnpack, savedBL = Mesh.Unpack, Mesh.SendBlacklist
    Mesh._ackWait, Mesh._ackWaitAt = {}, {}
    Mesh.SendBlacklist = function() end     -- suppress the auto-chain
    local ok, why = true, nil

    -- Two targets outstanding; the parent survives the first ACK and goes on the last.
    Mesh._ackWait["s1"] = { ["A-R"] = true, ["B-R"] = true }
    Mesh._ackWaitAt["s1"] = 500
    Mesh.Unpack = function() return { syncId = "s1", kind = "settings" } end
    Mesh._handleAck({ payload = "w" }, "A-R")
    if not Mesh._ackWait["s1"] then ok, why = false, "parent dropped while a target was outstanding" end
    if ok then
        Mesh._handleAck({ payload = "w" }, "B-R")
        if Mesh._ackWait["s1"] ~= nil then ok, why = false, "emptied wait set was not dropped" end
        if ok and Mesh._ackWaitAt["s1"] ~= nil then ok, why = false, "wait timestamp leaked" end
    end

    -- TTL backstop for the set that never empties (a peer that never answers).
    if ok then
        Mesh._ackWait["s2"] = { ["Ghost-R"] = true }
        Mesh._ackWaitAt["s2"] = 1000
        Mesh.PruneAckWait(1000 + Mesh.ACK_WAIT_TTL - 1)
        if not Mesh._ackWait["s2"] then ok, why = false, "wait set expired before its TTL" end
        if ok then
            Mesh.PruneAckWait(1000 + Mesh.ACK_WAIT_TTL + 1)
            if Mesh._ackWait["s2"] ~= nil then ok, why = false, "wait set outlived its TTL" end
            if ok and Mesh._ackWaitAt["s2"] ~= nil then ok, why = false, "orphan timestamp survived" end
        end
    end
    -- An entry with no timestamp is ADOPTED (given a full TTL), never nuked.
    if ok then
        Mesh._ackWait["s3"] = { ["C-R"] = true }
        Mesh.PruneAckWait(2000)
        if not Mesh._ackWait["s3"] then ok, why = false, "untimestamped wait set was nuked" end
        if ok and Mesh._ackWaitAt["s3"] ~= 2000 then ok, why = false, "untimestamped set was not adopted" end
    end

    Mesh._ackWait, Mesh._ackWaitAt = savedWait, savedAt
    Mesh.Unpack, Mesh.SendBlacklist = savedUnpack, savedBL
    return ok, why
end

-- _inSeq must not accumulate a record per stranger who ever whispered us, but
-- must never drop a CURRENT peer's high-water (that would re-open replay).
local function testInSeqPrune()
    local savedSeq, savedPeers = Mesh._inSeq, Mesh.peers
    Mesh._inSeq = {}
    Mesh.peers = { ["3"] = { aid = "3", name = "Live-R", online = true } }
    local ok, why = true, nil
    local T = 10000

    Mesh.FreshSeq("Live-R\1DSKN1", 5, "aa", T)
    Mesh.FreshSeq("Gone-R\1DSKN1", 5, "bb", T)
    Mesh.FreshSeq("Recent-R\1DSKN1", 5, "cc", T)
    if Mesh._inSeq["Live-R\1DSKN1"].t ~= T then ok, why = false, "FreshSeq did not stamp the record" end

    -- Well past the TTL for the two non-peers; the live peer is exempt.
    if ok then
        Mesh._inSeq["Recent-R\1DSKN1"].t = T + Mesh.INSEQ_TTL   -- consulted recently
        local dropped = Mesh.PruneInSeq(T + Mesh.INSEQ_TTL + 1)
        if Mesh._inSeq["Live-R\1DSKN1"] == nil then ok, why = false, "pruned a current peer's high-water" end
        if ok and Mesh._inSeq["Gone-R\1DSKN1"] ~= nil then ok, why = false, "stale stranger not pruned" end
        if ok and Mesh._inSeq["Recent-R\1DSKN1"] == nil then ok, why = false, "recently used record pruned" end
        if ok and dropped ~= 1 then ok, why = false, "prune count wrong: " .. tostring(dropped) end
    end
    -- The high-water still rejects a replay after the prune.
    if ok then
        if Mesh.FreshSeq("Live-R\1DSKN1", 4, "aa", T + 1) then
            ok, why = false, "replay accepted after prune"
        end
    end
    -- Records created before this build carry no stamp: adopt, don't drop.
    if ok then
        Mesh._inSeq["Legacy-R\1DSKN1"] = { sess = "zz", last = 9 }
        Mesh.PruneInSeq(T + 5)
        if Mesh._inSeq["Legacy-R\1DSKN1"] == nil then ok, why = false, "unstamped record was nuked" end
    end

    Mesh._inSeq, Mesh.peers = savedSeq, savedPeers
    return ok, why
end

-- B5: a deferred guild broadcast is dropped when the identical payload shows up
-- from another self-elected broadcaster while we are still waiting.
local function testBroadcastJitter()
    local savedPending, savedSend = Mesh._bcastPending, Mesh.SendTimerSnapshot
    local sent = 0
    Mesh.SendTimerSnapshot = function() sent = sent + 1 end
    local ok, why = true, nil
    local h = Mesh.BroadcastPayloadHash("packed-snapshot")

    if Mesh.BroadcastPayloadHash("packed-snapshot") ~= h then
        ok, why = false, "payload hash is not stable"
    end
    if ok and Mesh.BroadcastPayloadHash("other-snapshot") == h then
        ok, why = false, "payload hash does not separate payloads"
    end
    -- Armed, then the winner's copy arrives: we cancel and send nothing.
    if ok then
        local cancels = Mesh._bcastCancelled or 0
        Mesh._bcastPending = { hash = h, payload = "packed-snapshot", at = 0 }
        if not Mesh.CancelPendingBroadcast(h) then ok, why = false, "matching payload did not cancel" end
        if ok and Mesh._bcastPending ~= nil then ok, why = false, "cancelled broadcast still armed" end
        if ok and (Mesh._bcastCancelled or 0) ~= cancels + 1 then
            ok, why = false, "cancel telemetry did not advance"
        end
        if ok and Mesh.FlushPendingBroadcast(h) then ok, why = false, "cancelled broadcast still fired" end
        if ok and sent ~= 0 then ok, why = false, "cancelled broadcast reached the wire" end
    end
    -- A DIFFERENT payload must not cancel ours.
    if ok then
        Mesh._bcastPending = { hash = h, payload = "packed-snapshot", at = 0 }
        if Mesh.CancelPendingBroadcast(Mesh.BroadcastPayloadHash("other-snapshot")) then
            ok, why = false, "an unrelated payload cancelled our broadcast"
        end
        if ok and not Mesh.FlushPendingBroadcast(h) then ok, why = false, "armed broadcast did not fire" end
        if ok and sent ~= 1 then ok, why = false, "flush did not reach the transport" end
        if ok and Mesh._bcastPending ~= nil then ok, why = false, "pending slot not released after send" end
    end
    -- A stale timer for a superseded payload must not fire the new one.
    if ok then
        Mesh._bcastPending = { hash = Mesh.BroadcastPayloadHash("newer"), payload = "newer", at = 0 }
        if Mesh.FlushPendingBroadcast(h) then ok, why = false, "stale timer fired a superseded payload" end
        if ok and sent ~= 1 then ok, why = false, "superseded payload was sent" end
    end
    if ok and (Mesh.BCAST_JITTER_MAX or 0) <= 0 then ok, why = false, "jitter window is disabled" end

    Mesh._bcastPending, Mesh.SendTimerSnapshot = savedPending, savedSend
    return ok, why
end

function Mesh.RunSelfTests(verbose)
    local suite = {
        { name = "logout re-stamp",     fn = testLogoutRestamp },
        { name = "presence stale latch", fn = testStaleLatch },
        { name = "unknown op ignored",  fn = testUnknownOpIgnored },
        { name = "per-target cooldowns", fn = testSendCooldowns },
        { name = "ack-wait cleanup",    fn = testAckWaitCleanup },
        { name = "inSeq prune",         fn = testInSeqPrune },
        { name = "broadcast jitter",    fn = testBroadcastJitter },
        { name = "state content hash", fn = testStateHash },
        { name = "push suppressor",    fn = testPushSuppressor },
        { name = "inbound repaint pump", fn = testInboundRepaintPump },
        { name = "own-account authority (wire)", fn = testOwnAccountAuthorityWire },
        { name = "push delivery count",  fn = testPushDeliveryCount },
        { name = "segment content fingerprint (§9.6)", fn = testSegmentFingerprint },
        { name = "canonical peer names", fn = testCanonicalPeerNames },
        { name = "peer timeout sweep", fn = testPeerSweep },
        { name = "direct budget",      fn = testDirectBudget },
        { name = "relay age gate",     fn = testRelayAgeGate },
        { name = "online-hint discovery", fn = testOnlineHintDiscovery },
        { name = "transmit safety",  fn = testTransmitSafety },
        { name = "snapshot handoff", fn = testSnapshotHandoff },
        { name = "state-changed guard", fn = testStateChangedGuard },
        { name = "relay assignment", fn = testRelayPlan },
        { name = "hash diff",        fn = testHashDiff },
        { name = "namespace hash diff", fn = testNamespaceDiff },
        { name = "fresh ns push outranks bulk backfill", fn = testNSPushPriority },
        { name = "instances hash",   fn = testInstancesHash },
        { name = "dedup window",     fn = testDedupWindow },
        { name = "frame round-trip", fn = testFrameRoundTrip },
        { name = "session seq",      fn = testFreshSeq },
        { name = "malformed msgId",  fn = testMalformedMsgId },
        { name = "failure skip",     fn = testFailureSkip },
        { name = "join state machine", fn = testJoinStateMachine },
        { name = "reload race rejoin", fn = testReloadRace },
        { name = "channel health check", fn = testHealthCheck },
        { name = "roster ping selection", fn = testRosterPingSelection },
        { name = "join notice throttle", fn = testJoinNoticeThrottle },
        { name = "channel gating",   fn = testChannelGating },
        { name = "account conflict", fn = testAccountConflict },
        { name = "item cd wire boundary (A9.1)", fn = testItemCdWireBoundary },
        { name = "manifest ghost cleanup wiring (B4)", fn = testManifestWiring },
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
