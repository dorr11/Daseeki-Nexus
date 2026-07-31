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
--   CombatLogGetCurrentEventInfo() -> timestamp, subEvent, hideCaster, sourceGUID, ...
--   UnitGUID(unit)            -> guid:WOWGUID          (global; capability-guarded)
-- Events (all catalog-verified under Event.* in wow-api-catalog/latest):
--   PLAYER_ENTERING_WORLD, PLAYER_LEAVING_WORLD, PLAYER_LOGOUT,
--   UNIT_SPELLCAST_START / UNIT_SPELLCAST_SUCCEEDED (unitTarget, castGUID, spellID),
--   COMBAT_LOG_EVENT_UNFILTERED, UPDATE_MOUSEOVER_UNIT, PLAYER_TARGET_CHANGED,
--   CHAT_MSG_COMBAT_XP_GAIN, CHAT_MSG_MONEY, CHAT_MSG_SYSTEM.
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
-- Returns (entry, count).
function Instances.RecordInto(entries, name, mapID, t)
    entries = entries or {}
    local entry = {
        t = t, name = name, mapID = mapID,
        dur = 0, gold = 0, xp = 0, merged = false,
        goldLoot = 0,      -- loot-only copper (CHAT_MSG_MONEY); spec prefers this
        mobXP = 0,         -- kills that yielded XP
        mobKill = 0,       -- kills seen in the combat log (boosted grey runs)
    }
    entries[#entries + 1] = entry
    while #entries > RING_CAP do table.remove(entries, 1) end   -- evict oldest (front)
    return entry, #entries
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

    local prev = entries[#entries - 1]
    if type(prev) == "table" and not prev.merged and (prev.serial or 0) == serial then
        -- SAME LIVE INSTANCE: fold the new record's takings into the survivor.
        prev.goldLoot = (prev.goldLoot or 0) + (newest.goldLoot or 0)
        prev.xp       = (prev.xp or 0)       + (newest.xp or 0)
        prev.mobXP    = (prev.mobXP or 0)    + (newest.mobXP or 0)
        prev.mobKill  = (prev.mobKill or 0)  + (newest.mobKill or 0)
        -- Entry level / entry XP / entry money on the survivor are deliberately
        -- NOT overwritten (spec §2.4 — overwriting them was a bug there too).
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
    local FILL = { "serial", "prevSerial", "exitT", "goldLoot", "mobXP", "mobKill", "mapID" }
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

local function sampleGold()
    if GetMoney then return GetMoney() or 0 end
    return nil
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
    local entry = Instances.RecordInto(entries, name, instanceID, t)
    -- Open a run so exit can stamp duration + the wallet delta.
    Instances._openKey     = { aid = aid, nameRealm = nameRealm }
    Instances._openSample  = { gold = sampleGold(), entry = entry, entries = entries }
    Instances._entryAt     = t
    Instances._serialArmed = true   -- one-shot serial watcher (spec §2.1)
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
    local goldNow = sampleGold()
    if sample.gold ~= nil and goldNow ~= nil then
        -- WALLET delta: includes repairs, vendor sales, reagents, mail. Kept as a
        -- backup; e.goldLoot (loot-only, accumulated live) is the honest number
        -- and is what any display should prefer (spec §3.4 / §8.2).
        e.gold = goldNow - sample.gold
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
function Instances._onCombatLog()
    if not Instances._serialArmed then return end
    if not CombatLogGetCurrentEventInfo then return end
    if not pastSuppression() then return end
    local _, subEvent, _, sourceGUID = CombatLogGetCurrentEventInfo()
    if not CL_SERIAL_EVENTS[subEvent or ""] then return end
    Instances._observeSerial(sourceGUID, "combatlog")
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
    }
    local savedNow, savedData, savedGet = Store.Now, Store.data, ns.GetAccountID
    local savedDB = Store.db
    local savedState = {
        Instances._inside, Instances._curKey, Instances._openKey,
        Instances._openSample, Instances._serialArmed, Instances._entryAt,
        Instances._serverCapAt,
    }

    G.IsInInstance = function() return sim.inside, sim.itype end
    G.GetInstanceInfo = function()
        return sim.name, sim.itype, 1, "Normal", 5, 0, false, sim.instanceID
    end
    G.GetMoney = function() return sim.money end
    G.UnitGUID = function(unit) return sim.unitGUID and sim.unitGUID[unit] or nil end
    G.UnitName = function() return "Tester" end
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
              merged = false, serial = 8181, exitT = 5100, goldLoot = 4200, mobXP = 40, mobKill = 44 },
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
    ns.GetAccountID = savedGet
    Store.data = saved
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
          mobXP = 3, mobKill = 4, prevSerial = 77, mergeGUID = "g", mergeSource = "cast" },
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
