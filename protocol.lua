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

Protocol.SCHEMA_VERSION = 1     -- our binary state-schema version

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
    function w.u16(v)
        v = math.floor(v or 0) % 65536
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

    return w.result()
end

function Protocol.DecodeCharacter(bytes)
    local r = newReader(bytes)
    local version = r.u8()
    if version ~= Protocol.SCHEMA_VERSION then
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
    rec.level = 60
    rec.location = "Rend Staging (S)"
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
    return ok, why, #bytes
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

-- Run every self-test. Returns overall bool; prints per-test lines when
-- verbose (the /dsn debug selftest path). Also returns to callers so a
-- future CI harness could consume the result table.
function Protocol.RunSelfTests(verbose)
    local suite = {
        { name = "token bucket",     fn = testTokenBucket },
        { name = "priority queue",   fn = testPriorityQueue },
        { name = "chunking",         fn = testChunking },
        { name = "state round-trip", fn = testRoundTrip },
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
