-- Daseeki Nexus — protocol.lua  (WAVE N1: SCAFFOLDING ONLY)
-- Prefix constants + registration, and the pure-Lua building blocks the
-- mesh layer (wave N2) will drive: a per-prefix token bucket, priority
-- queue, message chunker, and our own compact binary state schema.
--
-- No addon messages are SENT this wave. Everything here is exercised by
-- /dsn debug selftest, which runs the round-trip and data-structure
-- tests below with zero network I/O.
--
-- Clean-room: prefixes and schema are Daseeki's own design (DSKN0..DSKN3);
-- there is deliberately no wire-compatibility with any other addon.

local ADDON, ns = ...

local Protocol = {}
ns.Protocol = Protocol

----------------------------------------------------------------------
-- Prefix constants (roles mirror the design: timer / state / heartbeat / sync)
----------------------------------------------------------------------

Protocol.PREFIX = {
    TIMER     = "DSKN0",   -- timer broadcasts + pull alerts
    STATE     = "DSKN1",   -- cross-account state pushes + relays
    HEARTBEAT = "DSKN2",   -- heartbeats + discovery
    SYNC      = "DSKN3",   -- handshakes / bulk sync (manifests, segments, settings)
}

Protocol.PREFIX_LIST = {
    Protocol.PREFIX.TIMER,
    Protocol.PREFIX.STATE,
    Protocol.PREFIX.HEARTBEAT,
    Protocol.PREFIX.SYNC,
}

-- Binary state-schema version. BUMP HISTORY:
--   v1 — original character record.
--   v2 — appended xp (u32), xpMax (u32), restedXP (u32) at the END of the
--        pack/unpack order (Experience/Rest view).
--   v3 — appended dmfCooldownRemaining (u32) at the END: the Darkmoon Faire
--        buff-cooldown REMAINING SECONDS as of the frame's lastDataUpdate, so a
--        peer's card can show a real countdown instead of the bare flag bit
--        (NEXUS_SCHEMA_V3_DESIGN.md §J4 / D4). 0 means "not sent / unknown",
--        which is what an ABSENT tail reads as, so the two are the same state
--        and the card falls back to today's flag-only rendering for both.
--
-- DECODER TOLERANCE (release gate D-14 / NW-7). DecodeCharacter accepts any
-- schema from 1 up to SCHEMA_TOLERATED (see below) and rejects anything above
-- it. Every bump so far has been append-at-the-tail and newReader reads 0 / ""
-- past the end of the buffer, so an OLDER payload decodes with its absent tail
-- fields reading as "not sent" — which is exactly what they mean.
--
-- The tolerance must ship one release BEFORE the encoder that needs it,
-- otherwise the release that introduces v3 also breaks every v2 peer that has
-- not updated yet. That is the whole point of it landing at v2 — which it did,
-- in wave 1 of this same design pass.
Protocol.SCHEMA_VERSION = 3     -- our binary state-schema version — what we ENCODE

-- THE TOLERANCE WINDOW (schema-v3 wave 2, "release B" of NEXUS_SCHEMA_V3_DESIGN.md
-- §J4). The encoder is now at v3 and the window is PINNED ONE VERSION WIDE:
--
--     SCHEMA_VERSION == SCHEMA_TOLERATED == 3   -- we send v3, we accept <= 3
--
-- Wave 1 raised the tolerance to 3 while still ENCODING v2, so the two constants
-- were briefly apart; this wave closes the gap by moving the ENCODER up to meet
-- it. Nothing about the acceptance rule changed — <= 3 is still admitted, 4 is
-- still refused — so a peer that took wave 1 (or this release) reads our frames,
-- and the pair stays "we never emit a version we would not accept ourselves".
--
-- WHY THE TWO CONSTANTS EXIST AT ALL, restated so the next bump inherits it. A
-- reader gate that refuses ANY version above what we ENCODE means the release
-- that first emits vN+1 goes one-way blind to every peer that has not updated,
-- and a mixed public mesh splits in half for a whole release cycle. Splitting
-- "what we send" from "what we accept" lets release A teach the mesh to swallow
-- the next schema and release B flip the encoder into a mesh already prepared.
-- The NEXT bump repeats the pattern: raise SCHEMA_TOLERATED to 4 in one release,
-- SCHEMA_VERSION to 4 in a later one.
--
-- WHAT THE OWNER KNOWINGLY GAVE UP HERE. Waves 1 and 2 ship in the SAME release
-- (owner decision 2026-08-07, "so we don't have multiple deployments"), so the
-- two-release rollout is collapsed: a peer still on 1.1.4 or older has a reader
-- that stops at v2 and will REFUSE our v3 STATE frames outright until it
-- updates. Same-machine meshes update atomically (one shared AddOns folder);
-- only a split-machine mesh sees one-way staleness, and only until both sides
-- are on 1.1.5. See NEXUS_SCHEMA_V3_DESIGN.md "Package as executed", and
-- testMixedVersionMatrix below, which asserts that cost rather than hiding it.
--
-- WHY IT IS SAFE TO DECODE A SCHEMA WE DO NOT ENCODE (the property the window
-- rests on, still true). The append-at-tail contract in the bump history above
-- is the whole guarantee: every bump has ADDED fields at the END and never moved
-- or resized an existing one, so the v2 prefix of a v3 frame is byte-identical
-- to a v2 frame. testGoldenV2Prefix pins that structurally against real bytes.
-- A reader that stops early simply never reads the tail, and newReader's
-- read-past-end already yields 0 / "" for an ABSENT one — so an unknown or
-- missing appended field decodes as "not sent", which is what it means.
--
-- THE TOLERANCE IS NOT OPEN-ENDED. v4 is still refused: nothing constrains a
-- schema two bumps out, and silently decoding it would be guessing. Version 0
-- stays rejected too — it is what an empty or truncated buffer reads as, not a
-- schema.
Protocol.SCHEMA_TOLERATED = 3   -- highest version DecodeCharacter will accept

-- Register every prefix so inbound messages reach CHAT_MSG_ADDON. Safe to
-- call once logged in; the mesh dispatcher attaches in wave N2.
function Protocol.OnLogin()
    if not (C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix) then
        return
    end
    for i = 1, #Protocol.PREFIX_LIST do
        C_ChatInfo.RegisterAddonMessagePrefix(Protocol.PREFIX_LIST[i])
    end
end

----------------------------------------------------------------------
-- Token bucket  (per-prefix; cap 8, refill 1/s)
----------------------------------------------------------------------

local TokenBucket = {}
TokenBucket.__index = TokenBucket
Protocol.TokenBucket = TokenBucket

function TokenBucket.new(cap, refillPerSec, now)
    return setmetatable({
        cap    = cap or 8,
        tokens = cap or 8,
        refill = refillPerSec or 1,
        last   = now or 0,
    }, TokenBucket)
end

function TokenBucket:Refill(now)
    if now > self.last then
        local gained = (now - self.last) * self.refill
        self.tokens = math.min(self.cap, self.tokens + gained)
        self.last = now
    end
end

-- Try to consume n tokens at time `now`. Returns true on success.
function TokenBucket:TryConsume(n, now)
    n = n or 1
    if now then self:Refill(now) end
    if self.tokens >= n then
        self.tokens = self.tokens - n
        return true
    end
    return false
end

----------------------------------------------------------------------
-- Priority queue  (lower priority number = served first; FIFO within a tier)
----------------------------------------------------------------------

local PriorityQueue = {}
PriorityQueue.__index = PriorityQueue
Protocol.PriorityQueue = PriorityQueue

function PriorityQueue.new()
    return setmetatable({ items = {}, seq = 0 }, PriorityQueue)
end

function PriorityQueue:Push(priority, item)
    self.seq = self.seq + 1
    self.items[#self.items + 1] = { priority = priority, seq = self.seq, item = item }
end

function PriorityQueue:IsEmpty()
    return #self.items == 0
end

function PriorityQueue:Size()
    return #self.items
end

-- Remove and return the highest-priority item (lowest number, then oldest).
function PriorityQueue:Pop()
    local best, bestIdx
    for i = 1, #self.items do
        local e = self.items[i]
        if not best
           or e.priority < best.priority
           or (e.priority == best.priority and e.seq < best.seq) then
            best, bestIdx = e, i
        end
    end
    if not best then return nil end
    table.remove(self.items, bestIdx)
    return best.item, best.priority
end

----------------------------------------------------------------------
-- Chunking  (>255-byte messages -> single/first/middle/last markers + seq)
----------------------------------------------------------------------

local Chunk = {}
Protocol.Chunk = Chunk
Chunk.MAX = 255

-- Split payload into ordered chunk tables. `seq` is the per-target
-- sequence id carried on every chunk so a receiver can group them.
function Chunk.Split(payload, seq, maxLen)
    maxLen = maxLen or Chunk.MAX
    seq = seq or 0
    if #payload <= maxLen then
        return { { marker = "S", seq = seq, index = 1, total = 1, data = payload } }
    end
    local total = math.ceil(#payload / maxLen)
    local chunks = {}
    for i = 1, total do
        local part = payload:sub((i - 1) * maxLen + 1, i * maxLen)
        local marker = (i == 1 and "F") or (i == total and "L") or "M"
        chunks[i] = { marker = marker, seq = seq, index = i, total = total, data = part }
    end
    return chunks
end

-- Reassemble ordered/unordered chunks back into the original payload.
-- Returns payload, ok. ok is false if a chunk is missing.
function Chunk.Reassemble(chunks)
    local byIndex, total = {}, nil
    for i = 1, #chunks do
        local c = chunks[i]
        byIndex[c.index] = c.data
        total = c.total
    end
    if not total then return "", false end
    local parts = {}
    for i = 1, total do
        if byIndex[i] == nil then return "", false end
        parts[i] = byIndex[i]
    end
    return table.concat(parts), true
end

----------------------------------------------------------------------
-- Binary writer / reader (big-endian unsigned ints, length-prefixed strings)
----------------------------------------------------------------------

local function newWriter()
    local buf = {}
    local w = {}
    function w.u8(v)
        v = math.floor(v or 0) % 256
        buf[#buf + 1] = string.char(v)
    end
    -- CLAMP, not wrap. `% 65536` turned an out-of-range value into a plausible
    -- WRONG one: 65536 became 0 and 70000 became 4464, so a bad duration or
    -- cooldown decoded as a believable small number instead of an obvious
    -- ceiling. Saturating at the range ends keeps the error monotonic (too big
    -- reads as "the maximum", never as "almost none"). This is NOT a wire-format
    -- change: the field is still exactly two big-endian bytes and every value
    -- that was already in [0, 65535] encodes byte-identically. SCHEMA_VERSION
    -- therefore stays put.
    function w.u16(v)
        v = math.floor(tonumber(v) or 0)
        if v < 0 then v = 0 elseif v > 65535 then v = 65535 end
        buf[#buf + 1] = string.char(math.floor(v / 256) % 256, v % 256)
    end
    function w.u32(v)
        v = math.floor(v or 0) % 4294967296
        buf[#buf + 1] = string.char(
            math.floor(v / 16777216) % 256,
            math.floor(v / 65536) % 256,
            math.floor(v / 256) % 256,
            v % 256)
    end
    function w.str(s)
        s = s or ""
        if #s > 255 then s = s:sub(1, 255) end
        w.u8(#s)
        buf[#buf + 1] = s
    end
    function w.result() return table.concat(buf) end
    return w
end

local function newReader(bytes)
    local pos = 1
    local r = {}
    function r.u8()
        local b = string.byte(bytes, pos) or 0
        pos = pos + 1
        return b
    end
    function r.u16()
        local a, b = string.byte(bytes, pos, pos + 1)
        pos = pos + 2
        return (a or 0) * 256 + (b or 0)
    end
    function r.u32()
        local a, b, c, d = string.byte(bytes, pos, pos + 3)
        pos = pos + 4
        return (a or 0) * 16777216 + (b or 0) * 65536 + (c or 0) * 256 + (d or 0)
    end
    function r.str()
        local n = r.u8()
        local s = bytes:sub(pos, pos + n - 1)
        pos = pos + n
        return s
    end
    return r
end

----------------------------------------------------------------------
-- Binary state schema (version 1) — compact character-record encoding
--
-- Field order (must match decode exactly):
--   u8  schema version
--   u8  flags  (bit0 inInstance, bit1 isResting, bit2 pvpFlagged,
--               bit3 chronoboonActive, bit4 dmfInBoon, bit5 dmfCooldownActive,
--               bit6 soulstoneReady)
--   u8  classIndex (into Store.CLASS_ORDER; 0 = unknown)
--   u8  faction    (0 none, 1 Alliance, 2 Horde)
--   u8  level
--   u8  boonCount
--   u8  shardCount
--   u16 itemCooldown        (seconds remaining)
--   u16 hearthstoneCD       (seconds remaining)
--   u32 pvpExpiry           (epoch)
--   u32 chronoboonLastSeen  (epoch)
--   u32 dmfOfflineSince     (epoch)
--   u32 lastSeen            (epoch)
--   u32 lastDataUpdate      (epoch)
--   u32 ownerEpoch          (sync tiebreaker)
--   u8  raid mask (bit i set => raid i present, order Store.RAID_KEYS)
--   [per set bit]  u32 expiry epoch
--   u8  aura count (<=10)
--   [per aura]  u8 slotIndex, u16 duration, u8 option, u8 source
--   str nameRealm
--   str className
--   str location
--   u32 xp                  (current XP into the level; 0 at max level)   [v2]
--   u32 xpMax               (total XP for the level;    0 at max level)   [v2]
--   u32 restedXP            (rested/double-XP pool;      0 when unrested)  [v2]
--   u32 dmfCooldownRemaining (DMF buff-cooldown seconds left AS OF this     [v3]
--                             frame's lastDataUpdate; 0 = not sent/unknown)
----------------------------------------------------------------------

local FACTION_TO_CODE = { Alliance = 1, Horde = 2 }
local CODE_TO_FACTION = { [1] = "Alliance", [2] = "Horde" }

local function classIndexOf(classTag)
    if not classTag then return 0 end
    for i = 1, #ns.Store.CLASS_ORDER do
        if ns.Store.CLASS_ORDER[i] == classTag then return i end
    end
    return 0
end

local function bit_set(mask, bitpos)
    -- bitpos 0-based. Uses arithmetic (Lua 5.1, no bit ops guaranteed).
    return (math.floor(mask / (2 ^ bitpos)) % 2) == 1
end

function Protocol.EncodeCharacter(rec)
    -- Defensive: never index a non-table. Callers (mesh PushState) treat a nil
    -- return as "nothing to send". This backstops any caller that fires a
    -- state-change signal without a real record (see import.lua STORE_REFRESHED).
    if type(rec) ~= "table" then return nil end
    local w = newWriter()
    w.u8(Protocol.SCHEMA_VERSION)

    local flags = 0
    if rec.inInstance        then flags = flags + 1  end
    if rec.isResting         then flags = flags + 2  end
    if rec.pvpFlagged        then flags = flags + 4  end
    if rec.chronoboonActive  then flags = flags + 8  end
    if rec.dmfInBoon         then flags = flags + 16 end
    if rec.dmfCooldownActive then flags = flags + 32 end
    if rec.soulstoneReady    then flags = flags + 64 end
    w.u8(flags)

    w.u8(classIndexOf(rec.classTag))
    w.u8(FACTION_TO_CODE[rec.faction or ""] or 0)
    w.u8(rec.level or 0)
    w.u8(rec.boonCount or 0)
    w.u8(rec.shardCount or 0)
    w.u16(rec.itemCooldown or 0)
    w.u16(rec.hearthstoneCD or 0)
    w.u32(rec.pvpExpiry or 0)
    w.u32(rec.chronoboonLastSeen or 0)
    w.u32((rec.dmfCooldown and rec.dmfCooldown.offlineSince) or 0)
    w.u32(rec.lastSeen or 0)
    w.u32(rec.lastDataUpdate or 0)
    w.u32(rec.ownerEpoch or 0)

    -- Raid lockouts: fixed order, mask + present expiries.
    local raidKeys = ns.Store.RAID_KEYS
    local mask, present = 0, {}
    for i = 1, #raidKeys do
        local expiry = rec.raidLockouts and rec.raidLockouts[raidKeys[i]]
        if expiry and expiry > 0 then
            mask = mask + 2 ^ (i - 1)
            present[#present + 1] = expiry
        end
    end
    w.u8(mask)
    for i = 1, #present do w.u32(present[i]) end

    -- Aura slots (max 10).
    local auras = rec.auraStates or {}
    local count = 0
    for i = 1, 10 do if auras[i] then count = count + 1 end end
    w.u8(count)
    for i = 1, 10 do
        local a = auras[i]
        if a then
            w.u8(i)
            w.u16(a.duration or 0)
            w.u8(a.option or 0)
            w.u8(a.source or 0)
        end
    end

    w.str(rec.nameRealm or "")
    w.str(rec.className or "")
    w.str(rec.location or "")

    -- v2 tail: experience + rested pool (u32 clamps to the u32 range in w.u32).
    w.u32(rec.xp or 0)
    w.u32(rec.xpMax or 0)
    w.u32(rec.restedXP or 0)

    -- v3 tail (§J4): the DMF buff-cooldown remaining seconds. APPENDED, never
    -- interleaved — everything above this line is byte-identical to what the v2
    -- encoder wrote for the same record, which is the contract testGoldenV2Prefix
    -- pins against real bytes and the whole reason an older reader can stop early.
    --
    -- THE VALUE IS A MIRROR, NOT A DERIVATION. tracker.lua's captureDMF writes
    -- rec.dmfCooldownRemaining from Store.DMFCooldownRemaining on every capture,
    -- in the same pass that stamps lastDataUpdate — so the number that goes out is
    -- true AS OF that stamp and the receiver can decay it against it. Re-deriving
    -- here would be re-deriving from the same field the tracker already ticked,
    -- one capture later, for nothing. 0 = "no countdown to report", which is also
    -- exactly what an ABSENT tail reads as on a v1/v2 frame.
    w.u32(rec.dmfCooldownRemaining or 0)

    return w.result()
end

function Protocol.DecodeCharacter(bytes)
    local r = newReader(bytes)
    local version = r.u8()
    -- Accept every schema from 1 up to SCHEMA_TOLERATED — that is every OLDER
    -- one plus the one release-B will encode. The body below reads the v2 field
    -- order unconditionally: an older payload's absent tail reads as 0/"" and a
    -- newer payload's appended tail is simply never read (append-at-tail
    -- contract; see the SCHEMA_TOLERATED block above). Anything ABOVE the
    -- tolerance is still refused — we cannot know what its extra fields
    -- displaced. Version 0 is not a schema — it is what an empty or truncated
    -- buffer reads as — so it stays rejected.
    if version < 1 or version > Protocol.SCHEMA_TOLERATED then
        return nil, "unsupported schema version " .. tostring(version)
    end

    local rec = ns.Store.NewCharacterRecord(nil)

    local flags = r.u8()
    rec.inInstance        = bit_set(flags, 0)
    rec.isResting         = bit_set(flags, 1)
    rec.pvpFlagged        = bit_set(flags, 2)
    rec.chronoboonActive  = bit_set(flags, 3)
    rec.dmfInBoon         = bit_set(flags, 4)
    rec.dmfCooldownActive = bit_set(flags, 5)
    rec.soulstoneReady    = bit_set(flags, 6)

    local classIdx = r.u8()
    rec.classTag = ns.Store.CLASS_ORDER[classIdx] or nil
    rec.faction  = CODE_TO_FACTION[r.u8()] or nil
    rec.level        = r.u8()
    rec.boonCount    = r.u8()
    rec.shardCount   = r.u8()
    rec.itemCooldown = r.u16()
    rec.hearthstoneCD = r.u16()
    rec.pvpExpiry    = r.u32()
    rec.chronoboonLastSeen = r.u32()
    rec.dmfCooldown = { offlineSince = r.u32() }
    rec.lastSeen       = r.u32()
    rec.lastDataUpdate = r.u32()
    rec.ownerEpoch     = r.u32()

    local raidKeys = ns.Store.RAID_KEYS
    local mask = r.u8()
    rec.raidLockouts = {}
    for i = 1, #raidKeys do
        if bit_set(mask, i - 1) then
            rec.raidLockouts[raidKeys[i]] = r.u32()
        end
    end

    local count = r.u8()
    rec.auraStates = {}
    for _ = 1, count do
        local slot = r.u8()
        local duration = r.u16()
        local option = r.u8()
        local source = r.u8()
        rec.auraStates[slot] = { duration = duration, option = option, source = source }
    end

    rec.nameRealm = r.str()
    rec.className = r.str()
    rec.location  = r.str()
    if rec.nameRealm == "" then rec.nameRealm = nil end
    if rec.className == "" then rec.className = nil end
    if rec.location == ""  then rec.location = nil end

    -- v2 tail: experience + rested pool (read in the same appended order).
    rec.xp       = r.u32()
    rec.xpMax    = r.u32()
    rec.restedXP = r.u32()

    -- v3 tail: the DMF buff-cooldown remaining seconds. Only a v3 frame CARRIES
    -- it, and it is read the same way every tail before it is read — flatly, in
    -- appended order, with no version branch. On a v1/v2 frame the reader is
    -- already past the end of the buffer here and newReader's read-past-end
    -- yields 0, which IS the field's "not sent / unknown" value: the card falls
    -- back to the flag-only rendering it has always had. The version gate above
    -- has already refused anything newer than SCHEMA_TOLERATED, so the only
    -- frames that reach this line are v1/v2 (tail absent -> 0) and v3 (tail
    -- present). Branching on the version here would buy nothing and would make
    -- the ONE contract every bump depends on stop being exercised.
    rec.dmfCooldownRemaining = r.u32()

    return rec
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; run via /dsn debug selftest)
----------------------------------------------------------------------

local function approxEqualField(a, b)
    return a == b or ((a or false) == (b or false))
end

-- Deep-compare the fields the binary schema round-trips.
local function recordsMatch(a, b)
    local scalars = {
        "classTag", "faction", "level", "boonCount", "shardCount",
        "itemCooldown", "hearthstoneCD", "pvpExpiry", "chronoboonLastSeen",
        "lastSeen", "lastDataUpdate", "ownerEpoch", "nameRealm",
        "className", "location",
        "xp", "xpMax", "restedXP",           -- v2 experience/rest tail
        "dmfCooldownRemaining",              -- v3 DMF countdown tail
    }
    for _, k in ipairs(scalars) do
        if a[k] ~= b[k] then
            return false, "scalar mismatch: " .. k ..
                " (" .. tostring(a[k]) .. " vs " .. tostring(b[k]) .. ")"
        end
    end
    local bools = {
        "inInstance", "isResting", "pvpFlagged", "chronoboonActive",
        "dmfInBoon", "dmfCooldownActive", "soulstoneReady",
    }
    for _, k in ipairs(bools) do
        if not approxEqualField(a[k], b[k]) then
            return false, "bool mismatch: " .. k
        end
    end
    if (a.dmfCooldown and a.dmfCooldown.offlineSince or 0)
        ~= (b.dmfCooldown and b.dmfCooldown.offlineSince or 0) then
        return false, "dmf offlineSince mismatch"
    end
    -- raid lockouts
    for k, v in pairs(a.raidLockouts or {}) do
        if (b.raidLockouts or {})[k] ~= v then
            return false, "raid lockout mismatch: " .. tostring(k)
        end
    end
    for k in pairs(b.raidLockouts or {}) do
        if (a.raidLockouts or {})[k] == nil then
            return false, "raid lockout extra: " .. tostring(k)
        end
    end
    -- auras
    for i = 1, 10 do
        local aa, ba = (a.auraStates or {})[i], (b.auraStates or {})[i]
        if (aa == nil) ~= (ba == nil) then
            return false, "aura slot presence mismatch at " .. i
        end
        if aa and ba then
            if aa.duration ~= ba.duration or aa.option ~= ba.option
               or aa.source ~= ba.source then
                return false, "aura field mismatch at " .. i
            end
        end
    end
    return true
end

local function testRoundTrip()
    local rec = ns.Store.NewCharacterRecord("Testchar-Whitemane")
    rec.classTag = "WARLOCK"
    rec.className = "Warlock"
    rec.faction = "Horde"
    rec.level = 58
    rec.location = "Rend Staging (S)"
    -- v2 experience/rest tail — non-zero values so the three u32 fields are proven
    -- to round-trip byte-exactly (sub-60 record carries live XP + a rested pool).
    rec.xp = 734512
    rec.xpMax = 1526400
    rec.restedXP = 381600
    rec.inInstance = false
    rec.isResting = true
    rec.pvpFlagged = true
    rec.pvpExpiry = 1785000300
    rec.chronoboonActive = true
    rec.chronoboonLastSeen = 1785000123
    rec.boonCount = 7
    rec.shardCount = 24
    rec.itemCooldown = 1800
    rec.hearthstoneCD = 420
    rec.dmfInBoon = true
    rec.dmfCooldownActive = true
    rec.soulstoneReady = true
    rec.dmfCooldown = { offlineSince = 1784990000 }
    -- v3 tail — a live countdown (3h 12m of the 4h owed), so the appended u32 is
    -- proven to round-trip byte-exactly rather than only proven to be present.
    rec.dmfCooldownRemaining = 11520
    rec.raidLockouts = { MC = 1785200000, BWL = 1785300000, Ony = 1785100000 }
    rec.auraStates = {
        [1] = { duration = 3600, option = 1, source = 0 },
        [3] = { duration = 7200, option = 2, source = 1 },
        [10] = { duration = 120, option = 0, source = 2 },
    }
    rec.lastSeen = 1785000500
    rec.lastDataUpdate = 1785000500
    rec.ownerEpoch = 1785000500

    local bytes = Protocol.EncodeCharacter(rec)
    local decoded, err = Protocol.DecodeCharacter(bytes)
    if not decoded then
        return false, "decode failed: " .. tostring(err), #bytes
    end
    local ok, why = recordsMatch(rec, decoded)
    if not ok then return ok, why, #bytes end
    -- The v2 tail is not just byte-equal, it is still USABLE at the far end: a
    -- peer's decoded record must satisfy the gate the instance log's Rest view
    -- reads it through (xpMax > 0), or the mesh delivers em-dashes to every peer.
    if ns.Store.RestedPercent(decoded) ~= 25 then
        return false, "decoded record lost its rested percent: "
            .. tostring(ns.Store.RestedPercent(decoded)), #bytes
    end
    return true, nil, #bytes
end

local function testTokenBucket()
    local b = TokenBucket.new(8, 1, 0)
    for _ = 1, 8 do
        if not b:TryConsume(1, 0) then return false, "should allow 8 consumes" end
    end
    if b:TryConsume(1, 0) then return false, "9th consume should fail" end
    -- refill 2 tokens after 2 seconds
    if not b:TryConsume(2, 2) then return false, "should refill 2 after 2s" end
    -- cap clamp: long wait must not exceed cap
    b:Refill(1000)
    if b.tokens > b.cap then return false, "refill exceeded cap" end
    return true
end

local function testPriorityQueue()
    local q = PriorityQueue.new()
    q:Push(2, "a")
    q:Push(1, "b")
    q:Push(1, "c")
    q:Push(3, "d")
    local order = {}
    while not q:IsEmpty() do
        order[#order + 1] = q:Pop()
    end
    local expected = { "b", "c", "a", "d" }
    for i = 1, #expected do
        if order[i] ~= expected[i] then
            return false, "order mismatch at " .. i ..
                " got " .. tostring(order[i]) .. " want " .. expected[i]
        end
    end
    return true
end

local function testChunking()
    local payload = string.rep("ABCDEFGHIJ", 60)   -- 600 bytes
    local chunks = Chunk.Split(payload, 42, 255)
    if #chunks ~= 3 then
        return false, "expected 3 chunks, got " .. #chunks
    end
    if chunks[1].marker ~= "F" or chunks[2].marker ~= "M" or chunks[3].marker ~= "L" then
        return false, "chunk markers wrong"
    end
    for i = 1, #chunks do
        if chunks[i].seq ~= 42 then return false, "seq not carried" end
    end
    local rebuilt, ok = Chunk.Reassemble(chunks)
    if not ok then return false, "reassemble reported missing chunk" end
    if rebuilt ~= payload then return false, "reassembled payload differs" end
    -- single-chunk path
    local single = Chunk.Split("short", 7, 255)
    if #single ~= 1 or single[1].marker ~= "S" then
        return false, "single-chunk marker wrong"
    end
    return true
end

-- w.u16 SATURATES instead of wrapping. Driven through the real encoder so the
-- test also proves the change is confined to the writer: every in-range value
-- still encodes to the same two bytes it always did, so the wire format (and
-- SCHEMA_VERSION) is untouched.
local function testU16Clamp()
    local function roundTripCD(v)
        local rec = ns.Store.NewCharacterRecord("Clamp-Realm")
        rec.itemCooldown  = v
        rec.hearthstoneCD = v
        local decoded = Protocol.DecodeCharacter(Protocol.EncodeCharacter(rec))
        if not decoded then return nil end
        return decoded.itemCooldown, decoded.hearthstoneCD
    end

    -- Over the ceiling: saturate at 65535. The old `% 65536` wrapped 65536 to 0
    -- ("no cooldown") and 70000 to 4464 ("74 minutes") — both plausible lies.
    local a, b = roundTripCD(65536)
    if a ~= 65535 or b ~= 65535 then
        return false, "65536 should clamp to 65535, got " .. tostring(a)
    end
    a = roundTripCD(70000)
    if a ~= 65535 then return false, "70000 should clamp to 65535, got " .. tostring(a) end

    -- Under the floor: saturate at 0 (the old code wrapped -1 to 65535).
    a = roundTripCD(-1)
    if a ~= 0 then return false, "-1 should clamp to 0, got " .. tostring(a) end

    -- In range: byte-identical to before, including both boundaries.
    for _, v in ipairs({ 0, 1, 420, 3600, 65534, 65535 }) do
        a = roundTripCD(v)
        if a ~= v then
            return false, "in-range " .. v .. " must round-trip unchanged, got " .. tostring(a)
        end
    end

    -- Fractional and nil inputs still floor / default rather than erroring.
    a = roundTripCD(1800.9)
    if a ~= 1800 then return false, "fractional should floor, got " .. tostring(a) end
    local rec = ns.Store.NewCharacterRecord("Clamp-Realm")
    rec.itemCooldown = nil
    local dec = Protocol.DecodeCharacter(Protocol.EncodeCharacter(rec))
    if not dec or dec.itemCooldown ~= 0 then return false, "nil should encode as 0" end

    -- The aura-duration u16 clamps on the same writer.
    rec = ns.Store.NewCharacterRecord("Clamp-Realm")
    rec.auraStates = { [2] = { duration = 99999, option = 1, source = 0 } }
    dec = Protocol.DecodeCharacter(Protocol.EncodeCharacter(rec))
    if not dec or not dec.auraStates[2] or dec.auraStates[2].duration ~= 65535 then
        return false, "aura duration should clamp to 65535"
    end
    return true
end

-- Decoder tolerance (NW-7 / release gate D-14, extended by schema-v3 wave 1
-- "release A" and now driven by the v3 ENCODER of wave 2 "release B"): OLDER
-- schemas decode with their absent tails reading as "not sent", the current one
-- decodes whole, and anything beyond the window is refused cleanly. Every
-- fixture is built by TRUNCATING and RESTAMPING real encoder output, so it is
-- exactly what a peer would put on the wire rather than a hand-rolled guess.
local V2_TAIL_BYTES = 12   -- xp + xpMax + restedXP, three u32s appended for v2
local V3_TAIL_BYTES = 4    -- dmfCooldownRemaining, one u32 appended for v3

-- The record every version fixture below is cut from. Carries a live value in
-- BOTH appended tails, so "the tail is absent" and "the tail is zero" can never
-- be confused with "the record had nothing to say".
local function toleranceFixture()
    local rec = ns.Store.NewCharacterRecord("Older-Whitemane")
    rec.classTag, rec.className, rec.faction = "MAGE", "Mage", "Alliance"
    rec.level, rec.boonCount, rec.shardCount = 60, 3, 0
    rec.location = "Ironforge"
    rec.lastSeen, rec.lastDataUpdate, rec.ownerEpoch = 1785000500, 1785000500, 1785000500
    rec.raidLockouts = { MC = 1785200000 }
    rec.auraStates = { [1] = { duration = 3600, option = 1, source = 0 } }
    rec.xp, rec.xpMax, rec.restedXP = 734512, 1526400, 381600
    rec.dmfCooldownActive = true
    rec.dmfCooldownRemaining = 9000        -- 2h 30m of the 4h still owed
    return rec
end

-- Cut a genuine older-schema payload out of a v3 frame: drop the tails the older
-- encoder never wrote, and restamp the version byte. This is only legitimate
-- BECAUSE of the append-at-tail contract (testGoldenV2Prefix pins it against real
-- bytes) — if a bump ever inserted a field mid-record, these fixtures would stop
-- being what an old peer emits and the whole tolerance suite would lie.
local function truncateTo(v3bytes, version)
    if version == 2 then
        return "\2" .. v3bytes:sub(2, #v3bytes - V3_TAIL_BYTES)
    end
    return "\1" .. v3bytes:sub(2, #v3bytes - V3_TAIL_BYTES - V2_TAIL_BYTES)
end

local function testSchemaTolerance()
    local rec = toleranceFixture()

    local v3bytes = Protocol.EncodeCharacter(rec)
    if not v3bytes then return false, "encoder produced nothing" end

    -- THE ENCODER IS AT v3 NOW (release B). Our own frames go out stamped 3, and
    -- the window is pinned one wide: VERSION == TOLERATED, so we never emit a
    -- version we would not accept from a peer.
    if Protocol.SCHEMA_VERSION ~= 3 then
        return false, "release B must ENCODE v3 (SCHEMA_VERSION is "
            .. tostring(Protocol.SCHEMA_VERSION) .. ")"
    end
    if v3bytes:byte(1) ~= 3 then
        return false, "our encoder must stamp version 3, got " .. tostring(v3bytes:byte(1))
    end
    if Protocol.SCHEMA_TOLERATED ~= Protocol.SCHEMA_VERSION then
        return false, "the window must stay pinned one version wide: TOLERATED "
            .. tostring(Protocol.SCHEMA_TOLERATED) .. " vs VERSION "
            .. tostring(Protocol.SCHEMA_VERSION)
    end
    if Protocol.SCHEMA_TOLERATED ~= 3 then
        return false, "the tolerance must accept v3 and stop there, got "
            .. tostring(Protocol.SCHEMA_TOLERATED)
    end

    -- A genuine v1 payload: version byte 1, and NEITHER appended tail present.
    local v1bytes = truncateTo(v3bytes, 1)
    if #v1bytes ~= #v3bytes - V3_TAIL_BYTES - V2_TAIL_BYTES then
        return false, "v1 fixture is the wrong length"
    end
    local old, oerr = Protocol.DecodeCharacter(v1bytes)
    if not old then return false, "a v1 payload must decode, got: " .. tostring(oerr) end
    if old.nameRealm ~= rec.nameRealm or old.level ~= rec.level
        or old.classTag ~= rec.classTag or old.faction ~= rec.faction
        or old.location ~= rec.location then
        return false, "v1 payload lost a v1-era field"
    end
    if old.raidLockouts.MC ~= 1785200000 then return false, "v1 payload lost its raid lockout" end
    if not old.auraStates[1] or old.auraStates[1].duration ~= 3600 then
        return false, "v1 payload lost its aura slot"
    end
    -- The absent v2 tail reads as "not sent", which is what it means.
    if old.xp ~= 0 or old.xpMax ~= 0 or old.restedXP ~= 0 then
        return false, "absent v2 tail should read as 0, got " .. tostring(old.xp)
    end
    -- ...and so does the absent v3 tail, by the SAME read-past-end contract.
    if old.dmfCooldownRemaining ~= 0 then
        return false, "absent v3 tail should read as 0 on a v1 frame, got "
            .. tostring(old.dmfCooldownRemaining)
    end
    -- The FLAG still crosses on a v1/v2 frame — only the countdown is missing.
    if old.dmfCooldownActive ~= true then
        return false, "the v1 frame lost the dmf cooldown FLAG (it is a v1-era bit)"
    end

    -- v2: the whole record MINUS the v3 tail. Every v2-era field survives and the
    -- appended countdown reads absent-as-0, i.e. "this sender never told us".
    local v2bytes = truncateTo(v3bytes, 2)
    local cur = Protocol.DecodeCharacter(v2bytes)
    if not cur then return false, "a v2 payload must still decode" end
    if cur.xp ~= rec.xp or cur.xpMax ~= rec.xpMax or cur.restedXP ~= rec.restedXP then
        return false, "v2 payload lost a v2-era field"
    end
    if cur.dmfCooldownRemaining ~= 0 then
        return false, "absent v3 tail should read as 0 on a v2 frame, got "
            .. tostring(cur.dmfCooldownRemaining)
    end
    if cur.dmfCooldownActive ~= true then
        return false, "the v2 frame lost the dmf cooldown FLAG"
    end

    -- v3: the record we encoded, whole, countdown included.
    local now3, nerr = Protocol.DecodeCharacter(v3bytes)
    if not now3 then return false, "our own v3 payload must decode: " .. tostring(nerr) end
    local same, why = recordsMatch(rec, now3)
    if not same then return false, "v3 round-trip differs: " .. tostring(why) end
    if now3.dmfCooldownRemaining ~= 9000 then
        return false, "the v3 countdown did not survive the wire, got "
            .. tostring(now3.dmfCooldownRemaining)
    end

    -- A TRUNCATED v3 frame (the tail lost in transit) is the read-past-end
    -- contract's own case: it must read 0 rather than error or half-decode.
    local chopped = v3bytes:sub(1, #v3bytes - V3_TAIL_BYTES)
    local cut, cerr = Protocol.DecodeCharacter(chopped)
    if not cut then return false, "a v3 frame missing its tail must decode: " .. tostring(cerr) end
    if cut.dmfCooldownRemaining ~= 0 then
        return false, "a truncated v3 tail must read as 0, got " .. tostring(cut.dmfCooldownRemaining)
    end

    -- ...but the window is exactly ONE version wide. v4 is refused cleanly —
    -- nil plus a reason, never a partial record and never an error. Nothing
    -- constrains a schema two bumps out, so decoding it would be guessing.
    local v4bytes = "\4" .. v3bytes:sub(2)
    local future, ferr = Protocol.DecodeCharacter(v4bytes)
    if future ~= nil then return false, "a v4 payload must be rejected, not decoded" end
    if type(ferr) ~= "string" or not ferr:find("unsupported schema version 4", 1, true) then
        return false, "v4 rejection must say why, got: " .. tostring(ferr)
    end

    -- Version 0 is not a schema: it is what an empty or truncated buffer reads
    -- as, and it must stay rejected rather than decode a record of zeroes.
    if Protocol.DecodeCharacter("") ~= nil then return false, "an empty buffer must be rejected" end
    if Protocol.DecodeCharacter("\0" .. v3bytes:sub(2)) ~= nil then
        return false, "version 0 must be rejected"
    end
    return true
end

-- ────────────────────────────────────────────────────────────────────────────
-- GOLDEN BYTES: the v2 prefix of a v3 frame is FROZEN.
--
-- The append-at-tail contract is what lets an older reader decode a newer frame
-- and stop early, and it is the sole justification for the truncate-and-restamp
-- fixtures above. Asserting it against the encoder's own current output would be
-- circular, so it is pinned against REAL BYTES captured from the v2 encoder
-- before the bump: encode the fixture today, and every byte up to the appended
-- u32 must still be what the v2 build wrote, with only the version byte moved
-- from 2 to 3.
--
-- WHAT THIS CATCHES that nothing else does: a future edit that reorders a field,
-- widens a u16 to a u32, inserts a value mid-record, or changes a string's
-- length prefix. All of those still round-trip perfectly through our own
-- encoder/decoder pair — and all of them silently corrupt every peer on an
-- older build. This test is the only thing standing between that edit and the
-- wire, so a failure here is a WIRE BREAK, never "the golden needs updating":
-- regenerating the constant to make it pass would be deleting the guarantee.
-- The ONLY legitimate reason to touch GOLDEN_V2 is a deliberate, documented
-- schema break, and that is a bump-history entry plus a rollout plan, not a
-- test edit.
-- ────────────────────────────────────────────────────────────────────────────

-- Captured 2026-08-07 from the SHIPPED v2 encoder (1.1.4, SCHEMA_VERSION = 2)
-- for goldenFixture() below. 118 bytes, version byte included.
local GOLDEN_V2 =
        "\2\126\8\2\60\7\24\7\8\1\164\106\100\241\108\106" ..
        "\100\240\187\106\100\201\48\106\100\242\52\106\100\242\52\106" ..
        "\100\242\52\76\106\105\132\32\106\103\253\128\106\102\118\224" ..
        "\3\1\14\16\1\0\3\28\32\2\1\10\0\120\0\2" ..
        "\16\71\111\108\100\101\110\45\87\104\105\116\101\109\97\110" ..
        "\101\7\87\97\114\108\111\99\107\16\82\101\110\100\32\83" ..
        "\116\97\103\105\110\103\32\40\83\41\0\11\53\48\0\23" ..
        "\74\128\0\5\210\160"

-- The record GOLDEN_V2 was captured from. Every field is pinned literally: it
-- must NOT drift with defaults, so nothing here is left to NewCharacterRecord
-- except the shape itself.
local function goldenFixture()
    local rec = ns.Store.NewCharacterRecord("Golden-Whitemane")
    rec.classTag, rec.className, rec.faction = "WARLOCK", "Warlock", "Horde"
    rec.level, rec.boonCount, rec.shardCount = 60, 7, 24
    rec.location = "Rend Staging (S)"
    rec.inInstance, rec.isResting, rec.pvpFlagged = false, true, true
    rec.pvpExpiry = 1785000300
    rec.chronoboonActive, rec.chronoboonLastSeen = true, 1785000123
    rec.itemCooldown, rec.hearthstoneCD = 1800, 420
    rec.dmfInBoon, rec.dmfCooldownActive, rec.soulstoneReady = true, true, true
    rec.dmfCooldown = { offlineSince = 1784990000 }
    rec.raidLockouts = { MC = 1785200000, BWL = 1785300000, Ony = 1785100000 }
    rec.auraStates = {
        [1]  = { duration = 3600, option = 1, source = 0 },
        [3]  = { duration = 7200, option = 2, source = 1 },
        [10] = { duration = 120,  option = 0, source = 2 },
    }
    rec.lastSeen, rec.lastDataUpdate, rec.ownerEpoch = 1785000500, 1785000500, 1785000500
    rec.xp, rec.xpMax, rec.restedXP = 734512, 1526400, 381600
    return rec
end

local function testGoldenV2Prefix()
    local rec = goldenFixture()
    rec.dmfCooldownRemaining = 12345          -- the v3 tail, deliberately non-zero
    local bytes = Protocol.EncodeCharacter(rec)
    if not bytes then return false, "encoder produced nothing" end

    -- 1. LENGTH. A v3 frame is the v2 frame plus exactly one appended u32.
    if #bytes ~= #GOLDEN_V2 + V3_TAIL_BYTES then
        return false, ("v3 frame must be exactly %d bytes longer than the v2 golden: got %d, expected %d")
            :format(V3_TAIL_BYTES, #bytes, #GOLDEN_V2 + V3_TAIL_BYTES)
    end

    -- 2. THE PREFIX, BYTE FOR BYTE. Only the version byte may differ, and only
    --    from 2 to 3 — every other byte of the v2 layout is frozen.
    if bytes:byte(1) ~= 3 then
        return false, "the version byte must be 3, got " .. tostring(bytes:byte(1))
    end
    local prefix = bytes:sub(2, #GOLDEN_V2)
    local golden = GOLDEN_V2:sub(2)
    if prefix ~= golden then
        -- Name the first offending offset: "it differs" is useless at 118 bytes.
        local at = 0
        for i = 1, math.min(#prefix, #golden) do
            if prefix:byte(i) ~= golden:byte(i) then at = i + 1 break end
        end
        return false, ("THE v2 PREFIX MOVED — this is a wire break, not a stale golden. "
            .. "First difference at byte %d: got %s, golden %s")
            :format(at, tostring(prefix:byte(at - 1)), tostring(golden:byte(at - 1)))
    end

    -- 3. THE TAIL is the appended u32, big-endian, and nothing else.
    local tail = bytes:sub(#GOLDEN_V2 + 1)
    local v = tail:byte(1) * 16777216 + tail:byte(2) * 65536 + tail:byte(3) * 256 + tail:byte(4)
    if v ~= 12345 then
        return false, "the appended v3 tail is not the countdown, decoded " .. tostring(v)
    end

    -- 4. And an OLD reader's view of our new frame is the golden record: cut the
    --    tail, restamp to 2, and it is the v2 frame byte for byte.
    if ("\2" .. bytes:sub(2, #GOLDEN_V2)) ~= GOLDEN_V2 then
        return false, "a v2 peer's view of our v3 frame is not the frozen v2 frame"
    end
    return true
end

-- ────────────────────────────────────────────────────────────────────────────
-- THE MIXED-VERSION MATRIX, asserted end to end.
--
-- Three cells, and the third one is a COST the owner accepted rather than a
-- behaviour we want:
--
--   v3 reader x v2 frame  -> decodes; countdown absent-as-0 -> flag-only card.
--   v3 reader x v3 frame  -> decodes; countdown present     -> countdown card.
--   v2 reader x v3 frame  -> REFUSED. A build whose SCHEMA_TOLERATED is 2 (i.e.
--                            Nexus 1.1.3 and earlier — 1.1.4 already tolerates
--                            v3 via wave 1) drops our STATE frames entirely and
--                            goes one-way blind to us until it updates.
--
-- That third row is the price of collapsing the two-release rollout into one
-- deployment (owner decision 2026-08-07, "so we don't have multiple
-- deployments"; NEXUS_SCHEMA_V3_DESIGN.md "Package as executed"). It is asserted
-- HERE, through a fixture decoder running the real DecodeCharacter with the
-- tolerance dialled back to 2, so the cost is documented in code that fails if
-- anyone quietly changes what it means — not left as a paragraph in a design doc.
-- ────────────────────────────────────────────────────────────────────────────
local function testMixedVersionMatrix()
    local rec = toleranceFixture()
    local v3bytes = Protocol.EncodeCharacter(rec)
    local v2bytes = truncateTo(v3bytes, 2)

    -- ROW 1 — v3 reader, v2 frame. The record lands; the countdown does not, and
    -- 0 is precisely the "render the flag alone" state the card already has.
    local fromOld = Protocol.DecodeCharacter(v2bytes)
    if not fromOld then return false, "row 1: a v2 peer's frame must still decode" end
    if fromOld.dmfCooldownActive ~= true then
        return false, "row 1: the v2 frame's dmf FLAG must still cross"
    end
    if fromOld.dmfCooldownRemaining ~= 0 then
        return false, "row 1: a v2 frame must yield no countdown, got "
            .. tostring(fromOld.dmfCooldownRemaining)
    end

    -- ROW 2 — v3 reader, v3 frame. Flag AND countdown.
    local fromNew = Protocol.DecodeCharacter(v3bytes)
    if not fromNew then return false, "row 2: our own v3 frame must decode" end
    if fromNew.dmfCooldownActive ~= true or fromNew.dmfCooldownRemaining ~= 9000 then
        return false, "row 2: a v3 frame must carry flag AND countdown, got "
            .. tostring(fromNew.dmfCooldownRemaining)
    end

    -- ROW 3 — THE ACCEPTED COST. A pre-wave-1 reader (SCHEMA_TOLERATED = 2) run
    -- against our v3 frame. Same real decoder, one constant dialled back, and
    -- restored in every exit path below so a failure cannot leak the fixture
    -- setting into the rest of the suite.
    local realTolerance = Protocol.SCHEMA_TOLERATED
    Protocol.SCHEMA_TOLERATED = 2
    local refused, rerr = Protocol.DecodeCharacter(v3bytes)
    local stillOK      = Protocol.DecodeCharacter(v2bytes)
    Protocol.SCHEMA_TOLERATED = realTolerance

    if refused ~= nil then
        return false, "row 3: a v2-era reader must REFUSE a v3 frame outright "
            .. "(if this now passes, the accepted cost changed and the CHANGELOG is wrong)"
    end
    if type(rerr) ~= "string" or not rerr:find("unsupported schema version 3", 1, true) then
        return false, "row 3: the refusal must say why, got: " .. tostring(rerr)
    end
    -- ...and the blindness is ONE-WAY: that same old reader still reads an old
    -- frame perfectly, so the mesh degrades on one edge rather than partitioning.
    if not stillOK then
        return false, "row 3: a v2-era reader must still read v2 frames"
    end
    if Protocol.SCHEMA_TOLERATED ~= realTolerance then
        return false, "row 3: the fixture leaked its tolerance override"
    end
    return true
end

-- Run every self-test. Returns overall bool; prints per-test lines when
-- verbose (the /dsn debug selftest path). Also returns to callers so a
-- future CI harness could consume the result table.
function Protocol.RunSelfTests(verbose)
    local suite = {
        { name = "token bucket",     fn = testTokenBucket },
        { name = "priority queue",   fn = testPriorityQueue },
        { name = "chunking",         fn = testChunking },
        { name = "state round-trip", fn = testRoundTrip },
        { name = "u16 clamp",        fn = testU16Clamp },
        { name = "schema tolerance (NW-7 + v3 release B)", fn = testSchemaTolerance },
        { name = "golden v2 prefix (append-at-tail)",      fn = testGoldenV2Prefix },
        { name = "mixed-version matrix (J4)",              fn = testMixedVersionMatrix },
    }
    local allPass, results = true, {}
    for _, t in ipairs(suite) do
        local ok, why, extra = t.fn()
        results[t.name] = { ok = ok, why = why, extra = extra }
        if not ok then allPass = false end
        if verbose and ns and ns.Print then
            if ok then
                local tail = ""
                if t.name == "state round-trip" and extra then
                    tail = " (" .. extra .. " bytes)"
                end
                ns:Print("  PASS " .. t.name .. tail)
            else
                ns:Print("  FAIL " .. t.name .. " :: " .. tostring(why))
            end
        end
    end
    if verbose and ns and ns.Print then
        ns:Print(allPass and "selftest: ALL PASS" or "selftest: FAILURES ABOVE")
    end
    return allPass, results
end
