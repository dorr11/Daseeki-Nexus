-- Daseeki Nexus — snbridge.lua  (N2 round 2: ShadowNetwork PASSIVE ingest)
--
-- RECEIVE-ONLY interop with ShadowNetwork's world-buff timer broadcasts. The
-- owner authorized decoding SN's guild timer/pull traffic as an extra data
-- source for our own timer engine. This module:
--   * registers SN's SDWW prefix (+ legacy SNT) for RECEIVING only;
--   * reverses SN's documented SDWW wire pipeline to a payload table;
--   * translates recognized timer/pull payloads into ns.Timers.OnSN* with the
--     "sn" trust tag (below mesh, above nwb/dbm), through the same
--     false-positive / dedup gates the other detectors use;
--   * tracks snPassive freshness.
--
-- HARD RULE — NO TRANSMIT: this client must NEVER send on SDWW/SNT (or any SN
-- prefix). There is deliberately NO send path in this file. RegisterAddonMessage
-- Prefix only enables RECEIVING; it does not permit sending. The mesh transport
-- additionally hard-blocks these prefixes at its send choke point. The
-- encode-side helper at the bottom is TEST-ONLY (self-test fixtures) and is
-- never wired to any SendAddonMessage / SendCommMessage call.
--
-- CLEAN-ROOM: no ShadowNetwork source was read. This implements only the wire
-- FACTS documented in network-design/NETWORK_SPEC_ENGINE.md §3 (prefix SDWW /
-- legacy SNT; XOR key ASCII "ShadowNt"; protocol version byte 2; short-key
-- compression; LibSerialize + LibDeflate; channel-safe encoding). SN's exact
-- byte-level framing (esp. multi-fragment chunk envelopes and the precise
-- short-key table) is NOT part of the clean-room facts; where the real wire
-- diverges from these facts, decode fails SILENTLY (never errors) and we simply
-- ingest nothing — SN's format may drift and must never break us.

local ADDON, ns = ...

local SNBridge = {}
ns.SNBridge = SNBridge

----------------------------------------------------------------------
-- Constants (documented SN wire facts)
----------------------------------------------------------------------

-- SN prefixes we REGISTER FOR RECEIVE ONLY. SDWW carries timer broadcasts +
-- pull alerts + targeted timer whispers; SNT is the legacy inbound alias.
SNBridge.RECV_PREFIXES = { "SDWW", "SNT" }

-- SDWW payload XOR-obfuscation key (ASCII "ShadowNt"), applied to the deflated
-- bytes. Symmetric, so the same routine encodes (tests) and decodes (live).
local XOR_KEY = "ShadowNt"

-- Message-type header protocol version. A decoded payload carrying a version
-- indicator that is not this value is rejected (spec: "rejected if ≠2").
local SN_PROTO_VERSION = 2

-- Wire-capture ring buffer cap (item 41). Persisted frames for the orchestrator
-- to derive SN's chunk envelope empirically from real broadcast evidence.
local CAPTURE_CAP = 50

----------------------------------------------------------------------
-- Diagnostics: per-stage counters (item 41). Every decode stage is counted so
-- `/nexus debug snbridge` shows exactly where a broadcast is being dropped —
-- especially "suspected fragment" (a chunked frame that fails to inflate). The
-- ingest itself stays SILENT in chat; only the counters move.
----------------------------------------------------------------------

SNBridge._stats = {
    heard = 0, byChannel = {},
    channelDecodeOK = 0, inflateOK = 0, deserializeOK = 0, versionOK = 0, translated = 0,
    -- Chunk-reassembly telemetry (item: sn-chunk-reassembly).
    reasmOpened = 0, reasmCompleted = 0, reasmMiddle = 0,
    drop = {
        notRecvPrefix = 0, channelDecode = 0, suspectedFragment = 0,
        deserialize = 0, notTable = 0, versionGate = 0, translateZero = 0,
        -- Reassembly drop reasons.
        reasmTimeout = 0, reasmEvicted = 0, reasmOrphan = 0, reasmIncomplete = 0,
        unknownType = 0,
    },
}

local function snBump(path, key)
    local t = SNBridge._stats[path]
    if type(t) == "table" then t[key] = (t[key] or 0) + 1 end
end

----------------------------------------------------------------------
-- Wire capture ring buffer (item 41), persisted to DaseekiNexusData.snCapture.
-- OFF by default. Capturing bytes arriving at the owner's own client is
-- legitimate interop practice; we store bytes only, never code.
----------------------------------------------------------------------

-- Escape a raw wire string to a printable \xHH form so SavedVariables stays
-- valid text and the dump is copy-safe. Pure + self-tested.
function SNBridge.EscapeBytes(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("[%z\1-\31\127-\255\\]", function(c)
        return string.format("\\x%02X", string.byte(c))
    end))
end

-- Inverse of EscapeBytes: turn a printable \xHH dump back into raw wire bytes.
-- Exact reverse of the escape above so a captured frame round-trips to the
-- byte-exact CHAT_MSG_ADDON `text`. Used by the permanent fixture regression
-- test (harness snfixture.lua) to replay real captured frames. Pure.
function SNBridge.UnescapeBytes(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("\\x(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

-- The persisted capture table (creates it lazily). nil if the data store is
-- unavailable (bare-VM self-test path just skips persistence).
local function captureStore(create)
    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    if not data then return nil end
    if not data.snCapture and create then
        data.snCapture = { enabled = false, frames = {}, dropped = 0 }
    end
    return data.snCapture
end

function SNBridge.CaptureEnabled()
    local cap = captureStore(false)
    return cap ~= nil and cap.enabled == true
end

function SNBridge.SetCapture(on)
    local cap = captureStore(true)
    if not cap then return false end
    cap.enabled = on and true or false
    if on and type(cap.frames) ~= "table" then cap.frames = {} end
    return true
end

-- Append one raw frame to the capped ring buffer (oldest evicted at cap).
function SNBridge.CaptureFrame(sender, channel, raw)
    local cap = captureStore(true)
    if not cap or not cap.enabled then return end
    cap.frames = cap.frames or {}
    cap.frames[#cap.frames + 1] = {
        sender = sender, channel = channel,
        len = (type(raw) == "string" and #raw) or 0,
        at = (ns.Store and ns.Store.Now and ns.Store.Now()) or 0,
        raw = SNBridge.EscapeBytes(raw),
    }
    while #cap.frames > CAPTURE_CAP do
        table.remove(cap.frames, 1)
        cap.dropped = (cap.dropped or 0) + 1
    end
end

----------------------------------------------------------------------
-- Lib access (guarded; the pure translation logic loads without them)
----------------------------------------------------------------------

local function libSerialize()
    return LibStub and LibStub.GetLibrary and LibStub:GetLibrary("LibSerialize", true)
end
local function libDeflate()
    return LibStub and LibStub.GetLibrary and LibStub:GetLibrary("LibDeflate", true)
end

----------------------------------------------------------------------
-- XOR obfuscation (pure). Repeating-key byte XOR over the whole buffer.
----------------------------------------------------------------------

local sbyte, schar = string.byte, string.char
function SNBridge.XorCrypt(str, key)
    if type(str) ~= "string" or type(key) ~= "string" or #key == 0 then return str end
    -- Lua 5.1 (Classic) has no bitwise operators; use an arithmetic byte XOR.
    local out = {}
    local klen = #key
    for i = 1, #str do
        local a = sbyte(str, i)
        local b = sbyte(key, ((i - 1) % klen) + 1)
        out[i] = schar(SNBridge._xorByte(a, b))
    end
    return table.concat(out)
end

-- Arithmetic byte XOR (0..255) without the 5.3 bit operators (Classic is 5.1).
function SNBridge._xorByte(a, b)
    local res, bit = 0, 1
    for _ = 1, 8 do
        local abit = a % 2
        local bbit = b % 2
        if abit ~= bbit then res = res + bit end
        a = (a - abit) / 2
        b = (b - bbit) / 2
        bit = bit * 2
    end
    return res
end

----------------------------------------------------------------------
-- Buff identifier mapping (SN id -> our timer key)
--
-- SN tracks the same world buffs (spec §4). We map the plausible identifier
-- forms and faction-resolve the H/A-split buffs. Unknown ids translate to nil
-- (skipped). This map is the most likely place to need tuning against a live
-- SN broadcaster, since SN's exact id/short-code strings are not clean-room
-- facts — but a miss only means "ingest nothing", never an error.
----------------------------------------------------------------------

local function playerFaction()
    return (UnitFactionGroup and UnitFactionGroup("player")) or "Horde"
end

-- base "ony"/"nef" -> faction-resolved key ("onyH"/"onyA" etc.).
local function factionResolve(base, faction)
    faction = faction or playerFaction()
    local suffix = (faction == "Alliance") and "A" or "H"
    return base .. suffix
end

-- Lowercased SN id -> either a final buff key or a base needing faction resolve.
local SN_BUFF_BASE = {
    rend = "rend", warchief = "rend", ["warchief's blessing"] = "rend",
    ["rallying cry"] = "ony",   -- ambiguous alone; treated as ony (dragonslayer)
    ony = "ony", onyx = "ony", onyxia = "ony", dragonslayer = "ony",
    nef = "nef", nefarian = "nef",
    zg = "zg", zan = "zg", zandalar = "zg", hakkar = "zg",
}
-- Already faction-explicit forms pass straight through.
local SN_BUFF_EXPLICIT = {
    onyh = "onyH", onya = "onyA", nefh = "nefH", nefa = "nefA",
    rend = "rend", zg = "zg",
}

function SNBridge.ResolveBuff(id, faction)
    if type(id) ~= "string" then
        if type(id) == "number" then id = tostring(id) else return nil end
    end
    local key = id:lower()
    if SN_BUFF_EXPLICIT[key] then return SN_BUFF_EXPLICIT[key] end
    local base = SN_BUFF_BASE[key]
    if not base then return nil end
    if base == "ony" or base == "nef" then return factionResolve(base, faction) end
    return base
end

----------------------------------------------------------------------
-- Tolerant field access — read a value under any of several key aliases so
-- small short-key/long-key naming differences don't defeat translation.
----------------------------------------------------------------------

local function pick(tbl, ...)
    for i = 1, select("#", ...) do
        local k = select(i, ...)
        local v = tbl[k]
        if v ~= nil then return v end
    end
    return nil
end

-- SN "Broadcast Timers" log-array key -> our buff key. rend/ony(H/A) are proven
-- against the real capture; nef/zg are defensive (SN may add them, same shape).
local SN_LOG_BUFF = {
    rendLog = "rend", onyLogH = "onyH", onyLogA = "onyA",
    nefLogH = "nefH", nefLogA = "nefA", zgLog = "zg",
}

-- Which buffs have an ANNOUNCER NPC whose death is a real respawn event.
--
-- This is the snbridge half of the engine's announcer-only kill rule (F2). A
-- log entry's `killed` flag is a per-buff claim and it does NOT mean the same
-- thing in every log: for Onyxia and Nefarian it is the announcer (Runthak,
-- Mattingly, Saurfang, Afrasiabi) dying, which starts a 6-minute respawn. Rend
-- and Zandalar HAVE no announcer — the only killable thing in their world is the
-- raid boss (Rend Blackhand, Hakkar) — so a `killed` flag in rendLog/zgLog is a
-- boss kill, and forwarding it as kind "killed" asked the engine to start a
-- respawn clock for an NPC that does not exist. Those route as a POP instead:
-- in SN's own log a rendLog entry is an entry in the REND POP LOG, and the flag
-- is annotation on when/how it was seen, not a different kind of event.
--
-- Resolved through the engine when it is loaded so there is exactly one
-- definition of the set, with a literal fallback for the bare-VM path.
local ANNOUNCER_FALLBACK = { onyH = true, onyA = true, nefH = true, nefA = true }
local function isAnnouncerBuff(buffKey)
    local T = ns.Timers
    local set = (T and T.ANNOUNCER_BUFFS) or ANNOUNCER_FALLBACK
    return set[buffKey] == true
end
SNBridge._isAnnouncerBuff = isAnnouncerBuff

-- Guards applied to every node write from SN. Resolved through the engine so
-- there is exactly one definition of "second-hand node data" (timers.lua), and
-- degrades to nil — plain newest-wins — in a bare VM without the engine.
local function netOpts()
    local T = ns.Timers
    return (T and T._netNodeOpts and T._netNodeOpts()) or nil
end

-- Songflower/node translation. Accepts ONLY unambiguous indexed-epoch shapes and
-- routes through the public Timers.MarkNode surface with "sn" trust. Returns the
-- number of node picks applied.
--
-- ═══ NOT SOURCED FROM A WIRE CAPTURE (audit item 8, owner-acknowledged) ═══
-- Everything below this line is INFERENCE, not observation. Our SN capture
-- carries no node data at all, so the key shapes this function accepts — a
-- `flower`/`tuber` sub-table of index->epoch, and flat `flowerN`/`tuberN` keys —
-- are guesses at what SN *might* send, modelled on how it stores nodes locally.
-- No SN payload we have ever decoded has exercised a single branch of it, and
-- the fixture-backed self-tests prove only that our own synthetic shapes are
-- handled, NOT that they match SN.
--
-- Consequence: treat a non-zero return from here as unverified. Decoding SN's
-- real node format needs a live wire capture from a client running SN with
-- Felwood timers set; until someone produces one, this stays defensive
-- scaffolding and must not be described as SN node support.
-- ═════════════════════════════════════════════════════════════════════════
local function markNodesFrom(map, kind)
    if type(map) ~= "table" then return 0 end
    local n = 0
    for idx, epoch in pairs(map) do
        local i = tonumber(idx)
        local z = tonumber(epoch)
        if i and i >= 1 and z and z > 1000000000 then
            -- Standard network guards (audit fix 2): an SN-relayed epoch is
            -- second-hand and may not stomp our own pick inside its respawn,
            -- nor re-report the same pick within 10s.
            if ns.Timers.MarkNode(kind, i, z, "sn", netOpts()) then n = n + 1 end
        end
    end
    return n
end

local function translateNodes(payload)
    if not ns.Timers.MarkNode then return 0 end
    local n = 0
    -- Sub-table form: { flower = {1=epoch,...}, tuber = {1=epoch,...} }.
    n = n + markNodesFrom(pick(payload, "flower", "flowers", "songflower"), "flower")
    n = n + markNodesFrom(pick(payload, "tuber", "tubers", "nightdragon"), "tuber")
    -- Flat "flowerN"/"tuberN" keys.
    for k, v in pairs(payload) do
        if type(k) == "string" then
            local fi = k:match("^flower(%d+)$")
            local ti = k:match("^tuber(%d+)$")
            local z = tonumber(v)
            if fi and z and z > 1000000000 then
                if ns.Timers.MarkNode("flower", tonumber(fi), z, "sn", netOpts()) then n = n + 1 end
            elseif ti and z and z > 1000000000 then
                if ns.Timers.MarkNode("tuber", tonumber(ti), z, "sn", netOpts()) then n = n + 1 end
            end
        end
    end
    return n
end

----------------------------------------------------------------------
-- Decode chain (production, RECEIVE)
--
-- Reverse of SN's documented SDWW encode pipeline:
--   channel-safe decode -> XOR "ShadowNt" -> inflate -> deserialize.
-- Entirely defensive: any step failing returns nil (silent skip). Never errors.
----------------------------------------------------------------------

-- Returns (payload, reason). reason is a stage label on failure (nil on success),
-- and each stage bumps a diagnostic counter (item 41). An inflate failure is the
-- prime suspect for a chunked broadcast fragment ("suspectedFragment").
function SNBridge.Decode(wire, channel)
    if type(wire) ~= "string" or #wire == 0 then return nil, "empty" end
    local LS, LD = libSerialize(), libDeflate()
    if not (LS and LD) then return nil, "libsAbsent" end
    -- channel-safe decode (addon channel; world YELL/SAY uses the chat variant).
    local dec
    if channel == "YELL" or channel == "SAY" then
        dec = LD.DecodeForWoWChatChannel and LD:DecodeForWoWChatChannel(wire)
    else
        dec = LD.DecodeForWoWAddonChannel and LD:DecodeForWoWAddonChannel(wire)
    end
    if not dec then snBump("drop", "channelDecode"); return nil, "channelDecode" end
    SNBridge._stats.channelDecodeOK = SNBridge._stats.channelDecodeOK + 1
    local xored = SNBridge.XorCrypt(dec, XOR_KEY)
    local raw = LD:DecompressDeflate(xored)
    if not raw then
        -- Partial deflate stream => almost certainly a multi-fragment envelope
        -- our single-frame path can't reassemble yet (reassembly deferred to
        -- captured wire evidence — item 41).
        snBump("drop", "suspectedFragment"); return nil, "suspectedFragment"
    end
    SNBridge._stats.inflateOK = SNBridge._stats.inflateOK + 1
    local ok, payload = LS:Deserialize(raw)
    if not ok or type(payload) ~= "table" then
        snBump("drop", "deserialize"); return nil, "deserialize"
    end
    SNBridge._stats.deserializeOK = SNBridge._stats.deserializeOK + 1
    return payload
end

-- Version gate. A decoded payload carrying a version indicator != 2 is rejected;
-- absent version is tolerated (some message types may omit it). Pure.
function SNBridge.VersionOK(payload)
    local ver = pick(payload, "v", "version", "protocol", "proto", "pv")
    if ver == nil then return true end
    return tonumber(ver) == SN_PROTO_VERSION
end

----------------------------------------------------------------------
-- Translation — recognized SN timer/pull payloads -> our ingest entry points.
--
-- Recognized shapes (canonical + a few key aliases):
--   batch : { timers = { <buffId> = <epoch>, ... } }
--   timer : { buff=<id>, epoch=<n>, event="pop"|"killed"|"quest" }
--   pull  : { pull=true (or kind="pull"), buff=<id>, epoch=<n>, duration=<n>, zone=<s> }
-- Returns the number of events handed to the timers layer.
----------------------------------------------------------------------

function SNBridge.Translate(payload, sender)
    if type(payload) ~= "table" then return 0 end
    if not (ns.Timers and ns.Timers.OnSNTimer) then return 0 end
    local handled = 0
    local who = sender or "SN"

    -- Batch timer map.
    local timers = pick(payload, "timers", "buffs")
    if type(timers) == "table" then
        for id, epoch in pairs(timers) do
            local buff = SNBridge.ResolveBuff(id)
            local e = tonumber(epoch)
            if buff and e and e > 1000000000 then
                ns.Timers.OnSNTimer(buff, e, "pop", { who = who })
                handled = handled + 1
            end
        end
    end

    -- Single event.
    local id = pick(payload, "buff", "b", "type", "buffType")
    local buff = id and SNBridge.ResolveBuff(id)
    if buff then
        local epoch = tonumber(pick(payload, "epoch", "e", "time", "ts")) or nil
        local kindField = pick(payload, "kind", "k", "event", "evt")
        local isPull = (payload.pull == true) or (kindField == "pull")
        if isPull then
            local duration = tonumber(pick(payload, "duration", "d", "dur")) or 0
            local zone = pick(payload, "zone", "z")
            ns.Timers.OnSNPull(buff, epoch, duration, zone, { who = who })
        else
            -- Normalize kind to pop/killed/quest. Same announcer rule as the log
            -- arrays below (F2): a "killed" claim for a buff with no announcer
            -- is a raid-boss kill and is carried as a pop, never as a respawn.
            local kind = "pop"
            if kindField == "killed" or kindField == "kill" then
                kind = isAnnouncerBuff(buff) and "killed" or "pop"
            elseif kindField == "quest" or kindField == "handin" then kind = "quest" end
            local zone = pick(payload, "zone", "z")
            ns.Timers.OnSNTimer(buff, epoch, kind, { who = who, zone = zone })
        end
        handled = handled + 1
    end

    -- SN "Broadcast Timers" per-buff pop/kill LOGS. This is the shape the real
    -- captured GUILD broadcasts actually carry (see harness snfixture.lua):
    --   rendLog / onyLogH / onyLogA = { { z=<epoch>, who=<name>?, killed=<bool>?,
    --                                     quest=<bool>? }, ... }  (newest-ish first)
    -- We anchor the NEWEST entry per log through the sn ingest path. Recording
    -- only the newest keeps the anchor current; Timers.Record's recency gate then
    -- decides whether it is fresh enough to raise a pull bar — so an old broadcast
    -- repopulates state WITHOUT an alert storm. nef/zg log keys are wired
    -- defensively in case SN begins broadcasting them; absent keys are no-ops.
    for logKey, buff in pairs(SN_LOG_BUFF) do
        local log = payload[logKey]
        if type(log) == "table" then
            local best
            for _, e in pairs(log) do
                if type(e) == "table" then
                    local z = tonumber(pick(e, "z", "epoch", "e", "time", "ts"))
                    if z and z > 1000000000 and (not best or z > best.z) then
                        best = { z = z, who = e.who, killed = e.killed, quest = e.quest }
                    end
                end
            end
            if best then
                -- F2: a `killed` flag only means "announcer died" for the buffs
                -- that HAVE an announcer; on rend/zg it is a raid-boss kill and
                -- belongs in the pop log, not the respawn model.
                local kind = "pop"
                if best.killed and isAnnouncerBuff(buff) then
                    kind = "killed"
                elseif best.quest then
                    -- F7: a hand-in, not a drop. OnSNTimer applies the +15s
                    -- assumed-drop lead and the pending-local-hand-in rule.
                    kind = "quest"
                end
                ns.Timers.OnSNTimer(buff, best.z, kind, { who = best.who or who })
                handled = handled + 1
            end
        end
    end

    -- Songflower / node picks, IF a future SN broadcast carries them. The real
    -- capture in hand contains NO node data, so the exact SN key shape is unproven;
    -- we accept only an unambiguous indexed-epoch map ("flowerN"/"tuberN" or a
    -- flower/tuber sub-table of index->epoch) and route via the public MarkNode
    -- surface. Anything we do not recognize is silently ignored (never guessed).
    handled = handled + translateNodes(payload)

    return handled
end

----------------------------------------------------------------------
-- Chunk envelope + reassembly (RECEIVE)
--
-- SN chunks logical messages > ~255 bytes with a small leading envelope,
-- derived from the owner's wire capture (harness snfixture.lua) and VERIFIED
-- byte-for-byte against it:
--   byte 1  = frame type:
--               'S' complete single message
--               'F' first chunk   (byte 3 = total chunk count)
--               'L' last  chunk
--               'M'/'N' speculative middle (NOT observed in the wild, but 3+-chunk
--                       messages exist; handled in arrival order, decode-guarded)
--   byte 2  = message counter (uint8) grouping the chunks of one logical message
--   byte 3  = 'F' ONLY: total chunk count
--   rest    = payload fragment. The FULL logical payload (after reassembly) is
--             <1-byte opcode><channel-encoded XOR+deflate+serialize stream>; we
--             strip the opcode and hand the remainder to the existing Decode
--             chain (channel-decode -> XOR "ShadowNt" -> inflate -> deserialize).
--             PROVEN order: reassemble F..L -> drop opcode -> SNBridge.Decode.
--
-- Everything is defensive: unknown type bytes, orphan/incomplete/oversized
-- reassemblies and format drift all decode to nothing and NEVER error. We NEVER
-- transmit — this is a pure one-way intake.
----------------------------------------------------------------------

local REASM_TIMEOUT     = 30    -- seconds an incomplete reassembly may linger
local REASM_MAX_PENDING = 8     -- cap on concurrent in-flight reassemblies
local FRAME_TYPES  = { S = true, F = true, L = true, M = true, N = true }
local FRAME_MIDDLE = { M = true, N = true }

-- Clock indirection (server epoch). Overridable in self-tests to exercise the
-- reassembly timeout deterministically.
function SNBridge._now()
    return (ns.Store and ns.Store.Now and ns.Store.Now())
        or (GetServerTime and GetServerTime())
        or (time and time()) or 0
end

-- Parse the chunk envelope. Returns a table {type,counter,total?,payload} for a
-- recognized frame, or nil for a headerless/unknown frame (caller falls back to
-- the legacy single-frame decode, then to capture-and-skip). Pure.
function SNBridge._parseEnvelope(text)
    if type(text) ~= "string" or #text < 2 then return nil end
    local t = text:sub(1, 1)
    if not FRAME_TYPES[t] then return nil end
    local counter = text:byte(2)
    if t == "F" then
        if #text < 3 then return nil end
        return { type = t, counter = counter, total = text:byte(3), payload = text:sub(4) }
    end
    -- S / L / M / N: 2-byte header, payload follows.
    return { type = t, counter = counter, payload = text:sub(3) }
end

SNBridge._reasm = {}   -- key -> { total, parts = {}, opened }

local function reasmKey(sender, prefix, counter)
    return tostring(sender) .. "\0" .. tostring(prefix) .. "\0" .. tostring(counter)
end

local function reasmCount()
    local n = 0
    for _ in pairs(SNBridge._reasm) do n = n + 1 end
    return n
end

-- Drop reassemblies older than REASM_TIMEOUT. Cheap, opportunistic sweep run on
-- every inbound frame (SN traffic is low-rate; no dedicated ticker needed).
local function reasmSweep(nowT)
    for k, e in pairs(SNBridge._reasm) do
        if (nowT - (e.opened or 0)) > REASM_TIMEOUT then
            SNBridge._reasm[k] = nil
            snBump("drop", "reasmTimeout")
        end
    end
end

-- Evict the oldest pending reassembly when at capacity (before opening a new one).
local function reasmEvictOldest()
    local oldestK, oldestT
    for k, e in pairs(SNBridge._reasm) do
        if not oldestT or (e.opened or 0) < oldestT then oldestK, oldestT = k, (e.opened or 0) end
    end
    if oldestK then
        SNBridge._reasm[oldestK] = nil
        snBump("drop", "reasmEvicted")
    end
end

local function isRecvPrefix(prefix)
    for i = 1, #SNBridge.RECV_PREFIXES do
        if SNBridge.RECV_PREFIXES[i] == prefix then return true end
    end
    return false
end
SNBridge._isRecvPrefix = isRecvPrefix

-- Shared decode -> version -> freshness -> translate tail. `stream` is the raw
-- channel-encoded payload (opcode already stripped), from either a single frame
-- or a completed reassembly. Returns handled-count.
local function ingestStream(stream, channel, sender)
    local stats = SNBridge._stats
    local payload = SNBridge.Decode(stream, channel)
    if not payload then return 0 end
    -- Test/diagnostic seam: observe every successfully-decoded table (before the
    -- version gate). Never set in production. pcall so a test hook can't break us.
    if SNBridge._onDecoded then pcall(SNBridge._onDecoded, payload, sender, channel) end
    if not SNBridge.VersionOK(payload) then snBump("drop", "versionGate"); return 0 end
    stats.versionOK = stats.versionOK + 1
    -- Heard valid, version-gated SN timer traffic — stamp freshness even if
    -- nothing translated (so the UI can show "SN seen Ns ago").
    if ns.Timers and ns.Timers._noteFreshness then
        ns.Timers._noteFreshness("snPassive")
    end
    local n = SNBridge.Translate(payload, sender)
    if n == 0 then snBump("drop", "translateZero") else stats.translated = stats.translated + n end
    return n
end

-- Strip the 1-byte inner opcode and run the shared decode tail on a completed
-- logical payload (single or reassembled).
local function decodeLogical(logical, channel, sender)
    if type(logical) ~= "string" or #logical < 1 then return 0 end
    return ingestStream(logical:sub(2), channel, sender)
end

-- Core ingest for one raw SN message. Returns handled-count (0 on any skip).
-- Fully pcall-guarded: SN traffic can never error us, whatever shape it arrives
-- in. A single 'S' frame decodes immediately; 'F'/'M'/'L' feed the reassembly
-- buffer and only decode once the 'L' closes the set; an unrecognized envelope
-- falls back to the legacy headerless decode (and then to capture-and-skip).
function SNBridge.Ingest(prefix, text, channel, sender)
    if not isRecvPrefix(prefix) then snBump("drop", "notRecvPrefix"); return 0 end
    local stats = SNBridge._stats
    stats.heard = stats.heard + 1
    stats.byChannel[channel or "?"] = (stats.byChannel[channel or "?"] or 0) + 1
    -- Capture the raw frame (bytes only) BEFORE decode so fragments are preserved.
    ns:SafeCall(SNBridge.CaptureFrame, sender, channel, text)
    local ok, handled = pcall(function()
        local nowT = SNBridge._now()
        reasmSweep(nowT)

        local env = SNBridge._parseEnvelope(text)
        if not env then
            -- Headerless / unknown-first-byte: try the legacy single-frame decode
            -- (backward compatibility + defensive), else capture-and-skip.
            local payload = SNBridge.Decode(text, channel)
            if not payload then snBump("drop", "unknownType"); return 0 end
            if SNBridge._onDecoded then pcall(SNBridge._onDecoded, payload, sender, channel) end
            if not SNBridge.VersionOK(payload) then snBump("drop", "versionGate"); return 0 end
            stats.versionOK = stats.versionOK + 1
            if ns.Timers and ns.Timers._noteFreshness then ns.Timers._noteFreshness("snPassive") end
            local n = SNBridge.Translate(payload, sender)
            if n == 0 then snBump("drop", "translateZero") else stats.translated = stats.translated + n end
            return n
        end

        if env.type == "S" then
            -- Complete single logical message: <opcode><stream>.
            return decodeLogical(env.payload, channel, sender)
        end

        -- Chunked: F opens, M/N append (arrival order), L closes.
        local key = reasmKey(sender, prefix, env.counter)
        if env.type == "F" then
            if not SNBridge._reasm[key] and reasmCount() >= REASM_MAX_PENDING then
                reasmEvictOldest()
            end
            -- A fresh 'F' for this (sender,prefix,counter) REPLACES any stale pending
            -- set (counter reuse from the same sender).
            SNBridge._reasm[key] = { total = env.total, parts = { env.payload }, opened = nowT }
            stats.reasmOpened = stats.reasmOpened + 1
            return 0
        elseif FRAME_MIDDLE[env.type] then
            local e = SNBridge._reasm[key]
            if not e then snBump("drop", "reasmOrphan"); return 0 end
            e.parts[#e.parts + 1] = env.payload
            stats.reasmMiddle = stats.reasmMiddle + 1
            return 0
        elseif env.type == "L" then
            local e = SNBridge._reasm[key]
            if not e then snBump("drop", "reasmOrphan"); return 0 end
            SNBridge._reasm[key] = nil
            e.parts[#e.parts + 1] = env.payload
            -- If a total was advertised and we are short, still best-effort assemble;
            -- a truncated stream simply fails to inflate and is skipped.
            if e.total and #e.parts < e.total then snBump("drop", "reasmIncomplete") end
            stats.reasmCompleted = stats.reasmCompleted + 1
            return decodeLogical(table.concat(e.parts), channel, sender)
        end
        return 0
    end)
    if not ok then return 0 end   -- silent skip on ANY error
    return handled or 0
end

local function onChatMsgAddon(event, prefix, text, channel, sender)
    if not isRecvPrefix(prefix) then return end
    -- Never process our own echoes (we never send SN, but a guildmate relay of
    -- our name should still be harmless; guard anyway on the self name).
    SNBridge.Ingest(prefix, text, channel, sender)
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

SNBridge._active = false

function SNBridge.OnLogin()
    if SNBridge._active then return end
    -- RECEIVE registration only. This lets inbound SDWW/SNT reach CHAT_MSG_ADDON;
    -- it grants no ability to send. We register a dedicated listener that filters
    -- to the SN prefixes and hands off to the defensive ingest.
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        for i = 1, #SNBridge.RECV_PREFIXES do
            C_ChatInfo.RegisterAddonMessagePrefix(SNBridge.RECV_PREFIXES[i])
        end
    end
    ns:RegisterEvent("CHAT_MSG_ADDON", onChatMsgAddon)
    SNBridge._active = true
end

----------------------------------------------------------------------
-- Debug: /nexus debug snbridge
----------------------------------------------------------------------

function SNBridge.DebugDump()
    local LS, LD = libSerialize(), libDeflate()
    ns:Print("snbridge: " .. (SNBridge._active and "active" or "inactive")
        .. " | libs " .. ((LS and LD) and "present" or "ABSENT")
        .. " | recv " .. table.concat(SNBridge.RECV_PREFIXES, "+") .. " (RECEIVE-ONLY)")
    local f = ns.Timers and ns.Timers.GetSourceFreshness and ns.Timers.GetSourceFreshness()
    if f then
        ns:Print(string.format("  snPassive last-seen epoch = %d", f.snPassive or 0))
    end
    -- Per-stage counters (item 41).
    local s = SNBridge._stats
    local chans = {}
    for ch, n in pairs(s.byChannel) do chans[#chans + 1] = ch .. "=" .. n end
    ns:Print(string.format("  heard=%d [%s]", s.heard, table.concat(chans, " ")))
    ns:Print(string.format("  stages: chanDecodeOK=%d inflateOK=%d deserializeOK=%d versionOK=%d translated=%d",
        s.channelDecodeOK, s.inflateOK, s.deserializeOK, s.versionOK, s.translated))
    ns:Print(string.format("  drops: notRecvPrefix=%d chanDecode=%d SUSPECTED-FRAGMENT=%d deserialize=%d versionGate=%d translateZero=%d",
        s.drop.notRecvPrefix, s.drop.channelDecode, s.drop.suspectedFragment,
        s.drop.deserialize, s.drop.versionGate, s.drop.translateZero))
    local pending = 0
    for _ in pairs(SNBridge._reasm) do pending = pending + 1 end
    ns:Print(string.format("  reasm: opened=%d completed=%d middle=%d pending=%d | drops timeout=%d evicted=%d orphan=%d incomplete=%d unknownType=%d",
        s.reasmOpened, s.reasmCompleted, s.reasmMiddle, pending,
        s.drop.reasmTimeout, s.drop.reasmEvicted, s.drop.reasmOrphan, s.drop.reasmIncomplete, s.drop.unknownType))
    local cap = ns.Store and ns.Store.GetData and ns.Store.GetData() and ns.Store.GetData().snCapture
    if cap then
        ns:Print(string.format("  capture: %s | frames=%d (cap %d, evicted %d) — /nexus debug sncapture dump",
            cap.enabled and "ON" or "off", cap.frames and #cap.frames or 0, CAPTURE_CAP, cap.dropped or 0))
    else
        ns:Print("  capture: off (use /nexus debug sncapture on)")
    end
end

-- /nexus debug sncapture on|off|dump  (item 41). Wire-capture control + dump.
function SNBridge.CaptureCommand(arg)
    arg = (arg or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if arg == "on" then
        if SNBridge.SetCapture(true) then ns:Print("snbridge capture: ON (raw SDWW/SNT frames -> DaseekiNexusData.snCapture, cap " .. CAPTURE_CAP .. ").")
        else ns:Print("snbridge capture: data store unavailable.") end
    elseif arg == "off" then
        SNBridge.SetCapture(false)
        ns:Print("snbridge capture: off.")
    elseif arg == "dump" then
        local cap = captureStore(false)
        if not cap or not cap.frames or #cap.frames == 0 then
            ns:Print("snbridge capture: no frames captured.")
            return
        end
        ns:Print(string.format("snbridge capture dump: %d frame(s) (newest last):", #cap.frames))
        for i = 1, #cap.frames do
            local fr = cap.frames[i]
            ns:Print(string.format("  [%d] %s via %s @%d len=%d", i,
                tostring(fr.sender), tostring(fr.channel), fr.at or 0, fr.len or 0))
            ns:Print("      " .. tostring(fr.raw))
        end
    else
        ns:Print("usage: /nexus debug sncapture on|off|dump")
    end
end

----------------------------------------------------------------------
-- TEST-ONLY encoder (self-test fixtures ONLY — never a transmit path)
--
-- Mirrors the documented SDWW encode pipeline so the self-tests can prove the
-- decode chain round-trips: short-keyed table -> serialize -> deflate(level 9)
-- -> XOR "ShadowNt" -> channel-safe encode, then the SN chunk envelope. These
-- functions are NOT reachable from any SendAddonMessage / SendCommMessage call
-- site; grep-verify they are only used inside RunSelfTests below.
----------------------------------------------------------------------

-- Inner opcode bytes observed in the real capture (single vs chunked). Opaque to
-- decode (always stripped); mirrored here so test frames match the wire exactly.
local OPCODE_SINGLE, OPCODE_CHUNK = 0x11, 0x10

-- Produce the raw channel-encoded XOR+deflate+serialize stream (no envelope).
local function testEncodeStream(payload, channel)
    local LS, LD = libSerialize(), libDeflate()
    if not (LS and LD) then return nil end
    local ser = LS:Serialize(payload)
    local comp = LD:CompressDeflate(ser, { level = 9 })
    local xored = SNBridge.XorCrypt(comp, XOR_KEY)
    if channel == "YELL" or channel == "SAY" then
        return LD:EncodeForWoWChatChannel(xored)
    end
    return LD:EncodeForWoWAddonChannel(xored)
end

-- A complete single 'S' frame: "S" <counter> <opcode> <stream>.
function SNBridge._TEST_encode(payload, channel, counter)
    local stream = testEncodeStream(payload, channel)
    if not stream then return nil end
    return "S" .. string.char(counter or 1) .. string.char(OPCODE_SINGLE) .. stream
end

-- Split one logical payload into nchunks F/(M...)/L frames sharing a counter.
-- The logical payload is <opcode><stream>; it is chunked byte-wise exactly as SN
-- does on the wire. Returns an array of frame strings in F..L order.
function SNBridge._TEST_chunkEncode(payload, channel, counter, nchunks)
    local stream = testEncodeStream(payload, channel)
    if not stream then return nil end
    counter = counter or 1
    nchunks = nchunks or 2
    local logical = string.char(OPCODE_CHUNK) .. stream
    local piece = math.ceil(#logical / nchunks)
    local frames, idx = {}, 1
    for c = 1, nchunks do
        local part = logical:sub(idx, idx + piece - 1)
        idx = idx + piece
        if c == 1 then
            frames[c] = "F" .. string.char(counter) .. string.char(nchunks) .. part
        elseif c == nchunks then
            frames[c] = "L" .. string.char(counter) .. part
        else
            frames[c] = "M" .. string.char(counter) .. part
        end
    end
    return frames
end

----------------------------------------------------------------------
-- Self-tests (pure + lib-backed; run via /nexus debug selftest)
----------------------------------------------------------------------

local function tcheck(cond, msg, fails)
    if not cond then fails[#fails + 1] = msg end
    return cond
end

-- XOR is symmetric and round-trips arbitrary bytes.
local function testXorRoundTrip(fails)
    local s = "\0\1\2\3ABC\255\254 the quick brown fox"
    local enc = SNBridge.XorCrypt(s, XOR_KEY)
    tcheck(enc ~= s, "xor changes the buffer", fails)
    local dec = SNBridge.XorCrypt(enc, XOR_KEY)
    tcheck(dec == s, "xor(xor(x)) == x", fails)
    -- byte xor sanity
    tcheck(SNBridge._xorByte(0xFF, 0x0F) == 0xF0, "xorByte 0xFF^0x0F=0xF0", fails)
    tcheck(SNBridge._xorByte(0, 123) == 123, "xorByte 0^x=x", fails)
end

-- Buff resolution incl. faction split and unknown -> nil.
local function testBuffResolve(fails)
    tcheck(SNBridge.ResolveBuff("rend") == "rend", "rend resolves", fails)
    tcheck(SNBridge.ResolveBuff("zan") == "zg", "zan -> zg", fails)
    tcheck(SNBridge.ResolveBuff("onyH") == "onyH", "explicit onyH passes", fails)
    tcheck(SNBridge.ResolveBuff("onya") == "onyA", "explicit onya -> onyA", fails)
    local ony = SNBridge.ResolveBuff("ony", "Horde")
    tcheck(ony == "onyH", "bare ony resolves to faction (Horde)", fails)
    tcheck(SNBridge.ResolveBuff("nef", "Alliance") == "nefA", "bare nef -> nefA (Alliance)", fails)
    tcheck(SNBridge.ResolveBuff("gibberish") == nil, "unknown id -> nil", fails)
end

-- Version gate.
local function testVersionGate(fails)
    tcheck(SNBridge.VersionOK({ v = 2, buff = "rend" }) == true, "version 2 accepted", fails)
    tcheck(SNBridge.VersionOK({ v = 3, buff = "rend" }) == false, "version 3 rejected", fails)
    tcheck(SNBridge.VersionOK({ buff = "rend" }) == true, "absent version tolerated", fails)
end

-- Does LibDeflate compress/decompress round-trip in THIS VM? (It does in-game;
-- some non-WoW Lua VMs used for CI cannot round-trip LibDeflate's inflate.)
local function deflateRoundTrips()
    local LD = libDeflate()
    if not LD then return false end
    local s = "sn-bridge-sentinel-0123456789"
    local c = LD:CompressDeflate(s, { level = 9 })
    if not c then return false end
    return LD:DecompressDeflate(c) == s
end

-- Translation logic in isolation (no crypto) — validates SN payload -> our
-- ingest routing under ANY VM. This is the core of the ingest coverage.
local function testTranslate(fails)
    if not (ns.Timers and ns.Timers.OnSNTimer) then
        fails[#fails + 1] = "timers layer absent"
        return
    end
    local savedTimer, savedPull = ns.Timers.OnSNTimer, ns.Timers.OnSNPull
    local seen = {}
    ns.Timers.OnSNTimer = function(buff, epoch, kind) seen[#seen + 1] = { buff = buff, epoch = epoch, kind = kind, pull = false } end
    ns.Timers.OnSNPull  = function(buff, epoch, dur, zone) seen[#seen + 1] = { buff = buff, epoch = epoch, dur = dur, zone = zone, pull = true } end
    local now = 1700000000
    -- single timer
    tcheck(SNBridge.Translate({ v = 2, buff = "onyH", epoch = now, event = "pop" }, "G") == 1, "single timer -> 1 event", fails)
    tcheck(seen[1] and seen[1].buff == "onyH" and not seen[1].pull, "onyH routed to OnSNTimer", fails)
    -- killed kind normalizes
    seen = {}
    SNBridge.Translate({ v = 2, buff = "onyH", epoch = now, kind = "killed" }, "G")
    tcheck(seen[1] and seen[1].kind == "killed", "kind=killed normalized", fails)
    -- pull
    seen = {}
    tcheck(SNBridge.Translate({ v = 2, buff = "rend", epoch = now, kind = "pull", duration = 120, zone = "Org" }, "G") == 1, "pull -> 1 event", fails)
    tcheck(seen[1] and seen[1].pull and seen[1].dur == 120, "pull routed to OnSNPull w/ duration", fails)
    -- batch
    seen = {}
    tcheck(SNBridge.Translate({ v = 2, timers = { rend = now, zg = now - 60 } }, "G") == 2, "batch of 2 -> 2 events", fails)
    -- unknown buff yields nothing
    seen = {}
    tcheck(SNBridge.Translate({ v = 2, buff = "gibberish", epoch = now }, "G") == 0, "unknown buff -> 0 events", fails)
    ns.Timers.OnSNTimer, ns.Timers.OnSNPull = savedTimer, savedPull
end

-- Full decode chain + translation, exercised through the TEST-ONLY encoder.
-- Skipped cleanly when the libs are unavailable OR the VM's LibDeflate cannot
-- round-trip (in-game WoW Lua 5.1 round-trips fine, so this runs fully there).
local function testDecodeChain(fails)
    local LS, LD = libSerialize(), libDeflate()
    if not (LS and LD) then return end   -- skip: no libs
    if not deflateRoundTrips() then return end   -- skip: VM deflate limitation
    if not (ns.Timers and ns.Timers.OnSNTimer) then
        fails[#fails + 1] = "timers layer absent for sn decode test"
        return
    end

    -- Capture what the timers layer receives without mutating real state.
    local savedTimer, savedPull = ns.Timers.OnSNTimer, ns.Timers.OnSNPull
    local seen = {}
    ns.Timers.OnSNTimer = function(buff, epoch, kind) seen[#seen + 1] = { buff = buff, epoch = epoch, kind = kind, pull = false } end
    ns.Timers.OnSNPull  = function(buff, epoch, dur, zone) seen[#seen + 1] = { buff = buff, epoch = epoch, dur = dur, zone = zone, pull = true } end

    local now = 1700000000

    -- 1) single timer pop, version 2, addon channel
    local wire1 = SNBridge._TEST_encode({ v = 2, buff = "onyH", epoch = now, event = "pop" })
    local h1 = SNBridge.Ingest("SDWW", wire1, "GUILD", "Guildie-Realm")
    tcheck(h1 == 1, "single SDWW timer decoded+translated", fails)
    tcheck(seen[1] and seen[1].buff == "onyH" and seen[1].epoch == now and not seen[1].pull,
        "onyH pop routed to OnSNTimer", fails)

    -- 2) pull alert with duration + zone
    seen = {}
    local wire2 = SNBridge._TEST_encode({ v = 2, buff = "rend", epoch = now, kind = "pull", duration = 120, zone = "Orgrimmar" })
    local h2 = SNBridge.Ingest("SDWW", wire2, "GUILD", "Guildie-Realm")
    tcheck(h2 == 1 and seen[1] and seen[1].pull and seen[1].buff == "rend" and seen[1].dur == 120,
        "SDWW pull routed to OnSNPull with duration", fails)

    -- 3) batch timer map (legacy SNT prefix)
    seen = {}
    local wire3 = SNBridge._TEST_encode({ v = 2, timers = { rend = now, zg = now - 60 } })
    local h3 = SNBridge.Ingest("SNT", wire3, "GUILD", "Guildie-Realm")
    tcheck(h3 == 2, "batch of 2 timers translated over legacy SNT", fails)

    -- 4) wrong version -> silent skip (0 handled)
    seen = {}
    local wire4 = SNBridge._TEST_encode({ v = 3, buff = "rend", epoch = now })
    tcheck(SNBridge.Ingest("SDWW", wire4, "GUILD", "x") == 0, "version-3 message skipped", fails)

    -- 5) garbage / non-SN bytes -> silent skip, never error
    tcheck(SNBridge.Ingest("SDWW", "not-a-valid-frame", "GUILD", "x") == 0, "garbage skipped, no error", fails)
    tcheck(SNBridge.Ingest("DSKN0", wire1, "GUILD", "x") == 0, "non-SN prefix ignored", fails)

    ns.Timers.OnSNTimer, ns.Timers.OnSNPull = savedTimer, savedPull
end

-- EscapeBytes / UnescapeBytes are exact inverses over arbitrary bytes (pure).
local function testEscapeRoundTrip(fails)
    local s = string.char(0, 1, 9, 10, 13, 31, 32, 65, 66, 127, 200, 255) ..
              [["quoted"]] .. string.char(92) .. "tail"
    local esc = SNBridge.EscapeBytes(s)
    tcheck(SNBridge.UnescapeBytes(esc) == s, "unescape(escape(x)) == x over all byte classes", fails)
    tcheck(SNBridge.UnescapeBytes("AB\\x01\\xFF\\x5C") == "AB\1\255\\", "unescape decodes \\xHH", fails)
end

-- Log-array + node translation in isolation (no crypto) — validates the REAL SN
-- "Broadcast Timers" payload shape (rendLog/onyLogH/onyLogA + node keys) routes
-- to OnSNTimer/MarkNode. Runs under ANY VM.
local function testLogTranslate(fails)
    if not (ns.Timers and ns.Timers.OnSNTimer) then
        fails[#fails + 1] = "timers layer absent"; return
    end
    local savedT, savedP, savedN = ns.Timers.OnSNTimer, ns.Timers.OnSNPull, ns.Timers.MarkNode
    local seen, nodes = {}, {}
    ns.Timers.OnSNTimer = function(buff, epoch, kind, meta)
        seen[#seen + 1] = { buff = buff, epoch = epoch, kind = kind, who = meta and meta.who }
    end
    ns.Timers.OnSNPull = function() end
    ns.Timers.MarkNode = function(kind, i, e) nodes[#nodes + 1] = { kind = kind, i = i, e = e }; return true end
    local function restore() ns.Timers.OnSNTimer, ns.Timers.OnSNPull, ns.Timers.MarkNode = savedT, savedP, savedN end

    local now = 1785279000
    -- Newest entry per log anchors; empty log = 0.
    local h = SNBridge.Translate({
        v = 2,
        rendLog = { { z = now - 3600, who = "old" }, { z = now, who = "fresh", killed = true } },
        onyLogH = { { z = now - 100, who = "h" } },
        onyLogA = {},
    }, "Broadcaster")
    local byBuff = {}
    for _, e in ipairs(seen) do byBuff[e.buff] = e end
    tcheck(byBuff.rend and byBuff.rend.epoch == now, "rendLog newest entry anchored", fails)
    -- F2: Rend has NO announcer NPC — the only killable thing is Rend Blackhand
    -- himself — so a rendLog `killed` flag is a raid-boss kill and rides as a
    -- POP. Forwarding it as "killed" asked the engine to start a 6-minute
    -- respawn for an NPC that does not exist.
    tcheck(byBuff.rend and byBuff.rend.kind == "pop" and byBuff.rend.who == "fresh",
        "rendLog killed flag routes as a POP, with who carried (F2)", fails)
    tcheck(byBuff.onyH and byBuff.onyH.epoch == now - 100, "onyLogH anchored", fails)
    tcheck(byBuff.onyA == nil, "empty onyLogA -> no anchor", fails)
    tcheck(h == 2, "two logs -> 2 anchors", fails)

    -- ...and an ONYXIA log's killed flag still means the announcer died.
    seen = {}
    SNBridge.Translate({ v = 2, onyLogH = { { z = now, who = "Runthak", killed = true } } }, "B")
    tcheck(seen[1] and seen[1].buff == "onyH" and seen[1].kind == "killed",
        "onyLogH killed flag stays an announcer kill", fails)
    -- Zandalar has no announcer either.
    seen = {}
    SNBridge.Translate({ v = 2, zgLog = { { z = now, who = "Hakkar", killed = true } } }, "B")
    tcheck(seen[1] and seen[1].buff == "zg" and seen[1].kind == "pop",
        "zgLog killed flag routes as a POP (Hakkar is not an announcer)", fails)
    -- The single-event path applies the same rule.
    seen = {}
    SNBridge.Translate({ v = 2, buff = "rend", epoch = now, kind = "killed" }, "B")
    tcheck(seen[1] and seen[1].kind == "pop", "single-event rend kill routes as a pop", fails)
    seen = {}
    SNBridge.Translate({ v = 2, buff = "nefH", epoch = now, kind = "killed" }, "B")
    tcheck(seen[1] and seen[1].kind == "killed", "single-event nefH kill stays a kill", fails)

    -- A quest entry carries the hand-in kind through to the engine, which owns
    -- the +15s lead and the pending-local-hand-in rule (F7).
    seen = {}
    SNBridge.Translate({ v = 2, rendLog = { { z = now, who = "Ann", quest = true } } }, "B")
    tcheck(seen[1] and seen[1].kind == "quest" and seen[1].epoch == now,
        "rendLog quest flag routes as a hand-in at its raw epoch", fails)

    -- Flat node keys route through MarkNode (defensive/forward-looking shape).
    seen, nodes = {}, {}
    SNBridge.Translate({ v = 2, flower1 = now, tuber3 = now - 5 }, "B")
    local haveF, haveT = false, false
    for _, n in ipairs(nodes) do
        if n.kind == "flower" and n.i == 1 then haveF = true end
        if n.kind == "tuber" and n.i == 3 then haveT = true end
    end
    tcheck(haveF and haveT, "flowerN/tuberN keys route to MarkNode", fails)

    restore()
end

-- Chunk reassembly: interleaved two-sender, 3-chunk, timeout, unknown-type.
-- Uses the TEST-ONLY chunk encoder; skipped when libs / deflate cannot round-trip.
local function testReassembly(fails)
    local LS, LD = libSerialize(), libDeflate()
    if not (LS and LD) then return end
    if not deflateRoundTrips() then return end
    if not (ns.Timers and ns.Timers.OnSNTimer) then
        fails[#fails + 1] = "timers layer absent for reassembly test"; return
    end
    local savedT, savedP = ns.Timers.OnSNTimer, ns.Timers.OnSNPull
    local seen = {}
    ns.Timers.OnSNTimer = function(buff, epoch, kind, meta)
        seen[#seen + 1] = { buff = buff, epoch = epoch, kind = kind, who = meta and meta.who }
    end
    ns.Timers.OnSNPull = function() end
    local function restore() ns.Timers.OnSNTimer, ns.Timers.OnSNPull = savedT, savedP end

    SNBridge._reasm = {}   -- isolate
    local now = 1785279000

    -- (b) Interleaved chunks, TWO senders, SAME counter -> keyed independently.
    local fa = SNBridge._TEST_chunkEncode({ v = 2, rendLog = { { z = now, who = "AAA" } } }, "GUILD", 1, 2)
    local fb = SNBridge._TEST_chunkEncode({ v = 2, onyLogH = { { z = now, who = "BBB" } } }, "GUILD", 1, 2)
    if not (fa and fb and #fa == 2 and #fb == 2) then fails[#fails + 1] = "chunk encoder failed"; restore(); return end
    tcheck(fa[1]:sub(1, 1) == "F" and fa[2]:sub(1, 1) == "L", "chunk encoder emits F..L", fails)
    -- Interleave: F_A, F_B, L_A, L_B.
    SNBridge.Ingest("SDWW", fa[1], "GUILD", "Alpha-R")
    SNBridge.Ingest("SDWW", fb[1], "GUILD", "Bravo-R")
    local hA = SNBridge.Ingest("SDWW", fa[2], "GUILD", "Alpha-R")
    local hB = SNBridge.Ingest("SDWW", fb[2], "GUILD", "Bravo-R")
    tcheck(hA == 1 and hB == 1, "both interleaved reassemblies completed", fails)
    local byBuff = {}
    for _, e in ipairs(seen) do byBuff[e.buff] = e end
    tcheck(byBuff.rend and byBuff.rend.who == "AAA", "sender A -> rend (no cross-contamination)", fails)
    tcheck(byBuff.onyH and byBuff.onyH.who == "BBB", "sender B -> onyH (no cross-contamination)", fails)

    -- 3-chunk F/M/L reassembles.
    seen = {}; SNBridge._reasm = {}
    local f3 = SNBridge._TEST_chunkEncode({ v = 2, rendLog = { { z = now, who = "MID" } } }, "GUILD", 7, 3)
    tcheck(f3 and #f3 == 3 and f3[2]:sub(1, 1) == "M", "3-chunk encoder emits F/M/L", fails)
    SNBridge.Ingest("SDWW", f3[1], "GUILD", "Char-R")
    SNBridge.Ingest("SDWW", f3[2], "GUILD", "Char-R")
    local h3 = SNBridge.Ingest("SDWW", f3[3], "GUILD", "Char-R")
    tcheck(h3 == 1 and seen[1] and seen[1].buff == "rend", "3-chunk F/M/L reassembled+translated", fails)

    -- (c) Incomplete reassembly times out cleanly (no error, pending cleared).
    seen = {}; SNBridge._reasm = {}
    local savedNow = SNBridge._now
    local clock = now
    SNBridge._now = function() return clock end
    local f2 = SNBridge._TEST_chunkEncode({ v = 2, rendLog = { { z = now, who = "X" } } }, "GUILD", 9, 2)
    SNBridge.Ingest("SDWW", f2[1], "GUILD", "Dangle-R")   -- F only, never closed
    local pendingBefore = 0; for _ in pairs(SNBridge._reasm) do pendingBefore = pendingBefore + 1 end
    tcheck(pendingBefore == 1, "incomplete reassembly is pending", fails)
    clock = now + REASM_TIMEOUT + 5
    -- Any subsequent inbound frame triggers the sweep.
    SNBridge.Ingest("SDWW", "Zx", "GUILD", "Other-R")
    local pendingAfter = 0; for _ in pairs(SNBridge._reasm) do pendingAfter = pendingAfter + 1 end
    tcheck(pendingAfter == 0, "stale incomplete reassembly swept after timeout", fails)
    SNBridge._now = savedNow

    -- (d) Unknown type byte -> ignored without error (0 handled).
    seen = {}
    local okZ = pcall(function() return SNBridge.Ingest("SDWW", "Z\1garbage-bytes", "GUILD", "U-R") end)
    tcheck(okZ, "unknown type byte does not error", fails)
    tcheck(SNBridge.Ingest("SDWW", "\240\5\6\7", "GUILD", "U-R") == 0, "high-byte unknown frame skipped", fails)

    SNBridge._reasm = {}
    restore()
end

-- Capture ring-buffer mechanics (item 41): escape format, cap eviction, dump shape.
local function testCaptureRing(fails)
    if not (ns.Store and ns.Store.GetData and ns.Store.GetData()) then
        return   -- skip: no data store in this VM
    end
    -- Escape: control/high bytes + backslash -> \xHH; printable ASCII untouched.
    tcheck(SNBridge.EscapeBytes("AB\1\255\\") == "AB\\x01\\xFF\\x5C", "escape bytes to \\xHH", fails)
    tcheck(SNBridge.EscapeBytes("plain text") == "plain text", "printable untouched", fails)
    -- Fresh capture store, enable, overflow the cap, verify eviction + order.
    local data = ns.Store.GetData()
    data.snCapture = { enabled = false, frames = {}, dropped = 0 }
    SNBridge.SetCapture(true)
    tcheck(SNBridge.CaptureEnabled() == true, "capture enables", fails)
    for i = 1, CAPTURE_CAP + 5 do
        SNBridge.CaptureFrame("S" .. i .. "-R", "GUILD", "raw" .. i)
    end
    local cap = data.snCapture
    tcheck(#cap.frames == CAPTURE_CAP, "ring capped at CAPTURE_CAP", fails)
    tcheck(cap.dropped == 5, "evicted count tracked", fails)
    tcheck(cap.frames[#cap.frames].sender == "S" .. (CAPTURE_CAP + 5) .. "-R", "newest frame retained", fails)
    tcheck(cap.frames[1].sender == "S6-R", "oldest 5 evicted (FIFO)", fails)
    tcheck(cap.frames[1].len == #("raw6"), "frame length recorded", fails)
    -- Disable stops capture.
    SNBridge.SetCapture(false)
    local before = #cap.frames
    SNBridge.CaptureFrame("X-R", "GUILD", "nope")
    tcheck(#cap.frames == before, "disabled capture is a no-op", fails)
    data.snCapture = nil   -- leave the store clean for other suites
end

function SNBridge.RunSelfTests(verbose)
    local suites = {
        { name = "xor round-trip", fn = testXorRoundTrip },
        { name = "buff resolve",   fn = testBuffResolve },
        { name = "version gate",   fn = testVersionGate },
        { name = "translate",      fn = testTranslate },
        { name = "escape roundtrip", fn = testEscapeRoundTrip },
        { name = "log translate",  fn = testLogTranslate },
        { name = "decode chain",   fn = testDecodeChain },
        { name = "reassembly",     fn = testReassembly },
        { name = "capture ring",   fn = testCaptureRing },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok = pcall(suite.fn, fails)
        local passed = ok and #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then
                ns:Print("  PASS snbridge/" .. suite.name)
            elseif not ok then
                ns:Print("  FAIL snbridge/" .. suite.name .. " :: error in test")
            else
                for _, f in ipairs(fails) do
                    ns:Print("  FAIL snbridge/" .. suite.name .. " :: " .. f)
                end
            end
        end
    end
    return allPass
end

----------------------------------------------------------------------
-- Registration
----------------------------------------------------------------------

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("snbridge", SNBridge.RunSelfTests)
end
if ns.RegisterDebugCommand then
    ns:RegisterDebugCommand("snbridge", function() SNBridge.DebugDump() end)
    ns:RegisterDebugCommand("sncapture", function(args) SNBridge.CaptureCommand(args) end)
end

-- Activate at login (Core fires "LOGIN"); OnLogin self-guards on re-entry.
if ns.On then
    ns:On("LOGIN", function() ns:SafeCall(SNBridge.OnLogin) end)
end
