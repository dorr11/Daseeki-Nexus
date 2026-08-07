-- Daseeki Nexus — instances.lua
-- Instance-entry ledger + rolling-window cap math ("Instances" panel engine).
-- Detection, storage, the pure caps math, the SERVER-SERIAL merge, the
-- cross-account view, the chat warning, mesh merge, and /nexus debug instances.
--
-- Clean-room: derived from public Classic Era game mechanics, the owner's usage,
-- and NIT_BEHAVIOR_SPEC.md (a behaviour-only description). No third-party addon
-- source is ever read (same treatment as ShadowNetwork / NovaWorldBuffs).
--
-- The ground-truth server rule this models (public game fact):
--   * 5 instances per ROLLING 60 minutes, 30 per ROLLING 24h, enforced PER
--     ACCOUNT by the server. Re-entering an instance that is STILL ALIVE costs
--     nothing; a freshly instantiated map costs a slot.
--
-- API discipline (Interface 11509 / 1.15.9.68808 — every call catalog-verified):
--   IsInInstance()            -> isInInstance:bool, instanceType:cstring
--   GetInstanceInfo()         -> name, instanceType, difficultyID, difficultyName,
--                                maxPlayers, dynamicDifficulty, isDynamic,
--                                instanceID(8), instanceGroupSize, lfgDungeonID,
--                                hasWorldTier    (there is NO literal "mapID" field;
--                                the stable identifier is instanceID, stored as
--                                entry.mapID per the design schema)
--   GetMoney()                -> copper:number         (global; capability-guarded)
--   CombatLogGetCurrentEventInfo() -> timestamp, subEvent, hideCaster, sourceGUID,
--                                sourceName, sourceFlags, sourceRaidFlags, destGUID, ...
--   UnitGUID(unit)            -> guid:WOWGUID          (global; capability-guarded)
--   UnitLevel(unit)           -> level:number          (global)
--   UnitIsUnit(unit1, unit2)  -> result:bool
--   GetNumGroupMembers()      -> count:number          (global)
--   IsInRaid()                -> inRaid:bool           (global)
--   GetPlayerTradeMoney() / GetTargetTradeMoney() -> copper:number   (globals)
-- Events (all catalog-verified under Event.* in wow-api-catalog/latest):
--   PLAYER_ENTERING_WORLD, PLAYER_LEAVING_WORLD, PLAYER_LOGOUT,
--   UNIT_SPELLCAST_START / UNIT_SPELLCAST_SUCCEEDED (unitTarget, castGUID, spellID),
--   COMBAT_LOG_EVENT_UNFILTERED, UPDATE_MOUSEOVER_UNIT, PLAYER_TARGET_CHANGED,
--   CHAT_MSG_COMBAT_XP_GAIN, CHAT_MSG_MONEY, CHAT_MSG_SYSTEM,
--   GROUP_ROSTER_UPDATE            (Event.PartyInfo.GroupRosterUpdate),
--   TRADE_SHOW / TRADE_MONEY_CHANGED / PLAYER_TRADE_MONEY /
--   TRADE_ACCEPT_UPDATE (playerAccepted, targetAccepted) / TRADE_REQUEST_CANCEL /
--   TRADE_CLOSED                   (Event.TradeInfo.*).
-- Every live call is guarded with a presence check so the module loads and its
-- pure self-tests run headless with none of these globals present.

local ADDON, ns = ...

local Instances = {}
ns.Instances = Instances

local Store = ns.Store

----------------------------------------------------------------------
-- Tunables (owner-tunable; documented so the panel can surface them later)
----------------------------------------------------------------------

local RING_CAP     = 60         -- entries kept per character (capped ring)
local HOUR         = 3600
local DAY          = 86400

Instances.HOURLY_CAP  = 5
Instances.DAILY_CAP   = 30
Instances.WARN_HOURLY = 4       -- chat warning fires when the account hits this hourly count
Instances.WARN_DAILY  = 27      -- amber threshold (consumed by the panel UI, not this engine)

Instances.RING_CAP     = RING_CAP
Instances.HOUR         = HOUR
Instances.DAY          = DAY

-- Deferred serial sources (combat log, mouseover, target) are ignored for the
-- first N seconds after entering, so a mob we were fighting -- or still had
-- targeted or moused over -- on the way in cannot stamp the new record with the
-- OLD instance's serial (spec §2.1). The cast watcher is exempt: a cast event
-- arriving after entry is by definition from a unit in the new instance.
local SERIAL_SUPPRESS = 2
Instances.SERIAL_SUPPRESS = SERIAL_SUPPRESS
Instances.CL_SERIAL_SUPPRESS = SERIAL_SUPPRESS   -- retained name

-- Unclosed-run duration fallback bound (spec §3.3): beyond this an unclosed run
-- reports zero rather than an absurd elapsed.
local DUR_FALLBACK_MAX = 21600
Instances.DUR_FALLBACK_MAX = DUR_FALLBACK_MAX

-- Reserved account id for imported runs belonging to a character no account in
-- the store claims. Entries land here so they stay VISIBLE in the register, but
-- this bucket is excluded from every cap meter — piling unattributable alts onto
-- the local account's meter is the exact failure the caps meter must not have.
-- Deliberately NOT a valid account id (ns:IsValidAccountID demands 1-2 digits),
-- so it can never collide with a real account or be advertised over the mesh.
Instances.ORPHAN_AID = "orphan"

-- Only instanceTypes that actually consume the 5/hr instance cap are logged.
-- Battlegrounds/arenas/scenarios do NOT count against the dungeon/raid instance
-- limit, so they are excluded to keep the caps math honest against the server's
-- real enforcement. (owner-tunable: widen this set to log more transition types.)
local COUNTED_TYPES = { party = true, raid = true }
Instances.COUNTED_TYPES = COUNTED_TYPES

--[[  THE MERGE MODEL — SERVER INSTANCE SERIAL, NOT A HEURISTIC
======================================================================
Two runs are the same billed instance IFF the server says so, and the server
tells us: every creature/cast GUID observed inside carries the *instance serial*
(GUID field 5) — the id the server assigns to each distinct instantiation of a
map. Two runs share it iff they are physically the same live instance. That is
precisely the quantity the 5-per-hour rule is enforced on.

  On entry we create the record (counted immediately) and ARM a one-shot serial
  watcher across FOUR sources -- a cast GUID, a combat-log source GUID, the
  mouseover unit, and the target unit. Whichever fires first wins and disarms the
  rest. Breadth matters because the merge is retroactive: until a serial lands
  the meter reads one too high, so the cheapest early signal is the best one, and
  on the owner's own historical data mouseover was the single most productive
  source by a wide margin. The first usable GUID yields a serial, and:

    * if the PREVIOUS record already carries that same serial AND the new record
      carries none yet -> MERGE: fold the new record's takings into the previous
      one, mark it merged (so it consumes no slot), and continue the open run on
      the survivor.
    * otherwise -> commit the serial to the current record.

  Only the immediately preceding record is ever compared; there is no backward
  scan and no time window.

Consequences (all correct by construction, no tuning):
  * reset-and-rerun of the same dungeon -> new serial -> NOT merged -> the farm
    run correctly burns a slot, however fast it happened;
  * corpse run / hearth-out-and-summon-back / relog inside -> same live instance
    -> same serial -> merged -> no slot consumed;
  * the merge is RETROACTIVE: the entry counts the moment it happens and drops
    back only once the first creature cast is observed.

There is deliberately NO name comparison, NO time window and NO world-zone
signal. The previous implementation used all three; the zone signal in
particular was inert-by-construction because PLAYER_ENTERING_WORLD fires BEFORE
ZONE_CHANGED_NEW_AREA, so every exit latched the flag and poisoned the next
entry. ZONE_CHANGED_NEW_AREA is no longer consumed by this module at all.

A merged record is KEPT in the ledger flagged merged=true rather than deleted.
Deleting it would silently change the mesh instance-ledger hash input; flagging
is equivalent for every cap computation and keeps the wire contract intact.
======================================================================]]

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function now()
    return (Store and Store.Now and Store.Now()) or (time and time()) or 0
end

local function selfNameRealm()
    local name = (UnitName and UnitName("player")) or "player"
    local realm = (GetRealmName and GetRealmName()) or ""
    realm = realm:gsub("%s+", "")
    return name .. "-" .. realm
end

-- Get (and optionally create) the entries list for a character under an account.
local function charEntries(aid, nameRealm, create)
    local all = Store and Store.data and Store.data.instances
    if type(all) ~= "table" then
        if not create then return nil end
        all = {}
        if Store and Store.data then Store.data.instances = all end
    end
    aid = aid or ""
    local acct = all[aid]
    if type(acct) ~= "table" then
        if not create then return nil end
        acct = {}
        all[aid] = acct
    end
    local crec = acct[nameRealm]
    if type(crec) ~= "table" then
        if not create then return nil end
        crec = { entries = {} }
        acct[nameRealm] = crec
    end
    if type(crec.entries) ~= "table" then crec.entries = {} end
    return crec.entries
end

----------------------------------------------------------------------
-- PURE core (fully self-testable; no live client API, no globals)
----------------------------------------------------------------------

-- Classify an outside/inside transition, including the instance->instance case.
--   wasInside=false, isInside=true                       -> "entry"
--   wasInside=true,  isInside=false                      -> "exit"
--   wasInside=true,  isInside=true, keys differ          -> "reenter"
--   otherwise                                            -> "none"
-- prevKey / curKey are instance identity keys (instanceID, name fallback). Both
-- optional: with neither supplied this degrades to the plain 2-state classifier.
-- "reenter" is the UBRS->BWL / in-instance portal / summoned-from-inside-A-into-B
-- case: the caller must CLOSE the prior run and OPEN a new one, or the prior
-- entry's duration spans both runs and its takings are contaminated.
function Instances.ClassifyTransition(wasInside, isInside, prevKey, curKey)
    if isInside and not wasInside then return "entry" end
    if wasInside and not isInside then return "exit" end
    if wasInside and isInside
        and prevKey ~= nil and curKey ~= nil
        and tostring(prevKey) ~= tostring(curKey) then
        return "reenter"
    end
    return "none"
end

-- Extract the server INSTANCE SERIAL from a unit GUID. Pure.
-- Classic Era GUID layouts (public, documented game data):
--   Creature-0-<serverID>-<instanceID>-<zoneUID>-<npcID>-<spawnUID>
--   Cast-0-<serverID>-<instanceID>-<zoneUID>-<spellID>-<castUID>
-- Field 5 (<zoneUID>) is the serial: the id the server assigns to each distinct
-- instantiation of a map. Unit types other than Creature and Cast are ignored
-- (spec §2.1) — Player/Pet/Item GUIDs do not carry a usable serial.
-- Returns (serial:number, unitType:string) or nil.
function Instances.ParseGUIDSerial(guid)
    if type(guid) ~= "string" then return nil end
    local f, n = {}, 0
    for part in string.gmatch(guid, "([^%-]+)") do
        n = n + 1
        f[n] = part
        if n >= 6 then break end
    end
    if n < 5 then return nil end
    local utype = f[1]
    if utype ~= "Creature" and utype ~= "Cast" then return nil end
    local serial = tonumber(f[5])
    if not serial or serial <= 0 then return nil end
    return serial, utype
end

-- Append a new entry to a character's entries list, ring-capping to RING_CAP
-- (drops the oldest). Every entry is born NON-merged and counted; the serial
-- watcher may retroactively merge it (Instances.ApplySerial).
-- `extra` (optional) seeds the ADDITIVE detail fields captured at entry time
-- (enteredLevel, group, groupAvg) without widening the positional signature.
-- Returns (entry, count).
function Instances.RecordInto(entries, name, mapID, t, extra)
    entries = entries or {}
    local entry = {
        t = t, name = name, mapID = mapID,
        dur = 0, gold = 0, xp = 0, merged = false,
        goldLoot = 0,      -- loot-only copper (CHAT_MSG_MONEY); spec prefers this
        mobXP = 0,         -- kills that yielded XP
        mobKill = 0,       -- kills seen in the combat log (boosted grey runs)
    }
    if type(extra) == "table" then
        for k, v in pairs(extra) do
            if entry[k] == nil and v ~= nil then entry[k] = v end
        end
    end
    entries[#entries + 1] = entry
    while #entries > RING_CAP do table.remove(entries, 1) end   -- evict oldest (front)
    return entry, #entries
end

----------------------------------------------------------------------
-- PER-ENTRY DETAIL: group snapshot, entry level, trades (spec §3.4 / §8.2 / §9)
--
-- These are the fields the reference's per-run hover carries that our ledger did
-- not: the level the character walked in at, who was in the group and at what
-- levels (plus the running average), the kill-derived mob count, and any money
-- that changed hands in a trade completed while inside.
--
-- WIRE / STORAGE SHAPE. The group is stored as ONE compact string —
-- "*Artaeum:60|Bramble:58|Cera:57" (a leading "*" marks the character's own row)
-- — not as an array of tables. A 40-man raid snapshot as 40 nested tables, on 60
-- ring entries, on a payload that is LibSerialize'd and chunked at 230 bytes a
-- chunk, is a materially larger mesh frame for no added meaning; the string form
-- deflates almost to nothing across entries that share a roster. Decode is a
-- pure function (Instances.DecodeGroup) and everything downstream reads that.
--
-- All of these fields are OPTIONAL and ADDITIVE: absent on every pre-existing
-- entry, ignored by old peers, and invisible to Mesh.HashInstances (which hashes
-- only t / name / merged), so an old peer and a new peer still agree.
----------------------------------------------------------------------

local MAX_GROUP  = 40           -- a raid is the natural bound
local MAX_TRADES = 20           -- per entry; the reference trims its own log too
Instances.MAX_GROUP  = MAX_GROUP
Instances.MAX_TRADES = MAX_TRADES

-- members: { { name = "Cera", level = 57, isSelf = bool }, ... } -> compact string
-- (or nil when there is nothing worth storing). Pure.
function Instances.EncodeGroup(members)
    if type(members) ~= "table" then return nil end
    local parts = {}
    for i = 1, #members do
        local m = members[i]
        local nm = m and m.name
        if type(nm) == "string" and nm ~= "" and #parts < MAX_GROUP then
            nm = nm:gsub("[|:*]", "")                      -- separators are ours
            if nm ~= "" then
                local lvl = math.floor(tonumber(m.level) or 0)
                if lvl < 0 then lvl = 0 end
                -- ROUND-26 Part A.1: the member token grows an optional THIRD field, the
                -- class tag ("*Name:60:ROGUE"). Additive by construction — a two-field
                -- token still decodes, so historical rows and old peers are unaffected.
                -- The tag is sanitised the same way the name is; an absent/blank class
                -- simply emits the old two-field form rather than a trailing colon.
                local cls = m.classTag
                if type(cls) == "string" then cls = cls:gsub("[|:*]", "") else cls = nil end
                local tok = (m.isSelf and "*" or "") .. nm .. ":" .. lvl
                if cls and cls ~= "" then tok = tok .. ":" .. cls end
                parts[#parts + 1] = tok
            end
        end
    end
    if #parts == 0 then return nil end
    return table.concat(parts, "|")
end

-- The inverse. Always returns an array (empty for nil/garbage). Pure.
function Instances.DecodeGroup(str)
    local out = {}
    if type(str) ~= "string" or str == "" then return out end
    for part in string.gmatch(str, "([^|]+)") do
        -- ROUND-26: TOLERANT decode. Try the enriched three-field token first
        -- ("Name:60:ROGUE"), then fall back to the legacy two-field ("Name:60"), then to a
        -- bare name. Historical entries keep decoding exactly as before, just with a nil
        -- classTag — which is what marks them "legacy" for the roster-match fallback.
        local nm, lvl, cls = part:match("^(.-):(%d+):(%a+)$")
        if not nm then
            nm, lvl = part:match("^(.-):(%d+)$")
        end
        if not nm then nm, lvl = part, "0" end
        local isSelf = false
        if nm:sub(1, 1) == "*" then isSelf, nm = true, nm:sub(2) end
        if nm ~= "" then
            out[#out + 1] = { name = nm, level = tonumber(lvl) or 0, isSelf = isSelf,
                              classTag = cls }
        end
    end
    return out
end

-- Average group level INCLUDING the player (spec §3.4), to one decimal. Members
-- with no usable level are skipped rather than dragging the mean to zero. Pure.
function Instances.AverageGroupLevel(members)
    local sum, n = 0, 0
    for i = 1, #(members or {}) do
        local lvl = tonumber(members[i] and members[i].level) or 0
        if lvl > 0 then sum = sum + lvl; n = n + 1 end
    end
    if n == 0 then return nil end
    return math.floor((sum / n) * 10 + 0.5) / 10
end

-- PURE. Is this member reading a FACT or merely a reading? (NX-2, async lesson
-- Class 7 with a Class 6 flavour.) No character in this game is level 0 — a zero
-- is the client saying "that unit is not loaded yet", which on the far side of a
-- loading screen is the normal answer for `party2` for the first second or two.
-- Treating it as data is how "Bramble:0" with no class colour gets written into
-- a run's roster and stays there for the life of the entry.
function Instances.MemberProven(m)
    return (tonumber(m and m.level) or 0) > 0
end

-- PURE. Has a sample settled enough to stop asking? Every member proven, and at
-- least as many of them as the client says are in the group (a member whose unit
-- has not loaded is missing from the sample entirely, not merely cold).
function Instances.GroupSampleSettled(members, expected)
    members = members or {}
    expected = tonumber(expected) or 1
    if expected < 1 then expected = 1 end
    if expected > MAX_GROUP then expected = MAX_GROUP end
    if #members < expected then return false end
    for i = 1, #members do
        if not Instances.MemberProven(members[i]) then return false end
    end
    return true
end

-- UNION a fresh roster reading into the stored snapshot (spec §3.4: the roster is
-- re-read on GROUP_ROSTER_UPDATE, and "fields are only overwritten when the new
-- value is valid" — a member who has walked out of range must not blank the
-- level we already recorded). First-seen order is preserved; new names append.
-- Returns (encodedString, averageLevel, memberCount). Pure.
--
-- NX-2: a member carrying `unproven = true` is a READING, not a fact, and is
-- refused ADMISSION — it may still upgrade a member already in the list (that
-- path is upgrade-only and cannot damage anything), but it may not create one.
-- The flag is set by the live sampler alone: rows decoded from storage or from
-- another visit never carry it, so folding historical entries (`:458`,
-- `ui_instancespanel.lua:376`) keeps admitting every name it always did.
function Instances.UnionGroup(prevStr, members)
    local list = Instances.DecodeGroup(prevStr)
    local idx = {}
    for i = 1, #list do idx[list[i].name] = list[i] end
    for i = 1, #(members or {}) do
        local m = members[i]
        local nm = m and m.name
        if type(nm) == "string" and nm ~= "" then
            nm = nm:gsub("[|:*]", "")
            if nm ~= "" then
                local have = idx[nm]
                if have then
                    local lvl = math.floor(tonumber(m.level) or 0)
                    if lvl > 0 then have.level = lvl end      -- valid values only
                    if m.isSelf then have.isSelf = true end
                    -- ROUND-26: a later snapshot may know a class the first one did not
                    -- (unit not yet loaded at entry), so class UPGRADES nil -> known and is
                    -- never cleared back to nil by a subsequent class-less sample.
                    if type(m.classTag) == "string" and m.classTag ~= "" then
                        have.classTag = m.classTag
                    end
                elseif #list < MAX_GROUP and not m.unproven then
                    local rec = { name = nm, level = math.floor(tonumber(m.level) or 0),
                                  isSelf = m.isSelf and true or false,
                                  classTag = m.classTag }
                    list[#list + 1] = rec
                    idx[nm] = rec
                end
            end
        end
    end
    return Instances.EncodeGroup(list), Instances.AverageGroupLevel(list), #list
end

-- Append a MONEY trade to an entry's trade log (spec §9: gold given and received
-- per partner, located to the instance when it happened inside one). Item-only
-- trades carry no money and are deliberately not logged — the reference's own
-- hover reports coin. Returns the record, or nil when there was nothing to log.
-- Pure over the entry table.
function Instances.AppendTrade(entry, t, who, gave, got)
    if type(entry) ~= "table" then return nil end
    gave = math.floor(tonumber(gave) or 0)
    got  = math.floor(tonumber(got)  or 0)
    if gave < 0 then gave = 0 end
    if got  < 0 then got  = 0 end
    if gave == 0 and got == 0 then return nil end
    if type(who) ~= "string" or who == "" then who = "?" end
    local list = entry.trades
    if type(list) ~= "table" then list = {}; entry.trades = list end
    if #list >= MAX_TRADES then return nil end
    local rec = { t = t, who = who, gave = gave, got = got }
    list[#list + 1] = rec
    return rec
end

-- Apply an observed instance serial to a character's ledger. THE merge decision.
-- Pure; the caller supplies the entries list and the observed serial.
--   "merged"    -> the newest record was folded into the previous one (same live
--                  instance). Second return is the SURVIVING entry: the caller
--                  must continue the open run on it.
--   "committed" -> the serial was stamped on the newest record (a new instance).
--   "noop"      -> nothing usable to do (no record, or already stamped).
function Instances.ApplySerial(entries, serial, guid, source)
    if type(entries) ~= "table" then return "noop" end
    if type(serial) ~= "number" or serial <= 0 then return "noop" end
    local newest = entries[#entries]
    if type(newest) ~= "table" then return "noop" end
    -- One serial per entry: once stamped, later GUIDs are ignored (spec §2.1 —
    -- the watcher is one-shot, this is the belt to that braces).
    if (newest.serial or 0) > 0 then return "noop" end

    -- THE PREVIOUS RECORD = the nearest preceding NON-merged entry.
    --
    -- The reference DELETES a merged record, so its "second-newest" is always a
    -- live record. We keep merged records (flagged) so the mesh ledger hash input
    -- stays stable, which means the equivalent lookup has to step back over them.
    -- Taking entries[#entries-1] blindly broke the SECOND corpse run of a single
    -- instance: the slot in front of the new record was the FIRST corpse run's
    -- merged entry, `not prev.merged` failed, and the third visit committed its
    -- own serial as a brand-new record — a phantom slot on the meter and a third
    -- row in the register for one physical instance. Merged records only ever sit
    -- immediately behind their own survivor, so walking back over them lands on
    -- exactly the record the reference would have compared.
    local prev
    for i = #entries - 1, 1, -1 do
        local cand = entries[i]
        if type(cand) == "table" and not cand.merged then prev = cand; break end
    end
    if type(prev) == "table" and (prev.serial or 0) == serial then
        -- SAME LIVE INSTANCE: fold the new record's takings into the survivor.
        prev.goldLoot = (prev.goldLoot or 0) + (newest.goldLoot or 0)
        prev.xp       = (prev.xp or 0)       + (newest.xp or 0)
        prev.mobXP    = (prev.mobXP or 0)    + (newest.mobXP or 0)
        prev.mobKill  = (prev.mobKill or 0)  + (newest.mobKill or 0)
        -- ROUND-26: rep folds in like the other takings — a corpse run back into the same
        -- live instance is one run, so its rep belongs to the survivor's total.
        if newest.rep then prev.rep = (prev.rep or 0) + newest.rep end
        if newest.repBy then
            prev.repBy = prev.repBy or {}
            for who, amt in pairs(newest.repBy) do prev.repBy[who] = (prev.repBy[who] or 0) + amt end
        end
        -- Entry level / entry XP / entry money on the survivor are deliberately
        -- NOT overwritten (spec §2.4 — overwriting them was a bug there too).
        -- The GROUP is unioned rather than kept, though: someone who joined during
        -- the corpse run is genuinely part of this run's roster.
        if newest.group then
            local gstr, gavg = Instances.UnionGroup(prev.group, Instances.DecodeGroup(newest.group))
            if gstr then prev.group, prev.groupAvg = gstr, gavg end
        end
        -- Trades completed in either visit belong to the same physical run.
        if type(newest.trades) == "table" and #newest.trades > 0 then
            local dest = prev.trades
            if type(dest) ~= "table" then dest = {}; prev.trades = dest end
            for i = 1, #newest.trades do
                if #dest >= MAX_TRADES then break end
                dest[#dest + 1] = newest.trades[i]
            end
        end
        prev.prevSerial  = serial
        prev.mergeGUID   = guid
        prev.mergeSource = source
        newest.serial = serial
        newest.merged = true
        return "merged", prev
    end

    newest.serial = serial
    return "committed", newest
end

-- Duration of an entry, in seconds. Pure (spec §3.3).
--   primary   : exit epoch - entry epoch (survives reload / relog / crash);
--   secondary : the in-memory dur stamped at exit;
--   fallback  : now - entry, ONLY when that is under DUR_FALLBACK_MAX and the
--               run is not the currently-open one. Beyond the bound -> 0.
-- isOpen=true (this IS the live open run) always reports live elapsed.
function Instances.EntryDuration(entry, nowE, isOpen)
    if type(entry) ~= "table" then return 0 end
    local t = entry.t or 0
    nowE = nowE or t
    if isOpen then
        local live = nowE - t
        return (live > 0) and live or 0
    end
    local x = entry.exitT
    if type(x) == "number" and x > t then return x - t end
    local d = entry.dur or 0
    if d > 0 then return d end
    local elapsed = nowE - t
    if elapsed > 0 and elapsed < DUR_FALLBACK_MAX then return elapsed end
    return 0
end

-- First integer in an XP-gain chat line (spec §3.4). Level-up safe by
-- construction: this accumulates gains, it never differences a counter that
-- resets on a ding. Pure.
function Instances.ParseXPGain(text)
    if type(text) ~= "string" then return nil end
    local n = tonumber(text:match("(%d+)"))
    if not n or n <= 0 then return nil end
    return n
end

-- Build "(%d+)…" Lua patterns from Blizzard's localized money format strings,
-- falling back to enUS when the globals are absent (headless / early load).
local function fmtToPattern(fmt, fallback)
    if type(fmt) ~= "string" or not fmt:find("%%d") then fmt = fallback end
    local head, tail = fmt:match("^(.-)%%d(.*)$")
    if not head then return nil end
    local function esc(s) return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")) end
    return esc(head) .. "(%d+)" .. esc(tail)
end

local _moneyPats
function Instances.MoneyPatterns(reset)
    if _moneyPats and not reset then return _moneyPats end
    local G = _G or getfenv(0)
    _moneyPats = {
        gold   = fmtToPattern(G and G.GOLD_AMOUNT,   "%d Gold"),
        silver = fmtToPattern(G and G.SILVER_AMOUNT, "%d Silver"),
        copper = fmtToPattern(G and G.COPPER_AMOUNT, "%d Copper"),
    }
    return _moneyPats
end

-- Parse a CHAT_MSG_MONEY line into total copper (spec §3.4). Pure given patterns.
-- Returns nil when the line carries no coin at all.
function Instances.ParseMoneyCopper(text, pats)
    if type(text) ~= "string" then return nil end
    pats = pats or Instances.MoneyPatterns()
    local total, found = 0, false
    if pats.gold then
        local g = text:match(pats.gold)
        if g then total = total + tonumber(g) * 10000; found = true end
    end
    if pats.silver then
        local s = text:match(pats.silver)
        if s then total = total + tonumber(s) * 100; found = true end
    end
    if pats.copper then
        local c = text:match(pats.copper)
        if c then total = total + tonumber(c); found = true end
    end
    if not found then return nil end
    return total
end

-- Does this system message carry the server's "too many instances" transfer
-- abort? (spec §4.6 — the ONLY reconciliation point against server ground
-- truth.) `localized` is TRANSFER_ABORT_TOO_MANY_INSTANCES when available; the
-- lowercase substring is the locale-independent-enough backstop for enUS. Pure.
function Instances.IsTooManyInstancesMessage(text, localized)
    if type(text) ~= "string" or text == "" then return false end
    if type(localized) == "string" and localized ~= "" then
        if text == localized then return true end
        local head = localized:match("^(.-)%%") or localized
        if #head >= 12 and text:sub(1, #head) == head then return true end
    end
    return text:lower():find("too many instances", 1, true) ~= nil
end

-- Rolling-window cap counts for ONE account's character map. Pure.
--   charMap = { [nameRealm] = { entries = { {t,name,...,merged}, ... } }, ... }
-- Counts NON-merged entries whose age is strictly < HOUR / < DAY (an entry
-- exactly HOUR old has aged out — its slot has re-opened). nextHourSlotAt /
-- nextDaySlotAt are when the OLDEST in-window entry ages out (nil if none).
function Instances.AccountCounts(charMap, nowE)
    nowE = nowE or now()
    local hourCount, dayCount = 0, 0
    local oldestHourT, oldestDayT
    if type(charMap) == "table" then
        for _, crec in pairs(charMap) do
            local entries = crec and crec.entries
            if type(entries) == "table" then
                for i = 1, #entries do
                    local e = entries[i]
                    if e and not e.merged then
                        local t = e.t or 0
                        local age = nowE - t
                        if age >= 0 and age < DAY then
                            dayCount = dayCount + 1
                            if not oldestDayT or t < oldestDayT then oldestDayT = t end
                            if age < HOUR then
                                hourCount = hourCount + 1
                                if not oldestHourT or t < oldestHourT then oldestHourT = t end
                            end
                        end
                    end
                end
            end
        end
    end
    return {
        hour = hourCount,
        day  = dayCount,
        nextHourSlotAt = oldestHourT and (oldestHourT + HOUR) or nil,
        nextDaySlotAt  = oldestDayT and (oldestDayT + DAY) or nil,
    }
end

-- Reconcile a counts table against the server's own verdict. Pure.
-- When the server aborted a transfer with "too many instances" at capAt, we KNOW
-- the account was at the hourly cap at that moment — regardless of what our
-- ledger believes. Within the hour that follows, force the meter to cap state
-- rather than cheerfully reporting a slot we do not have. If our own ledger
-- already reads at-cap we trust its (more precise) slot time; only when the
-- ledger UNDER-counts do we fall back to capAt + HOUR as the conservative bound.
function Instances.ApplyServerCap(counts, capAt, nowE, hourlyCap)
    counts = counts or {}
    if type(capAt) ~= "number" or capAt <= 0 then return counts end
    hourlyCap = hourlyCap or Instances.HOURLY_CAP
    local age = (nowE or 0) - capAt
    if age < 0 or age >= HOUR then return counts end
    if (counts.hour or 0) < hourlyCap then
        counts.hour = hourlyCap
        counts.serverCapped = true
        counts.nextHourSlotAt = capAt + HOUR
    end
    return counts
end

-- Union-merge two entry lists, deduping by timestamp (t). Existing entries win
-- on a tie, EXCEPT that `merged` is unioned and absent optional fields are
-- filled from the inbound copy. Re-sorted ascending by t and ring-capped to
-- RING_CAP (keeps newest). Pure. Returns (mergedList, addedCount).
--
-- Why `merged` is unioned: an entry's merged flag is a ONE-WAY transition
-- (false -> true, the moment the serial watcher proves it was the same live
-- instance). If a peer sampled our ledger in the seconds before that flip, a
-- plain existing-wins tie would leave the two sides permanently disagreeing on
-- a field that IS part of the mesh instance-ledger hash — a permanent hash
-- mismatch, i.e. a sync request on every heartbeat forever. Unioning makes the
-- flag convergent: whichever side learns of the merge first wins, and both
-- sides settle on the same value.
function Instances.MergeEntryList(existing, incoming)
    existing = existing or {}
    incoming = incoming or {}
    local byT, out = {}, {}
    for i = 1, #existing do
        local e = existing[i]
        out[#out + 1] = e
        if e and e.t ~= nil then byT[e.t] = e end
    end
    local added = 0
    -- ROUND-26: `rep` / `repBy` join the additive optional fields — filled from an inbound
    -- copy when we lack them, never overwriting what we already hold.
    local FILL = { "serial", "prevSerial", "exitT", "goldLoot", "mobXP", "mobKill", "mapID",
                   "enteredLevel", "group", "groupAvg", "trades", "src", "rep", "repBy" }
    for i = 1, #incoming do
        local e = incoming[i]
        if e and e.t ~= nil then
            local have = byT[e.t]
            if not have then
                byT[e.t] = e
                out[#out + 1] = e
                added = added + 1
            else
                if e.merged then have.merged = true end
                for j = 1, #FILL do
                    local k = FILL[j]
                    if have[k] == nil and e[k] ~= nil then have[k] = e[k] end
                end
                if (have.dur or 0) == 0 and (e.dur or 0) > 0 then have.dur = e.dur end
            end
        end
    end
    table.sort(out, function(a, b) return (a.t or 0) < (b.t or 0) end)
    while #out > RING_CAP do table.remove(out, 1) end
    return out, added
end

----------------------------------------------------------------------
-- Public read API (the panel UI codes against these)
----------------------------------------------------------------------

-- The server's last "too many instances" abort epoch, if any (persisted so the
-- reconciliation survives a /reload inside the hour it covers).
local function serverCapAt()
    if Instances._serverCapAt then return Instances._serverCapAt end
    local db = Store and Store.GetSettings and Store.GetSettings()
    return db and tonumber(db.instancesServerCapAt) or nil
end

-- Rolling-window counts for a single account id.
function Instances.WindowCounts(aid, nowE)
    nowE = nowE or now()
    aid = aid or ""
    if aid == Instances.ORPHAN_AID then
        -- Unattributable imported runs never count against any meter.
        return { hour = 0, day = 0, orphan = true }
    end
    local all = Store and Store.data and Store.data.instances
    local charMap = all and all[aid]
    local counts = Instances.AccountCounts(charMap, nowE)
    local selfAID = (ns.GetAccountID and ns:GetAccountID()) or ""
    if aid == selfAID then
        Instances.ApplyServerCap(counts, serverCapAt(), nowE)
    end
    return counts
end

-- Cross-account view: per-account counts plus an aggregate total. This is the
-- net-new value the single-account reference never had. The orphan bucket is
-- excluded from BOTH the per-account map and the total — it has no cap identity.
--   -> { accounts = { [aid] = counts, ... }, total = { hour = n, day = n } }
function Instances.AllAccounts(nowE)
    nowE = nowE or now()
    local all = (Store and Store.data and Store.data.instances) or {}
    local selfAID = (ns.GetAccountID and ns:GetAccountID()) or ""
    local capAt = serverCapAt()
    local accounts, totH, totD = {}, 0, 0
    for aid, charMap in pairs(all) do
        if aid ~= Instances.ORPHAN_AID then
            local c = Instances.AccountCounts(charMap, nowE)
            if aid == selfAID then Instances.ApplyServerCap(c, capAt, nowE) end
            accounts[aid] = c
            totH = totH + c.hour
            totD = totD + c.day
        end
    end
    return { accounts = accounts, total = { hour = totH, day = totD } }
end

-- Merge an inbound account's instance ledger (arrives over the mesh). Self-immune
-- (never overwrites our OWN account's data from the wire) and dedups by
-- (nameRealm, t). Returns the number of entries added.
function Instances.MergeInbound(aid, incoming)
    if aid == nil then return 0 end
    if ns.GetAccountID and aid == ns:GetAccountID() then return 0 end   -- self-immune
    if type(incoming) ~= "table" then return 0 end
    local data = Store and Store.data
    if not data then return 0 end
    if type(data.instances) ~= "table" then data.instances = {} end
    local dest = data.instances[aid]
    if type(dest) ~= "table" then dest = {}; data.instances[aid] = dest end
    local added = 0
    for nameRealm, crec in pairs(incoming) do
        local inc = crec and crec.entries
        -- OWN-ACCOUNT AUTHORITY (store.lua). The account-level check above only
        -- catches a ledger ADDRESSED to our own account id; a peer relaying a
        -- ledger for one of OUR characters under ITS OWN aid slips past it, the
        -- same misattribution that let phantom character records in. Our own
        -- lockouts are ours to capture.
        if Store and Store.RejectInboundOwnCharacter
           and Store.RejectInboundOwnCharacter(nameRealm) then
            inc = nil
        end
        if type(inc) == "table" then
            local drec = dest[nameRealm]
            if type(drec) ~= "table" then drec = { entries = {} }; dest[nameRealm] = drec end
            local mergedList, n = Instances.MergeEntryList(drec.entries, inc)
            drec.entries = mergedList
            added = added + n
        end
    end
    -- Inbound mesh entries landed: repaint the panel (additive; no-op with no listener,
    -- and skipped when nothing changed so the merge self-tests stay quiet).
    if added > 0 and ns.Fire then ns:Fire("INSTANCES_CHANGED") end
    return added
end

----------------------------------------------------------------------
-- Live capture (impure — the transition state machine + sampling)
----------------------------------------------------------------------

Instances._inside     = false   -- were we inside an instance at the last check?
Instances._curKey     = nil     -- identity key of the instance we believe we are in
Instances._openKey    = nil     -- { aid, nameRealm } of the currently-open run
Instances._openSample = nil     -- { gold, entry, entries } captured at entry
Instances._serialArmed = false  -- one-shot serial watcher armed for this entry?
Instances._entryAt    = nil     -- server time of entry (combat-log suppression)
Instances._lastGroupSnap = nil  -- throttle stamp for the roster re-snapshot
Instances._trade      = nil     -- the trade window currently open, if any

-- Roster re-snapshots are throttled to once per 2 s (spec §3.4). The union means
-- a reading skipped by the throttle costs nothing: the next one still lands.
local GROUP_SNAP_THROTTLE = 2
Instances.GROUP_SNAP_THROTTLE = GROUP_SNAP_THROTTLE

-- NX-2: the post-entry re-sample ladder, in seconds after `_recordEntry`.
-- Bounded and then it stops — the same shape social.lua's login ladder uses for
-- an answer that may or may not arrive. Party unit data warms within a second or
-- two of a loading screen; UNIT_LEVEL and GROUP_ROSTER_UPDATE cover the rest.
Instances.GROUP_LADDER_AT = { 1, 3, 8 }

----------------------------------------------------------------------
-- THE WALLET  (NX-5, async lesson Class 7 / Class 4)
--
-- `GetMoney()` is sampled at entry and again at exit, and BOTH of those run on
-- the far side of a loading screen, where the wallet is one of the things that
-- reads cold. Nothing was subscribed to `PLAYER_MONEY`, so nothing ever
-- corrected a cold sample — and because the exit number is a DELTA, a cold zero
-- does not merely read low, it reads as a catastrophe: entry 500g, exit cold 0,
-- and the run is recorded as having cost the character 500 gold.
--
-- Two halves, per the lesson catalog's evidence-precedence shape:
--   1. PLAYER_MONEY (catalog 11509: Event.CurrencySystem.PlayerMoney) keeps a
--      LAST WARM figure. The event only fires in-world after the client has
--      rewritten the value, so what it hands us is warm by construction —
--      including a warm ZERO, which is what stops "spent everything" from being
--      mistaken for a cold read forever after.
--   2. A zero read while the last warm figure was positive is UNPROVEN. It
--      still yields a usable number (the warm one) so continuity is kept, but it
--      is flagged, and `_stampExit` refuses to write a delta built from an
--      unproven end. `e.goldLoot` — the loot accumulator — is the honest number
--      and the one any display should prefer (see the comment at the exit
--      stamp); the wallet delta is a backup, and a backup that lies is worse
--      than a backup that is absent.
----------------------------------------------------------------------

-- PURE. Returns value, proven.
--
-- The whole table, because a zero is the ambiguous case and every branch of it
-- matters:
--   live > 0                  -> proven. Only a populated wallet answers this.
--   live == 0, no warm figure -> UNPROVEN. Nothing has ever proved this wallet;
--                                absence of proof is not proof of an empty purse.
--   live == 0, warm figure 0  -> proven. PLAYER_MONEY told us zero, and a warm
--                                zero is the answer "you spent it all".
--   live == 0, warm figure >0 -> UNPROVEN, and answer with the WARM figure. This
--                                is the loading-screen read, and the reason the
--                                delta used to come out as minus-everything.
function Instances.ProvenGold(live, lastWarm)
    live = tonumber(live)
    if live == nil then return nil, false end        -- API absent / headless
    if live > 0 then return live, true end
    lastWarm = tonumber(lastWarm)
    if lastWarm == nil then return 0, false end
    if lastWarm > 0 then return lastWarm, false end
    return 0, true
end

-- Record a warm reading. Called from the PLAYER_MONEY handler (warm by
-- construction) and from every proven sample.
function Instances._noteWallet(v)
    v = tonumber(v)
    if v == nil then return end
    Instances._walletWarm = v
end

local function sampleGold()
    if not GetMoney then return nil, false end
    local v, proven = Instances.ProvenGold(GetMoney(), Instances._walletWarm)
    if proven then Instances._noteWallet(v) end
    return v, proven
end

local function sampleLevel()
    if not UnitLevel then return nil end
    local l = tonumber(UnitLevel("player"))
    if l and l > 0 then return l end
    return nil
end

-- Read the live group roster as { name, level, isSelf }. The player is always
-- member 1 (the average includes them, spec §3.4). Party tokens are party1..N-1
-- (the player is not among them); raid tokens are raid1..N and DO include the
-- player, so that one is filtered by identity. Returns nil headless.
local function readGroupMembers()
    if not UnitName then return nil end
    local selfName = UnitName("player")
    if type(selfName) ~= "string" or selfName == "" then return nil end
    -- ROUND-26 Part A.1: capture the CLASS TAG alongside name/level. UnitClass returns
    -- (localisedName, TAG) — we store the TAG (locale-independent, and what
    -- Dashboard.ClassColor keys on). Guarded so a headless/older client just omits it.
    local function classOf(unit)
        if not UnitClass then return nil end
        local _, tag = UnitClass(unit)
        return (type(tag) == "string" and tag ~= "") and tag or nil
    end
    local members = { { name = selfName, level = sampleLevel() or 0, isSelf = true,
                        classTag = classOf("player") } }
    local n = (GetNumGroupMembers and tonumber(GetNumGroupMembers())) or 0
    if n > 1 then
        local inRaid = (IsInRaid and IsInRaid()) and true or false
        local prefix = inRaid and "raid" or "party"
        local last = inRaid and n or (n - 1)
        if last > MAX_GROUP then last = MAX_GROUP end
        for i = 1, last do
            local unit = prefix .. i
            local nm = UnitName(unit)
            local isMe = inRaid and UnitIsUnit and UnitIsUnit(unit, "player")
            if type(nm) == "string" and nm ~= "" and not isMe then
                local m = { name = nm, level = (UnitLevel and tonumber(UnitLevel(unit))) or 0,
                            classTag = classOf(unit) }
                -- NX-2: mark, do not drop. UnionGroup refuses ADMISSION to an
                -- unproven member but still lets it upgrade one already stored,
                -- so a member who goes cold mid-run never blanks their own row.
                m.unproven = not Instances.MemberProven(m)
                members[#members + 1] = m
            end
        end
    end
    return members
end

-- Snapshot (and union into) the open run's group. Called once at entry (forced)
-- and on every GROUP_ROSTER_UPDATE while inside (throttled).
function Instances._snapshotGroup(force)
    local sample = Instances._openSample
    local e = sample and sample.entry
    if not e then return end
    local nowE = now()
    if not force and Instances._lastGroupSnap
        and (nowE - Instances._lastGroupSnap) < GROUP_SNAP_THROTTLE then return end
    Instances._lastGroupSnap = nowE
    local members = readGroupMembers()
    if not members then return end
    -- NX-2: has the roster stopped being a reading and become a fact? The ladder
    -- below stops the moment it has, so a warm group costs one extra sample.
    local expected = (GetNumGroupMembers and tonumber(GetNumGroupMembers())) or 1
    Instances._groupSettled = Instances.GroupSampleSettled(members, expected)
    local gstr, gavg = Instances.UnionGroup(e.group, members)
    if gstr then e.group, e.groupAvg = gstr, gavg end
    return gstr
end

-- NX-2: the bounded post-entry re-sample ladder. A STATIC group for a whole run
-- never fires another GROUP_ROSTER_UPDATE, so without this the cold entry
-- reading was the only reading the run ever got. Generation-stamped so a run
-- that closes (or a boundary straight into another instance) leaves no rung of
-- the previous ladder able to write into it.
function Instances._armGroupLadder()
    Instances._groupSettled  = false
    Instances._groupLadderGen = (Instances._groupLadderGen or 0) + 1
    local gen = Instances._groupLadderGen
    if not (_G.C_Timer and C_Timer.After) then return end
    for _, at in ipairs(Instances.GROUP_LADDER_AT) do
        C_Timer.After(at, function()
            if Instances._groupLadderGen ~= gen then return end  -- a later run owns us now
            if Instances._groupSettled then return end           -- proven; stop asking
            ns:SafeCall(Instances._snapshotGroup, true)
        end)
    end
end

-- Read the current instance identity from the live client. Returns
-- (name, instanceID, instanceType) or nil when not resolvable.
local function currentInstanceIdentity()
    if not GetInstanceInfo then return nil end
    local name, itype, _, _, _, _, _, instanceID = GetInstanceInfo()
    return name, instanceID, itype
end

-- ENTRY: a transition into a counted (dungeon/raid) instance.
function Instances._recordEntry()
    local name, instanceID, itype = currentInstanceIdentity()
    if not COUNTED_TYPES[itype or ""] then
        -- Not a slot-consuming instance (bg/arena/scenario/none): ignore.
        return
    end
    local aid = (ns.GetAccountID and ns:GetAccountID()) or ""
    local nameRealm = selfNameRealm()
    local t = now()
    local entries = charEntries(aid, nameRealm, true)
    -- ADDITIVE detail sampled at the moment of entry: the level the character
    -- walked in at (never overwritten later, spec §2.4 / §8.2).
    local entry = Instances.RecordInto(entries, name, instanceID, t,
        { enteredLevel = sampleLevel() })
    -- Open a run so exit can stamp duration + the wallet delta.
    local entryGold, entryGoldProven = sampleGold()
    Instances._openKey     = { aid = aid, nameRealm = nameRealm }
    Instances._openSample  = { gold = entryGold, goldProven = entryGoldProven,
                               entry = entry, entries = entries }
    Instances._entryAt     = t
    Instances._serialArmed = true   -- one-shot serial watcher (spec §2.1)
    -- Group snapshot at entry; GROUP_ROSTER_UPDATE keeps it current while inside
    -- — except that a static group never fires one, which is why the ladder
    -- exists (NX-2). The entry sample itself is the coldest reading of the run.
    Instances._lastGroupSnap = nil
    Instances._snapshotGroup(true)
    Instances._armGroupLadder()
    -- The entry is COUNTED immediately; the serial watcher may retroactively
    -- un-count it (spec §2.7).
    Instances._maybeWarn(aid, t)
    if ns.Fire then ns:Fire("INSTANCES_CHANGED") end
end

-- Stamp the exit sample onto an open run's entry. Shared by the real exit path
-- and the teardown path, and safe to call more than once (a later stamp wins).
function Instances._stampExit(sample, nowE)
    local e = sample and sample.entry
    if not e then return end
    e.exitT = nowE
    e.dur = math.max(0, nowE - (e.t or nowE))
    local goldNow, goldProven = sampleGold()
    if sample.gold ~= nil and goldNow ~= nil and goldProven and sample.goldProven ~= false then
        -- WALLET delta: includes repairs, vendor sales, reagents, mail. Kept as a
        -- backup; e.goldLoot (loot-only, accumulated live) is the honest number
        -- and is what any display should prefer (spec §3.4 / §8.2).
        e.gold = goldNow - sample.gold
    else
        -- NX-5: one end of the subtraction is an unproven (cold) wallet read, so
        -- the difference is not a number about this run. Leave `e.gold` exactly
        -- as it is — nil on a first stamp, or whatever a PROVEN earlier stamp
        -- wrote — and let goldLoot carry the answer. A later stamp with two warm
        -- ends still wins, which is how a teardown-then-real-exit sequence heals.
        Instances._goldRefusals = (Instances._goldRefusals or 0) + 1
    end
    -- XP is the CHAT ACCUMULATOR, never an entry/exit snapshot delta — that delta
    -- goes negative across a ding. Clamped for safety.
    e.xp = math.max(0, e.xp or 0)
end

-- EXIT: an inside->outside transition closes the open run with its stats.
function Instances._closeRun()
    local sample = Instances._openSample
    Instances._openKey, Instances._openSample = nil, nil
    Instances._serialArmed, Instances._entryAt = false, nil
    Instances._lastGroupSnap, Instances._trade = nil, nil
    -- NX-2: retire any ladder rung still in flight for the run being closed.
    Instances._groupLadderGen = (Instances._groupLadderGen or 0) + 1
    Instances._groupSettled = false
    if not (sample and sample.entry) then return end
    Instances._stampExit(sample, now())
    if ns.Fire then ns:Fire("INSTANCES_CHANGED") end
end

-- TEARDOWN (PLAYER_LEAVING_WORLD / PLAYER_LOGOUT): persist an exit epoch so a run
-- that spans a /reload, relog, logout or disconnect reports a REAL duration
-- instead of 0 forever. Deliberately does NOT clear the open-run state: if we
-- come straight back (a portal hop, a cancelled logout) the same entry continues
-- and its exit epoch is simply restamped. This mirrors the reference's
-- logout-countdown behaviour, which samples without clearing the inside marker,
-- and is why PLAYER_LEAVING_WORLD is not used to CLOSE a run here.
-- Registers its own handlers; tracker.lua's teardown latch is untouched.
function Instances._stampTeardown()
    local sample = Instances._openSample
    if not (sample and sample.entry) then return end
    Instances._stampExit(sample, now())
end

-- Chat warning (design §6). Setting-gated (DaseekiNexusDB.instancesWarnOnEntry,
-- default ON) — fires when the account's rolling-hour count first equals the
-- warn threshold. Plain copy per BRAND_SPEC.
function Instances._maybeWarn(aid, nowE)
    local db = Store and Store.GetSettings and Store.GetSettings()
    if db and db.instancesWarnOnEntry == false then return end   -- explicit opt-out
    local c = Instances.WindowCounts(aid, nowE)
    if c.hour == Instances.WARN_HOURLY and ns.Print then
        ns:Print(Instances.WARN_HOURLY .. " of " .. Instances.HOURLY_CAP .. " hourly instances used.")
    end
end

----------------------------------------------------------------------
-- Serial acquisition (the one-shot watchers)
----------------------------------------------------------------------

-- Combat-log sub-events that carry a usable creature source GUID (spec §2.1).
local CL_SERIAL_EVENTS = {
    SWING_DAMAGE = true, SPELL_DAMAGE = true, RANGE_DAMAGE = true,
}

-- Feed an observed GUID to the merge decision. Disarms the watcher on the first
-- usable serial, so the cost is one event per instance entry.
function Instances._observeSerial(guid, source)
    if not Instances._serialArmed then return end
    local sample = Instances._openSample
    if not (sample and sample.entries and sample.entry) then return end
    local serial = Instances.ParseGUIDSerial(guid)
    if not serial then return end
    Instances._serialArmed = false                       -- one-shot
    local result, survivor = Instances.ApplySerial(sample.entries, serial, guid, source)
    if result == "merged" and survivor then
        sample.entry = survivor   -- the open run continues on the survivor
    end
    if result ~= "noop" and ns.Fire then ns:Fire("INSTANCES_CHANGED") end
    return result
end

-- UNIT_SPELLCAST_START / _SUCCEEDED -> (unitTarget, castGUID, spellID).
-- The castGUID is a Cast-… GUID and carries the instance serial in field 5.
function Instances._onSpellcast(unitTarget, castGUID)
    Instances._observeSerial(castGUID, "cast")
end

-- True once the post-entry suppression window has elapsed. Guards every serial
-- source that can carry a stale unit across a loading screen.
local function pastSuppression()
    local entryAt = Instances._entryAt
    return not entryAt or (now() - entryAt) >= SERIAL_SUPPRESS
end

-- COMBAT_LOG_EVENT_UNFILTERED -> read via CombatLogGetCurrentEventInfo().
-- Two consumers now share the one read: the serial watcher (one-shot, suppressed
-- for 2 s after entry) and the KILL-DERIVED mob counter (spec §3.4 secondary).
function Instances._onCombatLog()
    if not CombatLogGetCurrentEventInfo then return end
    local _, subEvent, _, sourceGUID, _, _, _, destGUID = CombatLogGetCurrentEventInfo()
    if subEvent == "UNIT_DIED" then
        Instances._onUnitDied(destGUID)
        return
    end
    if not Instances._serialArmed then return end
    if not CL_SERIAL_EVENTS[subEvent or ""] then return end
    if not pastSuppression() then return end
    Instances._observeSerial(sourceGUID, "combatlog")
end

-- The SECONDARY mob counter (spec §3.4): a kill seen in the combat log, whether
-- or not it yielded XP. It exists precisely for the boosted run where every mob
-- is grey and the XP-derived count stays at zero; the display prefers the
-- XP-derived count whenever that is above zero.
--
-- SIMPLIFICATION (documented): the reference excludes a maintained list of
-- companion/critter NPC ids. We have no such list and will not invent one, so a
-- rat killed inside an instance counts here. It cannot skew the displayed number
-- on any run that yielded XP (the primary count wins), and on a boosted run the
-- error is a handful of critters against hundreds of kills.
function Instances._onUnitDied(destGUID)
    local sample = Instances._openSample
    local e = sample and sample.entry
    if not e then return end
    if type(destGUID) ~= "string" then return end
    if destGUID:sub(1, 9) ~= "Creature-" then return end   -- players/pets are not mobs
    e.mobKill = (e.mobKill or 0) + 1
end

-- UPDATE_MOUSEOVER_UNIT / PLAYER_TARGET_CHANGED -> UnitGUID("mouseover"/"target").
--
-- These are the CHEAPEST and, on the owner's own historical data, the MOST
-- PRODUCTIVE serial sources: across that file mouseover supplied the serial 208
-- times and target 5, against 195 from the combat log. A player who walks in and
-- simply moves the cursor over the first mob resolves the merge immediately --
-- well before anything casts or swings, which matters because the merge is
-- retroactive and the meter reads one too high until it fires.
--
-- Same Creature-GUID field-5 parsing, same one-shot latch, same post-entry
-- suppression: a unit still targeted or moused over from BEFORE the loading
-- screen would otherwise stamp the new record with the old instance's serial.
function Instances._onUnitSerial(unit)
    if not Instances._serialArmed then return end
    if not UnitGUID then return end
    if not pastSuppression() then return end
    Instances._observeSerial(UnitGUID(unit), unit)
end

----------------------------------------------------------------------
-- Continuous sampling while inside (spec §3.4)
----------------------------------------------------------------------

-- CHAT_MSG_COMBAT_XP_GAIN: the level-up-safe XP source. Also the primary mob
-- counter (a kill that yields XP).
function Instances._onXPGain(text)
    local sample = Instances._openSample
    local e = sample and sample.entry
    if not e then return end
    local gained = Instances.ParseXPGain(text)
    if not gained then return end
    e.xp = (e.xp or 0) + gained
    e.mobXP = (e.mobXP or 0) + 1
end

-- ROUND-26 Part A.2: REPUTATION for the run.
-- MODEL CHOICE (documented per the brief): NET rep accumulated from the faction-change
-- messages, not an enter-vs-exit sweep of every faction. Reasons: (a) it matches how gold
-- and xp are already captured in this file, so there is one accumulation model rather than
-- two; (b) an enter/exit sweep has to iterate the whole faction list twice per run and
-- still misses rep earned then partly lost within the run; (c) the message carries the
-- faction NAME, so a per-faction breakdown stays available later without a schema change.
-- Stored as a single compact total `e.rep` (net across factions) plus `e.repBy` (a
-- name -> amount map) — the tooltip renders the total and the map is there if the owner
-- later wants the breakdown. Both are additive and absent on historical rows.
-- The message is localised, so the pattern is built from Blizzard's own global strings the
-- same way the money patterns are, with a literal English fallback.
local _repPats
function Instances.RepPatterns(reset)
    if _repPats and not reset then return _repPats end
    local function pat(s, fallback)
        s = (type(s) == "string" and s ~= "") and s or fallback
        -- escape magic chars, then turn the %s / %d placeholders into captures
        s = s:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
        s = s:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
        return s
    end
    _repPats = {
        inc = pat(rawget(_G, "FACTION_STANDING_INCREASED"),
                  "Your reputation with %s has increased by %d."),
        dec = pat(rawget(_G, "FACTION_STANDING_DECREASED"),
                  "Your reputation with %s has decreased by %d."),
    }
    return _repPats
end

-- Parse a faction-change line into (factionName, delta) with delta SIGNED. Pure given
-- the patterns, so the whole thing is headless-testable.
function Instances.ParseRepChange(text, pats)
    if type(text) ~= "string" then return nil end
    pats = pats or Instances.RepPatterns()
    local who, amt = text:match(pats.inc)
    if who and amt then return who, tonumber(amt) or 0 end
    who, amt = text:match(pats.dec)
    if who and amt then return who, -(tonumber(amt) or 0) end
    return nil
end

function Instances._onRepChange(text)
    local sample = Instances._openSample
    local e = sample and sample.entry
    if not e then return end
    local who, delta = Instances.ParseRepChange(text)
    if not who or not delta or delta == 0 then return end
    e.rep = (e.rep or 0) + delta
    e.repBy = e.repBy or {}
    e.repBy[who] = (e.repBy[who] or 0) + delta
end

-- CHAT_MSG_MONEY: the loot-only coin accumulator. Spend-proof, unlike the wallet
-- delta, which is kept in parallel as e.gold.
function Instances._onMoney(text)
    local sample = Instances._openSample
    local e = sample and sample.entry
    if not e then return end
    local copper = Instances.ParseMoneyCopper(text)
    if not copper or copper <= 0 then return end
    e.goldLoot = (e.goldLoot or 0) + copper
end

----------------------------------------------------------------------
-- Trades completed while inside (spec §9 — coin given/received per partner,
-- located to the instance when the trade happened inside one)
--
-- THE MECHANISM. The trade window's money getters are only valid while the
-- window is open, and no event says "that trade went through". What the client
-- does give us is: TRADE_SHOW (window opened, partner is unit "NPC"),
-- TRADE_MONEY_CHANGED / PLAYER_TRADE_MONEY (either side moved coin),
-- TRADE_ACCEPT_UPDATE(playerAccepted, targetAccepted) and TRADE_CLOSED. So we
-- sample the coin on every money event, latch "both sides accepted" from
-- TRADE_ACCEPT_UPDATE — the last moment the getters are guaranteed readable —
-- and commit the record on TRADE_CLOSED. TRADE_REQUEST_CANCEL drops the window.
--
-- SIMPLIFICATIONS (deliberate, and the only ones):
--   * a both-accepted trade that the SERVER then refuses (a full bag on either
--     side is the realistic case) is still logged. There is no client-side event
--     that distinguishes it, and over-logging a trade the owner did attempt is
--     the benign direction of that error.
--   * ITEM-only trades are not logged at all. The hover reports coin, so an
--     item-for-item trade has nothing to show; AppendTrade drops a 0/0 record.
--   * only trades completed while a run is OPEN are logged, which is exactly the
--     "trades while inside" scoping the panel needs.
----------------------------------------------------------------------

local function tradePartner()
    if not UnitName then return nil end
    local nm = UnitName("NPC")
    if type(nm) == "string" and nm ~= "" then return nm end
    return nil
end

function Instances._onTradeShow()
    Instances._trade = { who = tradePartner(), gave = 0, got = 0, accepted = false }
end

function Instances._onTradeMoney()
    local tr = Instances._trade
    if not tr then return end
    if GetPlayerTradeMoney then tr.gave = tonumber(GetPlayerTradeMoney()) or tr.gave end
    if GetTargetTradeMoney then tr.got  = tonumber(GetTargetTradeMoney()) or tr.got end
    if not tr.who then tr.who = tradePartner() end
end

function Instances._onTradeAccept(playerAccepted, targetAccepted)
    local tr = Instances._trade
    if not tr then return end
    Instances._onTradeMoney()      -- resample: the getters are still valid here
    if tonumber(playerAccepted) == 1 and tonumber(targetAccepted) == 1 then
        tr.accepted = true
    end
end

function Instances._onTradeCancel()
    Instances._trade = nil
end

function Instances._onTradeClosed()
    local tr = Instances._trade
    Instances._trade = nil
    if not (tr and tr.accepted) then return end
    local sample = Instances._openSample
    local e = sample and sample.entry
    if not e then return end       -- not inside a run: nothing to attach it to
    local rec = Instances.AppendTrade(e, now(), tr.who, tr.gave, tr.got)
    if rec and ns.Fire then ns:Fire("INSTANCES_CHANGED") end
    return rec
end

----------------------------------------------------------------------
-- Server reconciliation (spec §4.6 — the only ground-truth check we get)
----------------------------------------------------------------------

-- Record that the SERVER refused an instance transfer because the account is at
-- the hourly cap. This outranks our ledger: whatever we believe, we now KNOW.
function Instances.NoteServerCap(t)
    t = t or now()
    Instances._serverCapAt = t
    local db = Store and Store.GetSettings and Store.GetSettings()
    if db then db.instancesServerCapAt = t end
    if ns.Fire then ns:Fire("INSTANCES_CHANGED") end
    return t
end

-- The reconciled lockout summary the owner reads after a refused transfer.
function Instances.ServerCapReport(nowE)
    nowE = nowE or now()
    local aid = (ns.GetAccountID and ns:GetAccountID()) or ""
    local c = Instances.WindowCounts(aid, nowE)
    local wait = c.nextHourSlotAt and math.max(0, c.nextHourSlotAt - nowE) or HOUR
    return string.format(
        "server refused the transfer: this account is at %d/%d for the hour (%d/%d today). Next slot in %dm %02ds.",
        c.hour or 0, Instances.HOURLY_CAP, c.day or 0, Instances.DAILY_CAP,
        math.floor(wait / 60), wait % 60)
end

function Instances._onSystemMessage(text)
    local G = _G or getfenv(0)
    local localized = G and G.TRANSFER_ABORT_TOO_MANY_INSTANCES
    if not Instances.IsTooManyInstancesMessage(text, localized) then return end
    Instances.NoteServerCap(now())
    -- Spec §4.6: the server's own counters settle a beat after the abort line.
    local function report() if ns.Print then ns:Print(Instances.ServerCapReport()) end end
    if C_Timer and C_Timer.After then C_Timer.After(0.2, function() ns:SafeCall(report) end)
    else report() end
end

----------------------------------------------------------------------
-- The transition driver
----------------------------------------------------------------------

-- Fired on PLAYER_ENTERING_WORLD. Reads IsInInstance + GetInstanceInfo and routes
-- entry / exit / reenter through the pure classifier.
--
-- ORDERING NOTE: Blizzard fires PLAYER_ENTERING_WORLD BEFORE
-- ZONE_CHANGED_NEW_AREA on a zone transition. Nothing in this module depends on
-- ZONE_CHANGED_NEW_AREA any more, so that ordering is now irrelevant — which is
-- exactly the bug the serial model retires.
function Instances.OnWorldChange()
    local isInside = (IsInInstance and IsInInstance()) and true or false
    local curKey = nil
    if isInside then
        local name, instanceID = currentInstanceIdentity()
        curKey = instanceID or name
    end
    local kind = Instances.ClassifyTransition(Instances._inside, isInside, Instances._curKey, curKey)
    if kind == "entry" then
        Instances._recordEntry()
    elseif kind == "exit" then
        Instances._closeRun()
    elseif kind == "reenter" then
        -- Instance -> instance (UBRS->BWL, in-instance portal, summoned from
        -- inside A into B): close the prior run FIRST so its duration and
        -- takings stop at the boundary, then open a fresh entry.
        Instances._closeRun()
        Instances._recordEntry()
    end
    Instances._inside = isInside
    Instances._curKey = curKey
end

----------------------------------------------------------------------
-- Event wiring (additive; drives off the existing LOGIN signal — no core edit)
--
-- Handlers live in one table so the self-tests can drive the EXACT functions the
-- event frame drives, in Blizzard's real firing order.
----------------------------------------------------------------------

Instances._Handlers = {
    PLAYER_ENTERING_WORLD    = function() Instances.OnWorldChange() end,
    PLAYER_LEAVING_WORLD     = function() Instances._stampTeardown() end,
    PLAYER_LOGOUT            = function() Instances._stampTeardown() end,
    UNIT_SPELLCAST_START     = function(unit, castGUID) Instances._onSpellcast(unit, castGUID) end,
    UNIT_SPELLCAST_SUCCEEDED = function(unit, castGUID) Instances._onSpellcast(unit, castGUID) end,
    COMBAT_LOG_EVENT_UNFILTERED = function() Instances._onCombatLog() end,
    UPDATE_MOUSEOVER_UNIT    = function() Instances._onUnitSerial("mouseover") end,
    PLAYER_TARGET_CHANGED    = function() Instances._onUnitSerial("target") end,
    CHAT_MSG_COMBAT_XP_GAIN  = function(text) Instances._onXPGain(text) end,
    CHAT_MSG_MONEY           = function(text) Instances._onMoney(text) end,
    CHAT_MSG_SYSTEM          = function(text) Instances._onSystemMessage(text) end,
    -- Per-entry detail (catalog: Event.PartyInfo.GroupRosterUpdate, Event.TradeInfo.*)
    GROUP_ROSTER_UPDATE      = function() Instances._snapshotGroup() end,
    -- NX-2: a party member's unit finishing its load (or dinging) is the settle
    -- signal for the roster read, and it is the ONLY one a static group produces.
    -- Throttled by _snapshotGroup itself, and inert while no run is open.
    -- Catalog 11509: Event.Unit.UnitLevel(unitTarget).
    UNIT_LEVEL               = function() Instances._snapshotGroup() end,
    -- NX-5: the wallet's settle signal. Warm by construction — the client has
    -- already rewritten the value by the time this fires — so it is the one
    -- reading allowed to teach `_walletWarm` a ZERO.
    -- Catalog 11509: Event.CurrencySystem.PlayerMoney.
    PLAYER_MONEY             = function()
        if GetMoney then Instances._noteWallet(GetMoney()) end
    end,
    TRADE_SHOW               = function() Instances._onTradeShow() end,
    TRADE_MONEY_CHANGED      = function() Instances._onTradeMoney() end,
    PLAYER_TRADE_MONEY       = function() Instances._onTradeMoney() end,
    TRADE_ACCEPT_UPDATE      = function(p, t) Instances._onTradeAccept(p, t) end,
    TRADE_REQUEST_CANCEL     = function() Instances._onTradeCancel() end,
    TRADE_CLOSED             = function() Instances._onTradeClosed() end,
    -- ROUND-26 Part A.2: reputation accrual for the open run.
    CHAT_MSG_COMBAT_FACTION_CHANGE = function(text) Instances._onRepChange(text) end,
}

function Instances.OnLogin()
    -- Seed inside-state so the very first PLAYER_ENTERING_WORLD (login or /reload
    -- inside an instance) classifies as "none" and creates no phantom entry.
    local isInside = (IsInInstance and IsInInstance()) and true or false
    Instances._inside = isInside
    if isInside then
        local name, instanceID = currentInstanceIdentity()
        Instances._curKey = instanceID or name
    end
    for event, fn in pairs(Instances._Handlers) do
        ns:RegisterEvent(event, function(_, ...) ns:SafeCall(fn, ...) end)
    end
end

----------------------------------------------------------------------
-- Diagnostic: /nexus debug instances
----------------------------------------------------------------------

local function debugInstances()
    local nowE = now()
    local all = (Store and Store.data and Store.data.instances) or {}
    local view = Instances.AllAccounts(nowE)
    ns:Print("instances — now=" .. nowE .. " (caps: "
        .. Instances.HOURLY_CAP .. "/hr, " .. Instances.DAILY_CAP .. "/day per account)")
    local capAt = serverCapAt()
    if capAt and (nowE - capAt) >= 0 and (nowE - capAt) < HOUR then
        ns:Print(string.format("  SERVER said 'too many instances' %ds ago — meter reconciled to cap.", nowE - capAt))
    end
    local anyAcct = false
    for aid, charMap in pairs(all) do
        anyAcct = true
        local isOrphan = (aid == Instances.ORPHAN_AID)
        local c = view.accounts[aid] or { hour = 0, day = 0 }
        local slotStr = ""
        if c.hour >= Instances.HOURLY_CAP and c.nextHourSlotAt then
            slotStr = string.format(" | next hourly slot at t=%d (%ds)",
                c.nextHourSlotAt, math.max(0, c.nextHourSlotAt - nowE))
        end
        if isOrphan then
            ns:Print("  ORPHAN bucket (imported runs with no known account — counts against NO meter)")
        else
            ns:Print(string.format("  acct %s: %d/%d hour, %d/%d day%s%s",
                (aid ~= "" and aid) or "<self/unset>",
                c.hour, Instances.HOURLY_CAP, c.day, Instances.DAILY_CAP, slotStr,
                c.serverCapped and " [server-reconciled]" or ""))
        end
        for nameRealm, crec in pairs(charMap) do
            local entries = (crec and crec.entries) or {}
            local shown = 0
            for i = #entries, 1, -1 do
                if shown >= 6 then break end
                shown = shown + 1
                local e = entries[i]
                ns:Print(string.format("     %s | %s | t=%d age=%ds dur=%ds loot=%d wallet=%d xp=%d serial=%s%s",
                    nameRealm, e.name or "?", e.t or 0, nowE - (e.t or nowE),
                    Instances.EntryDuration(e, nowE), e.goldLoot or 0, e.gold or 0, e.xp or 0,
                    tostring(e.serial or "-"), e.merged and " (merged)" or ""))
            end
        end
    end
    if not anyAcct then ns:Print("  (no instance entries recorded yet)") end
    ns:Print(string.format("  TOTAL across accounts: %d hour, %d day",
        view.total.hour, view.total.day))
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; registered as suite "instances")
----------------------------------------------------------------------

-- ── A scriptable stand-in for the live client. Overrides only the globals
--    instances.lua actually reads, drives Instances._Handlers directly (so the
--    tests exercise the SAME functions the event frame does), and restores
--    everything afterwards.
local function newSimClient()
    local sim = {
        clock = 100000,
        inside = false,
        name = nil, instanceID = nil, itype = nil,
        money = 0,
    }
    local G = _G or getfenv(0)
    local saved = {
        IsInInstance = G.IsInInstance, GetInstanceInfo = G.GetInstanceInfo,
        GetMoney = G.GetMoney, UnitName = G.UnitName, GetRealmName = G.GetRealmName,
        CombatLogGetCurrentEventInfo = G.CombatLogGetCurrentEventInfo,
        UnitGUID = G.UnitGUID, C_Timer = G.C_Timer,
        UnitLevel = G.UnitLevel, UnitIsUnit = G.UnitIsUnit,
        GetNumGroupMembers = G.GetNumGroupMembers, IsInRaid = G.IsInRaid,
        GetPlayerTradeMoney = G.GetPlayerTradeMoney, GetTargetTradeMoney = G.GetTargetTradeMoney,
    }
    local savedNow, savedData, savedGet = Store.Now, Store.data, ns.GetAccountID
    local savedDB = Store.db
    local savedState = {
        Instances._inside, Instances._curKey, Instances._openKey,
        Instances._openSample, Instances._serialArmed, Instances._entryAt,
        Instances._serverCapAt, Instances._lastGroupSnap, Instances._trade,
        -- NX-2 / NX-5 session state. `_walletWarm` in particular is module-wide
        -- and would otherwise leak a warm figure from one sim into the next,
        -- which is exactly the kind of cross-test contamination that makes a
        -- cold-read fixture pass for the wrong reason.
        Instances._walletWarm, Instances._groupLadderGen, Instances._groupSettled,
        Instances._goldRefusals,
    }

    -- Group roster the sim reports: { unitToken -> {name, level} } plus the player.
    sim.playerLevel = 58
    sim.party = {}         -- array of { name = , level = }
    sim.inRaid = false
    sim.tradeMoney = { player = 0, target = 0 }
    sim.tradePartner = "Bramble"

    G.IsInInstance = function() return sim.inside, sim.itype end
    G.GetInstanceInfo = function()
        return sim.name, sim.itype, 1, "Normal", 5, 0, false, sim.instanceID
    end
    G.GetMoney = function() return sim.money end
    G.UnitGUID = function(unit) return sim.unitGUID and sim.unitGUID[unit] or nil end
    G.UnitName = function(unit)
        if unit == "player" or unit == nil then return "Tester" end
        if unit == "NPC" then return sim.tradePartner end
        local i = tonumber(tostring(unit):match("(%d+)$"))
        local m = i and sim.party[i]
        return m and m.name or nil
    end
    G.UnitLevel = function(unit)
        if unit == "player" then return sim.playerLevel end
        local i = tonumber(tostring(unit):match("(%d+)$"))
        local m = i and sim.party[i]
        return m and m.level or 0
    end
    G.UnitIsUnit = function(a, b)
        if b ~= "player" then return false end
        local i = tonumber(tostring(a):match("(%d+)$"))
        local m = i and sim.party[i]
        return (m and m.name == "Tester") and true or false
    end
    G.GetNumGroupMembers = function()
        if #sim.party == 0 then return 0 end
        return sim.inRaid and #sim.party or (#sim.party + 1)
    end
    G.IsInRaid = function() return sim.inRaid end
    G.GetPlayerTradeMoney = function() return sim.tradeMoney.player end
    G.GetTargetTradeMoney = function() return sim.tradeMoney.target end
    G.GetRealmName = function() return "Sim Realm" end
    G.C_Timer = nil   -- print immediately in tests rather than deferring 0.2 s
    Store.Now = function() return sim.clock end
    Store.data = { instances = {} }
    -- Opt out of the entry chat warning: the sims deliberately drive the meter to
    -- its cap, and the warning is not what they are asserting on.
    Store.db = { instancesWarnOnEntry = false }
    ns.GetAccountID = function() return "1" end

    Instances._inside, Instances._curKey = false, nil
    Instances._openKey, Instances._openSample = nil, nil
    Instances._serialArmed, Instances._entryAt = false, nil
    Instances._serverCapAt = nil
    Instances._lastGroupSnap, Instances._trade = nil, nil
    Instances._walletWarm, Instances._groupSettled = nil, false
    Instances._goldRefusals = 0

    -- Fire an event exactly as core.lua's event frame would.
    function sim.fire(event, ...)
        local fn = Instances._Handlers[event]
        if fn then fn(...) end
    end
    -- Blizzard's REAL zone-transition order: PEW first, ZONE_CHANGED_NEW_AREA
    -- after. (The old implementation latched a merge-breaking flag on the second
    -- event and so could never merge; nothing consumes it now.)
    function sim.zoneTo(inside, name, instanceID, itype)
        sim.inside, sim.name, sim.instanceID, sim.itype = inside, name, instanceID, itype
        sim.fire("PLAYER_ENTERING_WORLD")
        sim.fire("ZONE_CHANGED_NEW_AREA")
    end
    function sim.enter(name, instanceID, itype) sim.zoneTo(true, name, instanceID, itype or "party") end
    function sim.leave() sim.zoneTo(false, nil, nil, "none") end
    sim.unitGUID = {}
    local function creatureGUID(serial, npcID)
        return ("Creature-0-3151-%d-%d-%d-000082EA3F"):format(sim.instanceID or 0, serial, npcID or 11583)
    end
    sim.creatureGUID = creatureGUID
    function sim.cast(serial)
        sim.fire("UNIT_SPELLCAST_SUCCEEDED", "boss1",
            ("Cast-0-3299-%d-%d-52057-000229B4B7"):format(sim.instanceID or 0, serial))
    end
    -- Move the cursor over a mob (the owner's most productive serial source).
    function sim.mouseover(serial, npcID)
        sim.unitGUID.mouseover = serial and creatureGUID(serial, npcID) or nil
        sim.fire("UPDATE_MOUSEOVER_UNIT")
    end
    function sim.target(serial, npcID)
        sim.unitGUID.target = serial and creatureGUID(serial, npcID) or nil
        sim.fire("PLAYER_TARGET_CHANGED")
    end
    -- Mouse over a party member: a Player GUID carries no usable serial.
    function sim.mouseoverPlayer()
        sim.unitGUID.mouseover = "Player-3299-0AB4C1D2"
        sim.fire("UPDATE_MOUSEOVER_UNIT")
    end
    function sim.combatLog(serial, subEvent)
        G.CombatLogGetCurrentEventInfo = function()
            return sim.clock, subEvent or "SWING_DAMAGE", false, creatureGUID(serial)
        end
        sim.fire("COMBAT_LOG_EVENT_UNFILTERED")
    end
    -- A mob (or, with a Player GUID, a group member) dies in the combat log.
    function sim.unitDied(guid)
        G.CombatLogGetCurrentEventInfo = function()
            return sim.clock, "UNIT_DIED", false, nil, nil, 0, 0,
                   guid or creatureGUID(4242, 11583)
        end
        sim.fire("COMBAT_LOG_EVENT_UNFILTERED")
    end
    -- Set the group roster (array of { name, level }) and fire the roster event.
    function sim.setGroup(members, inRaid)
        sim.party = members or {}
        sim.inRaid = inRaid and true or false
        sim.fire("GROUP_ROSTER_UPDATE")
    end
    -- A complete money trade: open, move coin, both accept, close.
    function sim.trade(who, gave, got, accept)
        sim.tradePartner = who
        sim.fire("TRADE_SHOW")
        sim.tradeMoney.player, sim.tradeMoney.target = gave or 0, got or 0
        sim.fire("TRADE_MONEY_CHANGED")
        sim.fire("TRADE_ACCEPT_UPDATE", accept == false and 0 or 1, accept == false and 0 or 1)
        sim.fire("TRADE_CLOSED")
    end
    function sim.entries()
        local acct = Store.data.instances["1"] or {}
        local crec = acct["Tester-SimRealm"]
        return (crec and crec.entries) or {}
    end
    function sim.counts() return Instances.WindowCounts("1", sim.clock) end
    function sim.restore()
        for k, v in pairs(saved) do G[k] = v end
        Store.Now, Store.data, ns.GetAccountID = savedNow, savedData, savedGet
        Store.db = savedDB
        Instances._inside, Instances._curKey = savedState[1], savedState[2]
        Instances._openKey, Instances._openSample = savedState[3], savedState[4]
        Instances._serialArmed, Instances._entryAt = savedState[5], savedState[6]
        Instances._serverCapAt = savedState[7]
        Instances._lastGroupSnap, Instances._trade = savedState[8], savedState[9]
        Instances._walletWarm, Instances._groupLadderGen = savedState[10], savedState[11]
        Instances._groupSettled, Instances._goldRefusals = savedState[12], savedState[13]
    end
    return sim
end

-- The transition classifier, including the instance->instance case.
local function testTransition(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Instances.ClassifyTransition(false, true)  == "entry", "outside->inside = entry")
    ck(Instances.ClassifyTransition(true,  false) == "exit",  "inside->outside = exit")
    ck(Instances.ClassifyTransition(true,  true)  == "none",  "inside->inside, no keys = none")
    ck(Instances.ClassifyTransition(false, false) == "none",  "outside->outside = none")
    ck(Instances.ClassifyTransition(true, true, 409, 409) == "none", "same instance key = none")
    ck(Instances.ClassifyTransition(true, true, 229, 469) == "reenter", "UBRS->BWL = reenter")
    ck(Instances.ClassifyTransition(true, true, nil, 469) == "none", "unknown prior key = none")
    ck(Instances.ClassifyTransition(true, true, "Molten Core", "Molten Core") == "none",
        "name keys compare by value")
end

-- GUID parsing: field 5 is the instance serial.
local function testGUIDSerial(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local s, ut = Instances.ParseGUIDSerial("Creature-0-3151-469-4821-11583-000082EA3F")
    ck(s == 4821 and ut == "Creature", "creature GUID -> field 5 serial (got " .. tostring(s) .. ")")
    local s2 = Instances.ParseGUIDSerial("Cast-0-3299-469-4821-52057-000229B4B7")
    ck(s2 == 4821, "cast GUID -> same serial for the same live instance")
    ck(Instances.ParseGUIDSerial("Player-3299-0AB4C1D2") == nil, "player GUID ignored")
    ck(Instances.ParseGUIDSerial("Pet-0-3299-469-4821-165-0102030405") == nil, "pet GUID ignored")
    ck(Instances.ParseGUIDSerial("Creature-0-3151-0-0-11583-0001") == nil, "serial 0 rejected")
    ck(Instances.ParseGUIDSerial("Creature-0-3151") == nil, "short GUID rejected")
    ck(Instances.ParseGUIDSerial(nil) == nil, "nil GUID rejected")
    ck(Instances.ParseGUIDSerial(12345) == nil, "non-string GUID rejected")
end

-- ApplySerial: the merge decision, in isolation.
local function testApplySerial(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local entries = {}
    Instances.RecordInto(entries, "Molten Core", 409, 1000)
    ck(Instances.ApplySerial(entries, 777, "g1", "cast") == "committed", "first entry commits its serial")
    ck(entries[1].serial == 777, "serial stamped on the entry")
    ck(Instances.ApplySerial(entries, 999, "g2", "cast") == "noop", "already-stamped entry ignores later GUIDs")
    ck(entries[1].serial == 777, "serial not overwritten")

    -- Corpse run back into the SAME live instance -> merged, no slot consumed.
    entries[1].goldLoot, entries[1].xp = 500, 100
    local e2 = select(1, Instances.RecordInto(entries, "Molten Core", 409, 1200))
    e2.goldLoot, e2.xp, e2.mobXP = 250, 40, 3
    local res, survivor = Instances.ApplySerial(entries, 777, "g3", "cast")
    ck(res == "merged", "same serial -> merged")
    ck(survivor == entries[1], "survivor is the PREVIOUS entry")
    ck(entries[2].merged == true, "re-entry flagged merged (consumes no slot)")
    ck(entries[1].goldLoot == 750 and entries[1].xp == 140 and entries[1].mobXP == 3,
        "takings folded into the survivor")
    ck(entries[1].t == 1000, "survivor's entry epoch is NOT overwritten")
    ck(entries[1].prevSerial == 777 and entries[1].mergeSource == "cast", "merge diagnostics stamped")

    -- Reset + rerun: same NAME, new serial -> NOT merged.
    Instances.RecordInto(entries, "Molten Core", 409, 1300)
    ck(Instances.ApplySerial(entries, 778, "g4", "cast") == "committed",
        "same name + NEW serial -> committed, not merged")
    ck(entries[3].merged == false, "reset-rerun burns its own slot")

    -- A merged entry is never a merge target (it is not the live run).
    ck(Instances.ApplySerial({}, 5) == "noop", "empty ledger -> noop")
    ck(Instances.ApplySerial(entries, 0) == "noop", "serial 0 -> noop")
end

-- THE headline: real Blizzard event ordering, real handlers, real ledger.
local function testLiveSerialMerge(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local sim = newSimClient()
    local ok, err = pcall(function()
        -- 1. Walk into Deadmines. PEW then ZONE_CHANGED_NEW_AREA — the REAL order.
        sim.enter("The Deadmines", 36)
        ck(#sim.entries() == 1, "entry recorded on zone-in (got " .. #sim.entries() .. ")")
        ck(sim.counts().hour == 1, "1 slot counted immediately")
        sim.clock = sim.clock + 30
        sim.cast(5501)                       -- first mob casts: serial observed
        ck(sim.entries()[1].serial == 5501, "serial captured from the first cast")
        ck(sim.counts().hour == 1, "still 1 slot after the serial commits")

        -- 2. Wipe, run out to the graveyard (a WORLD ZONE change), corpse-run back
        --    into the SAME live instance. Old rule: broken by the zone change.
        sim.clock = sim.clock + 300
        sim.leave()
        ck(sim.entries()[1].exitT ~= nil, "exit epoch stamped on the way out")
        sim.clock = sim.clock + 240
        sim.enter("The Deadmines", 36)
        ck(#sim.entries() == 2, "the corpse-run re-entry is recorded")
        ck(sim.counts().hour == 2, "…and counted, until the serial proves otherwise")
        sim.clock = sim.clock + 5
        sim.cast(5501)                       -- SAME live instance
        ck(sim.entries()[2].merged == true, "corpse run merged: NO new slot")
        ck(sim.counts().hour == 1, "hour meter back to 1 (got " .. sim.counts().hour .. ")")

        -- 3. Clear it, step out, /reset, walk straight back in. Same name, same
        --    outdoor zone, minutes apart — the exact farm loop the 30-minute
        --    window used to swallow. New serial -> a real slot.
        sim.clock = sim.clock + 600
        sim.leave()
        sim.clock = sim.clock + 60
        sim.enter("The Deadmines", 36)
        sim.clock = sim.clock + 10
        sim.cast(5502)                       -- reset created a NEW instance
        ck(sim.entries()[3].merged == false, "reset+rerun is NOT merged")
        ck(sim.counts().hour == 2, "farm rerun burns a slot (got " .. sim.counts().hour .. ")")

        -- 4. Five reset-reruns in a row all count — the meter must not under-read.
        for i = 1, 3 do
            sim.clock = sim.clock + 300
            sim.leave()
            sim.clock = sim.clock + 60
            sim.enter("The Deadmines", 36)
            sim.clock = sim.clock + 10
            sim.cast(5502 + i)
        end
        ck(sim.counts().hour == 5, "five distinct farm runs = 5/5 (got " .. sim.counts().hour .. ")")
    end)
    sim.restore()
    if not ok then fails[#fails + 1] = "live serial merge sim errored: " .. tostring(err) end
end

-- Mouseover / target / combat-log serial sources. On the owner's own historical
-- data mouseover supplied the serial 208 times and target 5, against 195 from the
-- combat log -- so these are the sources that actually resolve the merge in play.
local function testUnitSerialSources(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- 1. Mouseover alone resolves a corpse-run merge: no cast, no combat.
    local sim = newSimClient()
    local ok, err = pcall(function()
        sim.enter("Scarlet Monastery", 189)
        sim.clock = sim.clock + 5           -- past the 2 s suppression window
        sim.mouseover(6100)
        ck(sim.entries()[1].serial == 6100, "mouseover stamps the serial")
        ck(sim.entries()[1].mergeSource == nil, "first entry commits, does not merge")
        sim.clock = sim.clock + 400
        sim.leave()
        sim.clock = sim.clock + 120
        sim.enter("Scarlet Monastery", 189)  -- corpse run back into the SAME instance
        ck(sim.counts().hour == 2, "re-entry counted until a serial proves otherwise")
        sim.clock = sim.clock + 5
        sim.mouseover(6100)
        ck(sim.entries()[2].merged == true, "mouseover alone merges the corpse run")
        ck(sim.counts().hour == 1, "no slot consumed (got " .. sim.counts().hour .. ")")
        ck(sim.entries()[1].mergeSource == "mouseover", "merge source recorded as mouseover")
    end)
    sim.restore()
    if not ok then fails[#fails + 1] = "mouseover sim errored: " .. tostring(err) end

    -- 2. Target works the same way, and a reset+rerun still bills a slot.
    local sim2 = newSimClient()
    local ok2, err2 = pcall(function()
        sim2.enter("Stratholme", 329)
        sim2.clock = sim2.clock + 5
        sim2.target(7100)
        ck(sim2.entries()[1].serial == 7100, "target stamps the serial")
        sim2.clock = sim2.clock + 600
        sim2.leave()
        sim2.clock = sim2.clock + 60
        sim2.enter("Stratholme", 329)
        sim2.clock = sim2.clock + 5
        sim2.target(7101)                    -- /reset made a NEW instance
        ck(sim2.entries()[2].merged == false, "target: reset+rerun is NOT merged")
        ck(sim2.counts().hour == 2, "target: farm rerun burns a slot")
    end)
    sim2.restore()
    if not ok2 then fails[#fails + 1] = "target sim errored: " .. tostring(err2) end

    -- 3. Suppression + rejection rules.
    local sim3 = newSimClient()
    local ok3, err3 = pcall(function()
        sim3.enter("Blackrock Depths", 230)
        -- Still inside the 2 s window: a unit held over from before the loading
        -- screen must NOT stamp the new record.
        sim3.clock = sim3.clock + 1
        sim3.mouseover(999)
        ck(sim3.entries()[1].serial == nil, "stale mouseover suppressed for 2 s after entry")
        sim3.target(999)
        ck(sim3.entries()[1].serial == nil, "stale target suppressed for 2 s after entry")
        sim3.combatLog(999)
        ck(sim3.entries()[1].serial == nil, "stale combat log suppressed for 2 s after entry")
        -- Past the window, a PLAYER GUID still carries nothing usable.
        sim3.clock = sim3.clock + 5
        sim3.mouseoverPlayer()
        ck(sim3.entries()[1].serial == nil, "a party member's Player GUID is ignored")
        ck(Instances._serialArmed == true, "…and the watcher stays armed for a real mob")
        -- An empty mouseover (cursor over nothing) is a no-op.
        sim3.mouseover(nil)
        ck(sim3.entries()[1].serial == nil, "empty mouseover is a no-op")
        ck(Instances._serialArmed == true, "…and does not disarm the watcher")
        -- The real thing lands.
        sim3.mouseover(8200)
        ck(sim3.entries()[1].serial == 8200, "a real creature GUID past the window commits")
        ck(Instances._serialArmed == false, "watcher disarms after the first usable serial")
        -- One-shot: later sources cannot overwrite it.
        sim3.target(8299)
        sim3.combatLog(8299)
        ck(sim3.entries()[1].serial == 8200, "one-shot: later sources cannot overwrite the serial")
    end)
    sim3.restore()
    if not ok3 then fails[#fails + 1] = "suppression sim errored: " .. tostring(err3) end

    -- 4. The combat-log path still works, and only on damage sub-events.
    local sim4 = newSimClient()
    local ok4, err4 = pcall(function()
        sim4.enter("Zul'Gurub", 309)
        sim4.clock = sim4.clock + 5
        sim4.combatLog(5000, "SPELL_AURA_APPLIED")     -- not a damage event
        ck(sim4.entries()[1].serial == nil, "combat log ignores non-damage sub-events")
        sim4.combatLog(5000, "SPELL_DAMAGE")
        ck(sim4.entries()[1].serial == 5000, "combat log commits on a damage sub-event")
    end)
    sim4.restore()
    if not ok4 then fails[#fails + 1] = "combat-log sim errored: " .. tostring(err4) end
end

-- Instance -> instance zoning closes the prior run and opens a new one.
local function testInstanceToInstance(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local sim = newSimClient()
    local ok, err = pcall(function()
        sim.money = 100000
        sim.enter("Blackrock Spire", 229)
        sim.clock = sim.clock + 20
        sim.cast(900)
        sim.fire("CHAT_MSG_MONEY", "You loot 3 Gold, 20 Silver, 5 Copper")
        sim.fire("CHAT_MSG_COMBAT_XP_GAIN", "Rockhide dies, you gain 500 experience.")
        sim.clock = sim.clock + 1800
        sim.money = 140000
        -- Portal straight into Blackwing Lair without ever going outside.
        sim.enter("Blackwing Lair", 469)
        local e = sim.entries()
        ck(#e == 2, "instance->instance records a SECOND entry (got " .. #e .. ")")
        ck(sim.counts().hour == 2, "…and it counts as its own slot")
        ck(e[1].exitT ~= nil and e[1].dur == 1820, "prior run closed AT the boundary (got " .. tostring(e[1].dur) .. ")")
        ck(e[1].goldLoot == 32005, "prior run keeps its own loot")
        ck(e[1].xp == 500, "prior run keeps its own xp")
        ck((e[2].goldLoot or 0) == 0 and (e[2].xp or 0) == 0, "new run starts clean — no contamination")
        ck(e[1].gold == 40000, "prior run's wallet delta stops at the boundary")

        -- Takings after the boundary land on the NEW entry only.
        sim.clock = sim.clock + 60
        sim.cast(901)
        sim.fire("CHAT_MSG_COMBAT_XP_GAIN", "Razorgore dies, you gain 1200 experience.")
        ck(sim.entries()[1].xp == 500, "old entry untouched after the boundary")
        ck(sim.entries()[2].xp == 1200, "new entry accumulates its own xp")
    end)
    sim.restore()
    if not ok then fails[#fails + 1] = "instance->instance sim errored: " .. tostring(err) end
end

-- XP accumulator survives a level-up; gold carries BOTH semantics.
local function testXPAndGold(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Instances.ParseXPGain("Defias Pillager dies, you gain 425 experience.") == 425, "xp: first integer")
    ck(Instances.ParseXPGain("You gain 425 experience. (+212 exp Rested bonus)") == 425, "xp: base amount, not the bonus")
    ck(Instances.ParseXPGain("You have slain a foe.") == nil, "xp: no integer -> nil")
    ck(Instances.ParseXPGain(nil) == nil, "xp: nil text -> nil")

    local P = { gold = "(%d+) Gold", silver = "(%d+) Silver", copper = "(%d+) Copper" }
    ck(Instances.ParseMoneyCopper("You loot 1 Gold, 20 Silver, 5 Copper", P) == 12005, "money: g+s+c")
    ck(Instances.ParseMoneyCopper("You loot 47 Copper", P) == 47, "money: copper only")
    ck(Instances.ParseMoneyCopper("You receive loot: item", P) == nil, "money: no coin -> nil")
    -- The default (global-derived or enUS-fallback) patterns must work too.
    ck(Instances.ParseMoneyCopper("You loot 2 Gold, 3 Silver, 4 Copper") == 20304, "money: default patterns")

    local sim = newSimClient()
    local ok, err = pcall(function()
        sim.money = 500000
        sim.enter("Scholomance", 289)
        sim.clock = sim.clock + 10
        sim.cast(4242)
        -- Grind to a DING. The raw UnitXP delta would go NEGATIVE here; the chat
        -- accumulator cannot.
        sim.fire("CHAT_MSG_COMBAT_XP_GAIN", "Risen Guard dies, you gain 3000 experience.")
        sim.fire("CHAT_MSG_COMBAT_XP_GAIN", "Risen Guard dies, you gain 3000 experience.")
        sim.fire("CHAT_MSG_COMBAT_XP_GAIN", "You gain 4000 experience.")     -- the ding
        sim.fire("CHAT_MSG_COMBAT_XP_GAIN", "Risen Guard dies, you gain 2500 experience.")
        sim.fire("CHAT_MSG_MONEY", "You loot 5 Gold, 50 Silver, 10 Copper")
        sim.clock = sim.clock + 900
        sim.money = 470000            -- net LOSS on the wallet: repaired mid-run
        sim.leave()
        local e = sim.entries()[1]
        ck(e.xp == 12500, "xp accumulator sums across the level-up (got " .. tostring(e.xp) .. ")")
        ck(e.xp >= 0, "xp is never negative")
        ck(e.mobXP == 4, "xp-derived mob count")
        ck(e.goldLoot == 55010, "loot-only coin accumulated (got " .. tostring(e.goldLoot) .. ")")
        ck(e.gold == -30000, "wallet delta kept in parallel, negative after a repair")
    end)
    sim.restore()
    if not ok then fails[#fails + 1] = "xp/gold sim errored: " .. tostring(err) end
end

-- Exit epoch persists across a teardown, so duration survives relog / DC.
local function testExitEpochPersistence(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- Pure duration semantics first.
    ck(Instances.EntryDuration({ t = 100, exitT = 400 }, 9999) == 300, "duration from the exit epoch")
    ck(Instances.EntryDuration({ t = 100, dur = 250 }, 9999) == 250, "falls back to the stamped dur")
    ck(Instances.EntryDuration({ t = 100 }, 1000) == 900, "bounded now-entry fallback")
    ck(Instances.EntryDuration({ t = 100 }, 100 + DUR_FALLBACK_MAX + 1) == 0, "beyond 6h -> 0")
    ck(Instances.EntryDuration({ t = 100 }, 900, true) == 800, "the open run reports live elapsed")
    ck(Instances.EntryDuration(nil, 500) == 0, "nil entry -> 0")

    local sim = newSimClient()
    local ok, err = pcall(function()
        sim.enter("Stratholme", 329)
        sim.clock = sim.clock + 15
        sim.cast(7000)
        sim.clock = sim.clock + 1200
        -- Disconnect / logout INSIDE. The old build stamped nothing here, so the
        -- run reported 0s forever.
        sim.fire("PLAYER_LEAVING_WORLD")
        local e = sim.entries()[1]
        ck(e.exitT == sim.clock, "teardown stamps a real exit epoch")
        ck(Instances.EntryDuration(e, sim.clock + 99999) == 1215, "duration survives the relog (got "
            .. Instances.EntryDuration(e, sim.clock + 99999) .. ")")
        -- Coming straight back continues the SAME entry (no phantom slot).
        sim.clock = sim.clock + 40
        sim.fire("CHAT_MSG_COMBAT_XP_GAIN", "Patchwork Golem dies, you gain 900 experience.")
        ck(sim.entries()[1].xp == 900, "the open run continues after a teardown stamp")
        ck(#sim.entries() == 1, "teardown creates no extra entry")
        sim.clock = sim.clock + 10
        sim.leave()
        ck(sim.entries()[1].exitT == sim.clock, "the real exit restamps the epoch")
        ck(sim.counts().hour == 1, "still exactly one slot")
    end)
    sim.restore()
    if not ok then fails[#fails + 1] = "exit-epoch sim errored: " .. tostring(err) end
end

-- Server "too many instances" reconciliation.
local function testServerCapReconciliation(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    ck(Instances.IsTooManyInstancesMessage("You have entered too many instances recently.") == true,
        "enUS transfer-abort matched")
    ck(Instances.IsTooManyInstancesMessage("You have entered too many instances recently.",
        "You have entered too many instances recently.") == true, "localized exact match")
    ck(Instances.IsTooManyInstancesMessage("Zu viele Instanzen betreten.",
        "Zu viele Instanzen betreten.") == true, "localized non-English match")
    ck(Instances.IsTooManyInstancesMessage("You have been saved to this instance.") == false,
        "unrelated system line ignored")
    ck(Instances.IsTooManyInstancesMessage(nil) == false, "nil text -> false")

    local T = 500000
    local c = Instances.ApplyServerCap({ hour = 2, day = 6 }, T - 100, T)
    ck(c.hour == 5 and c.serverCapped == true, "under-counting ledger forced to cap")
    ck(c.nextHourSlotAt == (T - 100) + HOUR, "conservative next-slot bound from the abort")
    local c2 = Instances.ApplyServerCap({ hour = 5, day = 9, nextHourSlotAt = T + 120 }, T - 100, T)
    ck(c2.hour == 5 and c2.serverCapped == nil, "already-at-cap ledger is left alone")
    ck(c2.nextHourSlotAt == T + 120, "…and keeps its own, more precise slot time")
    local c3 = Instances.ApplyServerCap({ hour = 1, day = 1 }, T - HOUR - 1, T)
    ck(c3.hour == 1, "an abort older than an hour no longer applies")
    local c4 = Instances.ApplyServerCap({ hour = 1, day = 1 }, nil, T)
    ck(c4.hour == 1, "no abort recorded -> untouched")

    local sim = newSimClient()
    local ok, err = pcall(function()
        sim.enter("Scarlet Monastery", 189)
        sim.clock = sim.clock + 10
        sim.cast(3300)
        sim.clock = sim.clock + 300
        sim.leave()
        ck(sim.counts().hour == 1, "our ledger believes 1/5")
        -- The server disagrees: it refuses the next transfer.
        sim.fire("CHAT_MSG_SYSTEM", "You have entered too many instances recently.")
        local rc = sim.counts()
        ck(rc.hour == Instances.HOURLY_CAP, "meter reconciled to cap on the server's word")
        ck(rc.serverCapped == true, "counts flagged server-reconciled")
        ck(Instances.ServerCapReport(sim.clock):find("5/5") ~= nil, "report states the cap")
        -- An hour later the reconciliation lapses.
        sim.clock = sim.clock + HOUR + 1
        ck(sim.counts().hour == 0, "reconciliation expires with its own hour")
    end)
    sim.restore()
    if not ok then fails[#fails + 1] = "server-cap sim errored: " .. tostring(err) end
end

-- Rolling-window counts incl. boundary aging + merged exclusion.
local function testWindowCounts(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local T = 1000000
    local charMap = {
        ["A-R"] = { entries = {
            { t = T - 10,        name = "MC", merged = false },  -- in hour + day
            { t = T - (HOUR - 1), name = "MC", merged = false }, -- in hour (age 3599 < 3600)
            { t = T - HOUR,      name = "MC", merged = false },  -- aged out of hour, in day
            { t = T - 100,       name = "MC", merged = true  },  -- merged: never counts
            { t = T - (DAY + 5), name = "MC", merged = false }, -- aged out of day
        } },
    }
    local c = Instances.AccountCounts(charMap, T)
    ck(c.hour == 2, "hour count excludes the exactly-HOUR-old + merged + day-only (got " .. c.hour .. ")")
    ck(c.day == 3, "day count excludes merged + >24h (got " .. c.day .. ")")
    ck(c.nextHourSlotAt == (T - (HOUR - 1)) + HOUR, "nextHourSlotAt = oldest in-window + HOUR")
    ck(c.nextDaySlotAt == (T - HOUR) + DAY, "nextDaySlotAt = oldest in-day + DAY")
    local e = Instances.AccountCounts({}, T)
    ck(e.hour == 0 and e.day == 0 and e.nextHourSlotAt == nil, "empty account -> zero counts, no slot time")
    local c2 = Instances.AccountCounts(charMap, (T - (HOUR - 1)) + HOUR)
    ck(c2.hour < c.hour, "count decreases once the oldest ages out at nextHourSlotAt")

    -- Day meter at its cap (nothing in the reference validates a 30/day rule).
    local dayMap = { ["D-R"] = { entries = {} } }
    for i = 1, Instances.DAILY_CAP do
        dayMap["D-R"].entries[i] = { t = T - (DAY - 60 - i * 100), name = "SM", merged = false }
    end
    local dc = Instances.AccountCounts(dayMap, T)
    ck(dc.day == Instances.DAILY_CAP, "day meter reaches the cap (got " .. dc.day .. ")")
    ck(dc.nextDaySlotAt ~= nil and dc.nextDaySlotAt > T, "…and produces a future day-slot time")
end

-- Ring capping at RING_CAP.
local function testRingCap(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local entries = {}
    for i = 1, RING_CAP + 15 do
        Instances.RecordInto(entries, "Zone" .. i, i, 5000 + i * 100)
    end
    ck(#entries == RING_CAP, "ring holds at most RING_CAP (" .. #entries .. ")")
    ck(entries[#entries].name == "Zone" .. (RING_CAP + 15), "newest entry retained")
    ck(entries[1].name == "Zone" .. 16, "oldest 15 evicted (front-first)")
    local e1 = entries[1]
    ck(e1.dur == 0 and e1.gold == 0 and e1.goldLoot == 0 and e1.merged == false,
        "new entry stats default to 0 / non-merged")
end

-- Cross-account aggregation + the orphan bucket's exclusion.
local function testCrossAccount(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local saved, savedGet = Store.data, ns.GetAccountID
    ns.GetAccountID = function() return "1" end
    local T = 2000000
    Store.data = { instances = {
        ["1"] = { ["A-R"] = { entries = {
            { t = T - 10, name = "MC", merged = false },
            { t = T - 20, name = "MC", merged = false },
        } } },
        ["2"] = { ["B-R"] = { entries = {
            { t = T - 30, name = "BWL", merged = false },
        } }, ["C-R"] = { entries = {
            { t = T - 40, name = "ZG", merged = false },
            { t = T - 50, name = "ZG", merged = true },   -- merged: not counted
        } } },
        [Instances.ORPHAN_AID] = { ["Z-R"] = { entries = {
            { t = T - 60, name = "SM", merged = false },
            { t = T - 70, name = "SM", merged = false },
        } } },
    } }
    local one = Instances.WindowCounts("1", T)
    ck(one.hour == 2, "account 1 has 2 in the hour")
    local view = Instances.AllAccounts(T)
    ck(view.accounts["1"].hour == 2, "cross view: acct 1 hour = 2")
    ck(view.accounts["2"].hour == 2, "cross view: acct 2 hour = 2 (merged excluded)")
    ck(view.accounts[Instances.ORPHAN_AID] == nil, "orphan bucket gets NO meter row")
    ck(view.total.hour == 4, "aggregate hour excludes orphans (got " .. view.total.hour .. ")")
    ck(view.total.day == 4, "aggregate day excludes orphans")
    local orp = Instances.WindowCounts(Instances.ORPHAN_AID, T)
    ck(orp.hour == 0 and orp.day == 0 and orp.orphan == true, "orphan bucket counts against no meter")
    ns.GetAccountID = savedGet
    Store.data = saved
end

-- Inbound merge dedup by (nameRealm, t) + self-immunity + convergent merged flag.
local function testMergeInbound(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local saved, savedGet = Store.data, ns.GetAccountID
    ns.GetAccountID = function() return "1" end   -- WE are account 1
    Store.data = { instances = {
        ["2"] = { ["B-R"] = { entries = {
            { t = 100, name = "MC", merged = false },
            { t = 200, name = "MC", merged = false },
        } } },
    } }
    local added = Instances.MergeInbound("2", {
        ["B-R"] = { entries = {
            { t = 200, name = "MC", merged = false },   -- dup -> dropped
            { t = 300, name = "MC", merged = false },   -- new -> added
        } },
    })
    ck(added == 1, "only the new (nameRealm,t) is added (got " .. added .. ")")
    local list = Store.data.instances["2"]["B-R"].entries
    ck(#list == 3, "list has 3 after dedup merge (got " .. #list .. ")")
    ck(list[#list].t == 300, "entries sorted ascending, newest last")

    -- Convergence: a peer that learned of a merge FIRST hands us the flag, and
    -- the richer fields fill in. Without this the two ledgers would disagree on
    -- `merged` forever — and `merged` is part of the mesh ledger hash.
    Instances.MergeInbound("2", {
        ["B-R"] = { entries = {
            { t = 200, name = "MC", merged = true, serial = 4242, exitT = 260, dur = 60 },
        } },
    })
    local e200
    for _, e in ipairs(Store.data.instances["2"]["B-R"].entries) do if e.t == 200 then e200 = e end end
    ck(e200.merged == true, "merged flag is unioned (one-way false -> true)")
    ck(e200.serial == 4242 and e200.exitT == 260 and e200.dur == 60, "absent optional fields filled from the wire")
    -- …and never flips back.
    Instances.MergeInbound("2", { ["B-R"] = { entries = { { t = 200, name = "MC", merged = false } } } })
    ck(e200.merged == true, "merged never regresses to false")

    local self0 = Instances.MergeInbound("1", { ["Z-R"] = { entries = { { t = 9, name = "X" } } } })
    ck(self0 == 0 and Store.data.instances["1"] == nil, "self-immune: own account not written from wire")
    ns.GetAccountID = savedGet
    Store.data = saved
end

-- Segment round-trip through the REAL mesh Pack/Unpack codec (LibDeflate), then
-- MergeInbound — proves the wire payload survives and dedups. Skips cleanly if
-- the lib codec is unavailable (non-harness VM without LibDeflate).
local function testSegmentRoundTrip(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    if not (ns.Mesh and ns.Mesh.Pack and ns.Mesh.Unpack) then
        return   -- mesh/codec absent: nothing to assert (documented skip)
    end
    local payload = ns.Mesh.Pack({ aid = "5", records = {
        ["D-R"] = { entries = {
            -- Carries the NEW optional fields: old peers ignore what they do not
            -- know, new peers get the richer record. Additive by construction.
            { t = 1500, name = "Zul'Gurub", mapID = 309, dur = 3600, gold = 500, xp = 0,
              merged = false, serial = 8181, exitT = 5100, goldLoot = 4200, mobXP = 40, mobKill = 44,
              enteredLevel = 60, group = "*Tester:60|Bramble:60", groupAvg = 60,
              trades = { { t = 4000, who = "Bramble", gave = 500000, got = 0 } } },
            { t = 1600, name = "Zul'Gurub", mapID = 309, dur = 60, gold = 0, xp = 0,
              merged = true, serial = 8181 },
        } },
    } })
    if not payload then return end   -- codec unavailable: skip
    local seg = ns.Mesh.Unpack(payload)
    ck(seg and seg.aid == "5", "round-trip: aid survives the codec")
    ck(seg and seg.records and seg.records["D-R"], "round-trip: records survive")
    local saved, savedGet = Store.data, ns.GetAccountID
    ns.GetAccountID = function() return "1" end
    Store.data = { instances = {} }
    local added = Instances.MergeInbound(seg.aid, seg.records)
    ck(added == 2, "round-trip: both entries merge into a fresh store (got " .. tostring(added) .. ")")
    local e = Store.data.instances["5"]["D-R"].entries
    ck(e[1].name == "Zul'Gurub" and e[2].merged == true, "round-trip: fields + merged flag intact")
    ck(e[1].serial == 8181 and e[1].exitT == 5100 and e[1].goldLoot == 4200,
        "round-trip: the new optional fields survive the wire")
    ck(e[1].enteredLevel == 60 and e[1].group == "*Tester:60|Bramble:60" and e[1].groupAvg == 60,
        "round-trip: entry level + group snapshot survive the wire")
    ck(type(e[1].trades) == "table" and e[1].trades[1].who == "Bramble" and e[1].trades[1].gave == 500000,
        "round-trip: the nested trade log survives the wire")
    ns.GetAccountID = savedGet
    Store.data = saved
end

-- The PURE per-entry detail primitives: group codec, average, union, trade log.
local function testDetailPrimitives(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- Codec round-trip, including the "you" marker.
    local members = { { name = "Tester", level = 58, isSelf = true },
                      { name = "Bramble", level = 57 }, { name = "Cera", level = 60 } }
    local str = Instances.EncodeGroup(members)
    ck(str == "*Tester:58|Bramble:57|Cera:60", "group encodes compactly (got " .. tostring(str) .. ")")
    local back = Instances.DecodeGroup(str)
    ck(#back == 3, "group decodes 3 members (got " .. #back .. ")")
    ck(back[1].name == "Tester" and back[1].level == 58 and back[1].isSelf == true,
        "group decode: self member with its level")
    ck(back[3].name == "Cera" and back[3].isSelf == false, "group decode: non-self member")
    ck(Instances.EncodeGroup({}) == nil, "empty roster encodes to nil, not an empty string")
    ck(Instances.EncodeGroup(nil) == nil, "nil roster -> nil")
    ck(#Instances.DecodeGroup(nil) == 0, "decoding nil yields an empty list")
    ck(#Instances.DecodeGroup("") == 0, "decoding an empty string yields an empty list")
    ck(#Instances.DecodeGroup("garbage") == 1 and Instances.DecodeGroup("garbage")[1].level == 0,
        "a level-less token still decodes with level 0")
    -- Separators can never be smuggled in via a name.
    local sep = Instances.DecodeGroup(Instances.EncodeGroup({ { name = "A|B:C*D", level = 5 } }))
    ck(#sep == 1 and sep[1].name == "ABCD" and sep[1].level == 5, "separators stripped from names")

    -- Average INCLUDING the player; unknown levels are skipped, not counted as 0.
    ck(Instances.AverageGroupLevel(members) == 58.3,
        "avg group level to 1dp (got " .. tostring(Instances.AverageGroupLevel(members)) .. ")")
    ck(Instances.AverageGroupLevel({ { name = "A", level = 60 }, { name = "B", level = 0 } }) == 60,
        "a member with no level does not drag the average down")
    ck(Instances.AverageGroupLevel({}) == nil, "no members -> no average")

    -- UNION: new names append, valid levels update, invalid levels never blank.
    local u1, avg1, n1 = Instances.UnionGroup(str, { { name = "Bramble", level = 58 },
                                                     { name = "Dorn", level = 55 } })
    local ul = Instances.DecodeGroup(u1)
    ck(n1 == 4 and #ul == 4, "union appends the newcomer (got " .. tostring(n1) .. ")")
    ck(ul[2].name == "Bramble" and ul[2].level == 58, "union updates a member who dinged")
    ck(ul[1].name == "Tester" and ul[1].isSelf == true, "union preserves first-seen order + self")
    ck(ul[4].name == "Dorn", "the newcomer lands last")
    ck(avg1 == 57.8, "union recomputes the average (got " .. tostring(avg1) .. ")")
    local u2 = Instances.DecodeGroup(Instances.UnionGroup(u1, { { name = "Bramble", level = 0 } }))
    ck(u2[2].level == 58, "an out-of-range reading (level 0) does NOT blank a known level")
    local u3, _, n3 = Instances.UnionGroup(nil, { { name = "Solo", level = 41, isSelf = true } })
    ck(n3 == 1 and u3 == "*Solo:41", "union from nothing seeds the snapshot")
    -- The roster cap holds at a full raid.
    local big = {}
    for i = 1, Instances.MAX_GROUP + 10 do big[i] = { name = "M" .. i, level = 60 } end
    local _, _, nBig = Instances.UnionGroup(nil, big)
    ck(nBig == Instances.MAX_GROUP, "group capped at MAX_GROUP (got " .. tostring(nBig) .. ")")

    -- Trade log.
    local e = {}
    ck(Instances.AppendTrade(e, 100, "Bramble", 500000, 0) ~= nil, "a money trade is logged")
    ck(#e.trades == 1 and e.trades[1].who == "Bramble" and e.trades[1].gave == 500000,
        "trade record carries partner + coin given")
    ck(Instances.AppendTrade(e, 110, "Cera", 0, 120000) ~= nil, "a received-coin trade is logged")
    ck(e.trades[2].got == 120000, "coin received recorded")
    ck(Instances.AppendTrade(e, 120, "Dorn", 0, 0) == nil, "an item-only (0/0) trade is NOT logged")
    ck(#e.trades == 2, "…and adds no record")
    ck(Instances.AppendTrade(e, 130, nil, 100, 0) ~= nil, "an unnamed partner still logs")
    ck(e.trades[3].who == "?", "…as an explicit unknown")
    ck(Instances.AppendTrade(nil, 1, "X", 1, 0) == nil, "nil entry -> no record, no error")
    for i = 1, Instances.MAX_TRADES + 5 do Instances.AppendTrade(e, 200 + i, "Spam", 1, 0) end
    ck(#e.trades == Instances.MAX_TRADES, "trade log capped at MAX_TRADES (got " .. #e.trades .. ")")
end

-- LIVE per-entry detail through the real handlers: entry level, roster union,
-- the kill-derived mob counter, and trades scoped to the run.
local function testLiveDetailCapture(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local sim = newSimClient()
    local ok, err = pcall(function()
        sim.playerLevel = 58
        sim.party = { { name = "Bramble", level = 57 }, { name = "Cera", level = 60 } }
        sim.enter("Scholomance", 289)
        local e = sim.entries()[1]
        ck(e.enteredLevel == 58, "entry level captured at zone-in (got " .. tostring(e.enteredLevel) .. ")")
        local g = Instances.DecodeGroup(e.group)
        ck(#g == 3, "group snapshotted at entry: player + 2 (got " .. #g .. ")")
        ck(g[1].name == "Tester" and g[1].isSelf == true, "the player leads the roster")
        ck(e.groupAvg == 58.3, "average group level includes the player (got " .. tostring(e.groupAvg) .. ")")

        -- A fourth member joins mid-run: the roster UNIONS, it does not replace.
        sim.clock = sim.clock + 60
        sim.setGroup({ { name = "Bramble", level = 57 }, { name = "Cera", level = 60 },
                       { name = "Dorn", level = 55 } })
        local g2 = Instances.DecodeGroup(sim.entries()[1].group)
        ck(#g2 == 4, "roster update unions the newcomer in (got " .. #g2 .. ")")
        -- Someone drops group entirely: the people who WERE here stay recorded.
        sim.clock = sim.clock + 60
        sim.setGroup({ { name = "Bramble", level = 57 } })
        local g3 = Instances.DecodeGroup(sim.entries()[1].group)
        ck(#g3 == 4, "a member leaving does not erase them from the run's roster (got " .. #g3 .. ")")

        -- Throttle: two roster events inside 2 s only sample once.
        sim.setGroup({ { name = "Zed", level = 60 } })
        ck(#Instances.DecodeGroup(sim.entries()[1].group) == 4, "roster re-read throttled to 2 s")
        sim.clock = sim.clock + 3
        sim.setGroup({ { name = "Zed", level = 60 } })
        ck(#Instances.DecodeGroup(sim.entries()[1].group) == 5, "…and lands once the throttle lapses")

        -- Kill-derived mob count (the boosted-run counter).
        sim.unitDied()
        sim.unitDied()
        ck(sim.entries()[1].mobKill == 2, "UNIT_DIED on a creature counts a kill (got "
            .. tostring(sim.entries()[1].mobKill) .. ")")
        ck((sim.entries()[1].mobXP or 0) == 0, "…without touching the XP-derived count")
        sim.unitDied("Player-3299-0AB4C1D2")
        ck(sim.entries()[1].mobKill == 2, "a player death is not a mob kill")
        sim.fire("CHAT_MSG_COMBAT_XP_GAIN", "Risen Guard dies, you gain 300 experience.")
        ck(sim.entries()[1].mobXP == 1, "the XP-derived counter still works alongside")

        -- A trade completed INSIDE lands on the run.
        sim.clock = sim.clock + 30
        sim.trade("Bramble", 500000, 0)
        local tr = sim.entries()[1].trades
        ck(tr and #tr == 1, "a completed trade inside is logged (got " .. tostring(tr and #tr) .. ")")
        ck(tr[1].who == "Bramble" and tr[1].gave == 500000, "trade partner + coin given recorded")
        ck(tr[1].t == sim.clock, "trade stamped with the time it completed")
        -- A cancelled trade is not.
        sim.trade("Cera", 999, 0, false)
        ck(#sim.entries()[1].trades == 1, "a trade neither side accepted is NOT logged")
        -- Nor is one that opens and is cancelled outright.
        sim.fire("TRADE_SHOW"); sim.fire("TRADE_REQUEST_CANCEL"); sim.fire("TRADE_CLOSED")
        ck(#sim.entries()[1].trades == 1, "a cancelled trade window logs nothing")

        -- Outside the instance nothing is captured at all.
        sim.clock = sim.clock + 30
        sim.leave()
        sim.unitDied()
        sim.trade("Cera", 700000, 0)
        ck(sim.entries()[1].mobKill == 2, "no kills counted once the run is closed")
        ck(#sim.entries()[1].trades == 1, "no trades logged once the run is closed")
    end)
    sim.restore()
    if not ok then fails[#fails + 1] = "live detail sim errored: " .. tostring(err) end
end

-- The SECOND corpse run into the same live instance. The reference deletes a
-- merged record, so its "previous record" is always live; we keep merged records
-- flagged, so the lookup has to step back over them or the third visit bills a
-- phantom slot and shows as its own row.
local function testDoubleCorpseRun(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local sim = newSimClient()
    local ok, err = pcall(function()
        sim.enter("Stratholme", 329)
        sim.clock = sim.clock + 10
        sim.cast(9100)
        sim.fire("CHAT_MSG_MONEY", "You loot 1 Gold, 0 Silver, 0 Copper")

        -- Wipe 1 -> corpse run back into the SAME instance.
        sim.clock = sim.clock + 300; sim.leave()
        sim.clock = sim.clock + 200; sim.enter("Stratholme", 329)
        sim.clock = sim.clock + 5;   sim.cast(9100)
        ck(sim.counts().hour == 1, "first corpse run consumes no slot")

        -- Wipe 2 -> corpse run back AGAIN. The record in front of the new one is
        -- now the first corpse run's MERGED entry.
        sim.clock = sim.clock + 300; sim.leave()
        sim.clock = sim.clock + 200; sim.enter("Stratholme", 329)
        sim.clock = sim.clock + 5;   sim.cast(9100)
        local e = sim.entries()
        ck(#e == 3, "three physical visits recorded")
        ck(e[3].merged == true, "the SECOND corpse run merges too (got merged="
            .. tostring(e[3].merged) .. ")")
        ck(sim.counts().hour == 1, "one live instance = one slot, however many corpse runs (got "
            .. sim.counts().hour .. ")")
        ck(e[1].merged == false and e[1].serial == 9100, "the original survivor holds the serial")

        -- A genuine reset after all that still bills its own slot.
        sim.clock = sim.clock + 300; sim.leave()
        sim.clock = sim.clock + 60;  sim.enter("Stratholme", 329)
        sim.clock = sim.clock + 5;   sim.cast(9101)
        ck(sim.entries()[4].merged == false, "a reset+rerun after corpse runs is NOT merged")
        ck(sim.counts().hour == 2, "…and burns its own slot (got " .. sim.counts().hour .. ")")
    end)
    sim.restore()
    if not ok then fails[#fails + 1] = "double corpse-run sim errored: " .. tostring(err) end
end

-- A merge must fold the DETAIL fields too: the corpse-run roster and any trades
-- taken during it belong to the same physical run.
local function testMergeFoldsDetail(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local entries = {}
    local a = select(1, Instances.RecordInto(entries, "Molten Core", 409, 1000,
        { enteredLevel = 58, group = "*Tester:58|Bramble:57", groupAvg = 57.5 }))
    a.serial = 4242
    Instances.AppendTrade(a, 1100, "Bramble", 100000, 0)
    local b = select(1, Instances.RecordInto(entries, "Molten Core", 409, 1400,
        { enteredLevel = 59, group = "*Tester:59|Dorn:60", groupAvg = 59.5 }))
    Instances.AppendTrade(b, 1450, "Dorn", 0, 250000)
    b.mobKill = 7
    local res, survivor = Instances.ApplySerial(entries, 4242, "g", "cast")
    ck(res == "merged" and survivor == a, "same serial merges into the survivor")
    ck(a.enteredLevel == 58, "entry level on the survivor is NOT overwritten (spec §2.4)")
    local g = Instances.DecodeGroup(a.group)
    ck(#g == 3, "the corpse-run roster is unioned into the survivor (got " .. #g .. ")")
    ck(g[1].level == 59, "a member who dinged during the re-entry updates")
    ck(a.groupAvg == 58.7, "average recomputed over the union (got " .. tostring(a.groupAvg) .. ")")
    ck(#a.trades == 2, "trades from both visits land on the survivor (got " .. #a.trades .. ")")
    ck(a.trades[2].who == "Dorn", "…in order")
    ck(a.mobKill == 7, "kill-derived count folded")
end

-- The mesh instance-ledger hash must be BLIND to the new optional fields, or an
-- old peer and a new peer would disagree forever and resync on every heartbeat.
local function testHashCompat(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    if not (ns.Mesh and ns.Mesh.HashInstances) then return end   -- documented skip
    local old = { ["A-R"] = { entries = {
        { t = 100, name = "MC", merged = false },
        { t = 200, name = "MC", merged = true },
    } } }
    local new = { ["A-R"] = { entries = {
        { t = 100, name = "MC", merged = false, serial = 77, exitT = 180, goldLoot = 9,
          mobXP = 3, mobKill = 4, prevSerial = 77, mergeGUID = "g", mergeSource = "cast",
          -- the per-entry DETAIL fields must be invisible to the hash too
          enteredLevel = 58, group = "*Tester:58|Bramble:57", groupAvg = 57.5,
          trades = { { t = 150, who = "Bramble", gave = 500000, got = 0 } }, src = "nit" },
        { t = 200, name = "MC", merged = true, serial = 77 },
    } } }
    ck(ns.Mesh.HashInstances(old) == ns.Mesh.HashInstances(new),
        "hash input unchanged by the new optional fields (no old/new sync loop)")
    local flipped = { ["A-R"] = { entries = {
        { t = 100, name = "MC", merged = false },
        { t = 200, name = "MC", merged = false },
    } } }
    ck(ns.Mesh.HashInstances(old) ~= ns.Mesh.HashInstances(flipped),
        "…but a genuine merged-flag divergence still trips a sync")
end

----------------------------------------------------------------------
-- NX-2 — A COLD ROSTER READING IS NOT A ROSTER (async lesson Class 7 + 6)
--
-- The entry snapshot is forced from PLAYER_ENTERING_WORLD, i.e. on the far side
-- of a loading screen, where `UnitLevel("party2")` routinely answers 0 and
-- `UnitClass` answers nil because the unit has not finished loading. That
-- reading was persisted as fact. `UnionGroup` upgrades on LATER samples, so a
-- group that reshuffles heals itself — but a STATIC group for a whole run never
-- fires another GROUP_ROSTER_UPDATE, so for the commonest case in the game (five
-- people who zone in together and stay) the coldest reading of the run was the
-- only reading the run ever got, and "Bramble:0" with no class colour was
-- written into the entry for good.
--
-- Red control: the pre-fix admission rule, restated as `unproven = nil`, on the
-- SAME sample — and the fixture asserts that the pre-fix rule really does admit
-- the phantom, so the green half cannot be vacuous.
----------------------------------------------------------------------
local function testColdRoster(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- ---- 1) the admission rule, pure ------------------------------------
    ck(Instances.MemberProven({ name = "Bramble", level = 57 }) == true,
       "a levelled member is proven")
    ck(Instances.MemberProven({ name = "Bramble", level = 0 }) == false,
       "level 0 is the client saying 'not loaded', not a level")
    ck(Instances.MemberProven({ name = "Bramble" }) == false, "a missing level is not proven")
    ck(Instances.MemberProven(nil) == false, "nil is not proven")

    local COLD = { name = "Bramble", level = 0, classTag = nil, unproven = true }
    local WARM = { name = "Bramble", level = 57, classTag = "DRUID" }

    -- GREEN: refused admission.
    local g1 = Instances.DecodeGroup(Instances.UnionGroup(nil, {
        { name = "Tester", level = 60, isSelf = true, classTag = "ROGUE" }, COLD }))
    ck(#g1 == 1, "an unproven member was admitted anyway (got " .. #g1 .. " member(s))")
    ck(g1[1].name == "Tester", "the proven self member must still be admitted")

    -- RED CONTROL: the same sample under the pre-fix rule (no `unproven` flag)
    -- admits the phantom. If this ever stops being true, the green row above is
    -- asserting nothing.
    local preFix = { name = "Bramble", level = 0, classTag = nil }
    local r1 = Instances.DecodeGroup(Instances.UnionGroup(nil, {
        { name = "Tester", level = 60, isSelf = true }, preFix }))
    ck(#r1 == 2 and r1[2].level == 0,
       "RED CONTROL FAILED: the pre-fix rule no longer admits a level-0 member, "
       .. "so the refusal above proves nothing")

    -- ---- 2) refusal is ADMISSION-only, never destructive -----------------
    -- A member already stored who goes cold mid-run (walked out of range) must
    -- keep the level we already know — the upgrade-only path is untouched.
    local stored = Instances.UnionGroup(nil, { { name = "Tester", level = 60, isSelf = true }, WARM })
    local g2 = Instances.DecodeGroup(Instances.UnionGroup(stored, { COLD }))
    ck(#g2 == 2, "the stored member was dropped by a cold sample")
    local bramble
    for _, m in ipairs(g2) do if m.name == "Bramble" then bramble = m end end
    ck(bramble and bramble.level == 57, "a cold sample blanked a level we already knew")
    ck(bramble and bramble.classTag == "DRUID", "a cold sample blanked a class we already knew")

    -- ---- 3) stored/decoded rows are NOT affected -------------------------
    -- The historical fold paths (`:458`, ui_instancespanel) union DECODED rows,
    -- which never carry the flag. Pre-fix data containing "Bramble:0" must keep
    -- folding exactly as it always did, or the fix would silently eat history.
    local legacy = Instances.DecodeGroup("*Tester:60|Bramble:0")
    local g3 = Instances.DecodeGroup(Instances.UnionGroup(nil, legacy))
    ck(#g3 == 2, "folding a historical entry lost a member (got " .. #g3 .. ")")

    -- ---- 4) the settle predicate ----------------------------------------
    ck(Instances.GroupSampleSettled({ { level = 60 }, { level = 57 } }, 2) == true,
       "two proven members with two expected is settled")
    ck(Instances.GroupSampleSettled({ { level = 60 }, { level = 0 } }, 2) == false,
       "a cold member means not settled")
    ck(Instances.GroupSampleSettled({ { level = 60 } }, 2) == false,
       "a member whose unit has not loaded at all is missing, not merely cold")
    ck(Instances.GroupSampleSettled({ { level = 60 } }, 0) == true,
       "solo (expected clamps to 1) is settled")

    -- ---- 5) THE LIVE PATH, through the real handlers ---------------------
    local sim = newSimClient()
    -- The ladder needs a real deferral. The sim nils C_Timer on purpose (so
    -- prints are immediate); give it a queue-and-pump one for this fixture only.
    local queue = {}
    _G.C_Timer = { After = function(d, fn) queue[#queue + 1] = { at = tonumber(d) or 0, fn = fn } end }
    local function pump(untilT)
        local keep = {}
        for i = 1, #queue do
            local q = queue[i]
            if q.at <= untilT then pcall(q.fn) else keep[#keep + 1] = q end
        end
        queue = keep
    end

    local ok, err = pcall(function()
        -- A STATIC five-man that zones in together. party2 is still loading.
        sim.playerLevel = 60
        sim.party = { { name = "Bramble", level = 0 }, { name = "Dorn", level = 58 } }
        sim.inRaid = false
        sim.money = 5000
        Instances._noteWallet(5000)          -- a warm wallet, so gold is not the subject here
        sim.enter("Molten Core", 409, "raid")

        local e = sim.entries()[1]
        ck(e ~= nil, "the entry was not recorded")
        local atEntry = Instances.DecodeGroup(e.group)
        ck(#atEntry == 2, "the cold member was persisted at entry (got " .. #atEntry .. ")")
        for _, m in ipairs(atEntry) do
            ck(m.name ~= "Bramble", "the cold member 'Bramble' was written into the entry")
        end
        ck(Instances._groupSettled == false, "a cold sample must not report itself settled")
        ck(#queue == #Instances.GROUP_LADDER_AT,
           "the post-entry ladder did not arm (" .. #queue .. " rung(s))")

        -- NOTHING ELSE HAPPENS. No roster change, no event — the static-group
        -- case. Only the ladder is left, and the unit warms up one second in.
        sim.party[1].level = 57
        Instances._lastGroupSnap = nil       -- the ladder rung forces past the throttle
        pump(1)
        local after = Instances.DecodeGroup(e.group)
        ck(#after == 3, "the ladder did not admit the member once warm (got " .. #after .. ")")
        local found
        for _, m in ipairs(after) do if m.name == "Bramble" then found = m end end
        ck(found and found.level == 57,
           "the member landed at the wrong level (" .. tostring(found and found.level) .. ")")
        ck(Instances._groupSettled == true, "a fully proven sample must report settled")
        ck(e.groupAvg == 58.3,
           "the average is over the settled roster (got " .. tostring(e.groupAvg) .. ")")

        -- The remaining rungs see `_groupSettled` and stop asking.
        local snapsBefore = e.group
        pump(99)
        ck(e.group == snapsBefore, "a settled ladder kept re-sampling")

        -- UNIT_LEVEL is the other producer, and the only one a static group
        -- fires at all. Drive it through the REAL handler table.
        sim.party[#sim.party + 1] = { name = "Kess", level = 0 }
        Instances._lastGroupSnap = nil
        sim.fire("UNIT_LEVEL", "party3")
        ck(#Instances.DecodeGroup(e.group) == 3, "a still-cold UNIT_LEVEL admitted a phantom")
        sim.party[3].level = 59
        Instances._lastGroupSnap = nil
        sim.fire("UNIT_LEVEL", "party3")
        ck(#Instances.DecodeGroup(e.group) == 4,
           "UNIT_LEVEL did not admit the member once warm")
        ck(Instances._Handlers.UNIT_LEVEL ~= nil,
           "UNIT_LEVEL is not in the handler table (the producer is unwired)")

        -- Closing the run retires any rung still in flight, so a stale timer can
        -- never write into the next entry.
        local genBefore = Instances._groupLadderGen
        sim.leave()
        ck(Instances._groupLadderGen ~= genBefore, "closing a run did not retire its ladder")
    end)
    _G.C_Timer = nil
    sim.restore()
    if not ok then fails[#fails + 1] = "cold-roster sim errored: " .. tostring(err) end
end

----------------------------------------------------------------------
-- NX-5 — THE COLD WALLET (async lesson Class 7 / Class 4)
--
-- Both wallet samples run on the far side of a loading screen. A cold zero at
-- exit does not merely read low: the stored number is a DELTA, so the run gets
-- recorded as having cost the character everything they walked in with.
----------------------------------------------------------------------
local function testColdWallet(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- ---- 1) the evidence table, pure -------------------------------------
    local v, p
    v, p = Instances.ProvenGold(5000, nil)
    ck(v == 5000 and p == true, "a positive read is proven")
    v, p = Instances.ProvenGold(0, nil)
    ck(v == 0 and p == false, "a zero with nothing ever warm is UNPROVEN")
    v, p = Instances.ProvenGold(0, 0)
    ck(v == 0 and p == true, "a zero confirmed by a warm zero is proven (you spent it all)")
    v, p = Instances.ProvenGold(0, 5000)
    ck(v == 5000 and p == false,
       "a zero against a warm positive must answer with the WARM figure, unproven")
    v, p = Instances.ProvenGold(nil, 5000)
    ck(v == nil and p == false, "an absent API is not a wallet of zero")

    -- ---- 2) the live path -------------------------------------------------
    local sim = newSimClient()
    local ok, err = pcall(function()
        -- Walk in with 500g. The entry read is warm.
        sim.money = 5000000
        sim.fire("PLAYER_MONEY")                    -- the settle signal
        ck(Instances._walletWarm == 5000000, "PLAYER_MONEY did not record a warm figure")
        ck(Instances._Handlers.PLAYER_MONEY ~= nil,
           "PLAYER_MONEY is not in the handler table (the producer is unwired)")

        sim.enter("Molten Core", 409, "raid")
        ck(Instances._openSample.goldProven == true, "the warm entry sample read as unproven")

        -- Loot 100g inside; the client tells us about it.
        sim.clock = sim.clock + 3600
        sim.money = 6000000
        sim.fire("PLAYER_MONEY")

        -- THE COLD EXIT. The loading screen has not finished; GetMoney answers 0.
        sim.money = 0
        local refusalsBefore = Instances._goldRefusals or 0
        sim.leave()
        local e = sim.entries()[1]
        ck(e ~= nil, "no entry recorded")
        -- The refusal leaves RecordInto's neutral `gold = 0` in place — "no
        -- wallet delta recorded for this run", which is what an un-stamped run
        -- already reads as, and which the display treats as nothing to show.
        ck(e.gold == 0,
           "the cold exit wrote a wallet delta of " .. tostring(e.gold)
           .. " instead of refusing")
        ck((Instances._goldRefusals or 0) == refusalsBefore + 1, "the refusal was not counted")

        -- RED CONTROL. The pre-fix code ran exactly this subtraction on exactly
        -- these two samples. Asserting the number it produced is what keeps the
        -- row above from being a tautology about a field that starts at 0.
        local preFixDelta = (0 - 5000000)
        ck(preFixDelta == -5000000,
           "RED CONTROL: the pre-fix arithmetic on these samples")
        ck(e.gold ~= preFixDelta,
           "the entry carries the pre-fix -500g figure — the run reads as having "
           .. "cost the character everything they walked in with")

        -- The wallet warms up a moment later, and a second stamp with two warm
        -- ends wins — this is the teardown-then-real-exit heal.
        sim.money = 6000000
        sim.fire("PLAYER_MONEY")
        Instances._stampExit({ gold = 5000000, goldProven = true, entry = e }, sim.clock)
        ck(e.gold == 1000000,
           "the warm re-stamp did not land (got " .. tostring(e.gold) .. ")")

        -- A genuinely broke character is a real answer, not a refusal.
        sim.money = 0
        sim.fire("PLAYER_MONEY")
        ck(Instances._walletWarm == 0, "a warm ZERO must be learnable, or spending everything "
           .. "would read as a cold wallet forever")
        local e2 = { t = sim.clock }
        Instances._stampExit({ gold = 0, goldProven = true, entry = e2 }, sim.clock + 10)
        ck(e2.gold == 0, "a warm zero at both ends is a real delta of zero")
    end)
    sim.restore()
    if not ok then fails[#fails + 1] = "cold-wallet sim errored: " .. tostring(err) end
end

function Instances.RunSelfTests(verbose)
    local suites = {
        { name = "transition classifier",         fn = testTransition },
        { name = "GUID instance serial",          fn = testGUIDSerial },
        { name = "serial merge decision",         fn = testApplySerial },
        { name = "live serial merge (real order)", fn = testLiveSerialMerge },
        { name = "mouseover/target/CL sources",    fn = testUnitSerialSources },
        { name = "instance->instance boundary",   fn = testInstanceToInstance },
        { name = "xp accumulator + gold",         fn = testXPAndGold },
        { name = "exit-epoch persistence",        fn = testExitEpochPersistence },
        { name = "server cap reconciliation",     fn = testServerCapReconciliation },
        { name = "rolling-window counts",         fn = testWindowCounts },
        { name = "ring capping",                  fn = testRingCap },
        { name = "cross-account + orphan bucket", fn = testCrossAccount },
        { name = "per-entry detail primitives",   fn = testDetailPrimitives },
        { name = "cold roster admission + ladder (NX-2, Class 7/6)", fn = testColdRoster },
        { name = "cold wallet refusal (NX-5, Class 7/4)",            fn = testColdWallet },
        { name = "live detail capture",           fn = testLiveDetailCapture },
        { name = "double corpse run",             fn = testDoubleCorpseRun },
        { name = "merge folds detail fields",     fn = testMergeFoldsDetail },
        { name = "inbound merge dedup",           fn = testMergeInbound },
        { name = "segment round-trip (codec)",    fn = testSegmentRoundTrip },
        { name = "mesh hash compatibility",       fn = testHashCompat },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok, err = pcall(suite.fn, fails)
        local passed = ok and #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS instances/" .. suite.name)
            elseif not ok then ns:Print("  FAIL instances/" .. suite.name .. " :: error in test: " .. tostring(err))
            else for _, f in ipairs(fails) do ns:Print("  FAIL instances/" .. suite.name .. " :: " .. f) end end
        end
    end
    return allPass
end

----------------------------------------------------------------------
-- Registration (subcommand-free; debug + selftest + login wiring at load)
----------------------------------------------------------------------

if ns.RegisterDebugCommand then
    ns:RegisterDebugCommand("instances", debugInstances)
end
if ns.RegisterSelfTest then
    ns:RegisterSelfTest("instances", Instances.RunSelfTests)
end

-- Drive login wiring off the existing lifecycle hook (mirrors mesh.lua).
ns:On("LOGIN", function()
    ns:SafeCall(Instances.OnLogin)
end)
