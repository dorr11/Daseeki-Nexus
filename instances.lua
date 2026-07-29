-- Daseeki Nexus — instances.lua
-- Instance-entry ledger + rolling-window cap math (NovaInstanceTracker
-- absorption, "Instances" tab engine). This wave is ENGINE ONLY: detection,
-- storage, the pure caps math, the merge heuristic, the cross-account view,
-- the chat warning, mesh merge, and /nexus debug instances. The tab UI + the
-- options section land in a sibling wave and code against the Instances.* API.
--
-- Clean-room: derived from public Classic Era game mechanics and the owner's
-- usage only. NovaInstanceTracker's source is NEVER read (same treatment as
-- ShadowNetwork / NovaWorldBuffs — assumed unlicensed).
--
-- The ground-truth server rule this models (public game fact):
--   * 5 instances per ROLLING 60 minutes, 30 per ROLLING 24h, enforced PER
--     ACCOUNT by the server. Entering an instance you are continuing does not
--     consume a new slot; a fresh instance ID does.
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
--   UnitXP("player") / UnitXPMax("player")             (globals; capability-guarded)
-- Every live call is guarded with a presence check so the module loads and its
-- pure self-tests run headless with none of these globals present.

local ADDON, ns = ...

local Instances = {}
ns.Instances = Instances

local Store = ns.Store

----------------------------------------------------------------------
-- Tunables (owner-tunable; documented so the tab can surface them later)
----------------------------------------------------------------------

local RING_CAP     = 60         -- entries kept per character (capped ring)
local MERGE_WINDOW = 30 * 60    -- 30 min: same-name re-entry inside this merges
local HOUR         = 3600
local DAY          = 86400

Instances.HOURLY_CAP  = 5
Instances.DAILY_CAP   = 30
Instances.WARN_HOURLY = 4       -- chat warning fires when the account hits this hourly count
Instances.WARN_DAILY  = 27      -- amber threshold (consumed by the tab UI, not this engine)

Instances.RING_CAP     = RING_CAP
Instances.MERGE_WINDOW = MERGE_WINDOW
Instances.HOUR         = HOUR
Instances.DAY          = DAY

-- Only instanceTypes that actually consume the 5/hr instance cap are logged.
-- Battlegrounds/arenas/scenarios do NOT count against the dungeon/raid instance
-- limit, so they are excluded to keep the caps math honest against the server's
-- real enforcement. (owner-tunable: widen this set to log more transition types.)
local COUNTED_TYPES = { party = true, raid = true }
Instances.COUNTED_TYPES = COUNTED_TYPES

--[[  MERGE HEURISTIC (owner-tunable — documented here for tuning)
======================================================================
The server treats "continuing" an instance you already hold differently from
creating a fresh instance ID, but the client cannot see the raw instance-ID
lifecycle cheaply. So we approximate a "same run" continuation with a heuristic:

  A fresh outside->inside transition MERGES into the prior entry (marks the new
  entry merged=true, so it is NOT counted in the caps math) WHEN ALL hold:
    1. the previous entry exists and is for the SAME instance NAME
       (case-insensitive), AND
    2. the re-entry happened within MERGE_WINDOW (30 min) of the prior entry, AND
    3. NO world-zone change occurred in between (crossing a graveyard / world
       zone while outside breaks the chain — that signals a genuinely new run).

Rationale: hearthing out and running back into the same MC lockout within a few
minutes is one physical run and should not burn a slot; but leaving, questing
across a world zone, and coming back is a new instance the server will bill.
Both thresholds are tunable: MERGE_WINDOW above, and the zone-change break is
tracked by Instances.OnZoneChanged. A merged entry is still stored (visible in
the register) — it simply does not consume a slot in WindowCounts.
======================================================================]]

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function now()
    return (Store and Store.Now and Store.Now()) or (time and time()) or 0
end

local function lower(s) return type(s) == "string" and s:lower() or "" end

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

-- Classify an outside/inside transition. Pure.
--   wasInside=false, isInside=true  -> "entry"
--   wasInside=true,  isInside=false -> "exit"
--   otherwise                       -> "none"
function Instances.ClassifyTransition(wasInside, isInside)
    if isInside and not wasInside then return "entry" end
    if wasInside and not isInside then return "exit" end
    return "none"
end

-- The merge heuristic (see the doc block above). Pure + self-tested.
-- prev        = the previous entry table for this character (or nil)
-- candName    = the re-entry's instance name
-- candT       = the re-entry's timestamp
-- zoneChanged = did a world-zone change occur since the prior instance activity?
-- window      = merge window (defaults to MERGE_WINDOW)
function Instances.MergeDecision(prev, candName, candT, zoneChanged, window)
    window = window or MERGE_WINDOW
    if type(prev) ~= "table" then return false end
    if zoneChanged then return false end
    if not prev.name or not candName then return false end
    if lower(prev.name) ~= lower(candName) then return false end
    local dt = (candT or 0) - (prev.t or 0)
    if dt < 0 or dt > window then return false end
    return true
end

-- Append a new entry to a character's entries list, applying the merge
-- heuristic and ring-capping to RING_CAP (drops the oldest). Injected time/zone
-- keep it pure so the detection + merge matrix is testable headless.
-- Returns (entry, merged, count).
function Instances.RecordInto(entries, name, mapID, t, zoneChanged)
    entries = entries or {}
    local prev = entries[#entries]
    local merged = Instances.MergeDecision(prev, name, t, zoneChanged, MERGE_WINDOW)
    local entry = { t = t, name = name, mapID = mapID, dur = 0, gold = 0, xp = 0, merged = merged }
    entries[#entries + 1] = entry
    while #entries > RING_CAP do table.remove(entries, 1) end   -- evict oldest (front)
    return entry, merged, #entries
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

-- Union-merge two entry lists, deduping by timestamp (t). Existing entries win
-- on a tie (an inbound entry with a t we already hold is dropped). Re-sorted
-- ascending by t and ring-capped to RING_CAP (keeps newest). Pure.
-- Returns (mergedList, addedCount).
function Instances.MergeEntryList(existing, incoming)
    existing = existing or {}
    incoming = incoming or {}
    local seen, out = {}, {}
    for i = 1, #existing do
        local e = existing[i]
        out[#out + 1] = e
        if e and e.t ~= nil then seen[e.t] = true end
    end
    local added = 0
    for i = 1, #incoming do
        local e = incoming[i]
        if e and e.t ~= nil and not seen[e.t] then
            seen[e.t] = true
            out[#out + 1] = e
            added = added + 1
        end
    end
    table.sort(out, function(a, b) return (a.t or 0) < (b.t or 0) end)
    while #out > RING_CAP do table.remove(out, 1) end
    return out, added
end

----------------------------------------------------------------------
-- Public read API (the tab UI codes against these — see deliverable)
----------------------------------------------------------------------

-- Rolling-window counts for a single account id.
function Instances.WindowCounts(aid, nowE)
    nowE = nowE or now()
    local all = Store and Store.data and Store.data.instances
    local charMap = all and all[aid or ""]
    return Instances.AccountCounts(charMap, nowE)
end

-- Cross-account view: per-account counts plus an aggregate total. This is the
-- net-new value the single-account tracker never had.
--   -> { accounts = { [aid] = counts, ... }, total = { hour = n, day = n } }
function Instances.AllAccounts(nowE)
    nowE = nowE or now()
    local all = (Store and Store.data and Store.data.instances) or {}
    local accounts, totH, totD = {}, 0, 0
    for aid, charMap in pairs(all) do
        local c = Instances.AccountCounts(charMap, nowE)
        accounts[aid] = c
        totH = totH + c.hour
        totD = totD + c.day
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
    return added
end

----------------------------------------------------------------------
-- Live capture (impure — the transition state machine + delta sampling)
----------------------------------------------------------------------

Instances._inside            = false   -- were we inside an instance at the last check?
Instances._openKey           = nil     -- { aid, nameRealm } of the currently-open run
Instances._openSample        = nil     -- { gold, xp, entry } captured at entry
Instances._zoneChangedSince  = false   -- world-zone change since last instance activity

local function sampleGold()
    if GetMoney then return GetMoney() or 0 end
    return nil
end

-- XP delta is only meaningful below 60 (a capped character earns none). Returns
-- nil at 60 / when the API is absent so no bogus delta is stored.
local function sampleXP()
    if not (UnitXP and UnitLevel) then return nil end
    if (UnitLevel("player") or 0) >= 60 then return nil end
    return UnitXP("player") or 0
end

-- Read the current instance identity from the live client. Returns
-- (name, instanceID, instanceType) or nil when not resolvable.
local function currentInstanceIdentity()
    if not GetInstanceInfo then return nil end
    local name, itype, _, _, _, _, _, instanceID = GetInstanceInfo()
    return name, instanceID, itype
end

-- ENTRY: an outside->inside transition into a counted (dungeon/raid) instance.
function Instances._recordEntry()
    local name, instanceID, itype = currentInstanceIdentity()
    if not COUNTED_TYPES[itype or ""] then
        -- Not a slot-consuming instance (bg/arena/scenario/none): ignore, but keep
        -- inside-state accurate so the matching exit is a no-op.
        return
    end
    local aid = (ns.GetAccountID and ns:GetAccountID()) or ""
    local nameRealm = selfNameRealm()
    local t = now()
    local entries = charEntries(aid, nameRealm, true)
    local entry, merged = Instances.RecordInto(entries, name, instanceID, t, Instances._zoneChangedSince)
    Instances._zoneChangedSince = false
    -- Open a run so exit can compute duration + gold/xp deltas.
    Instances._openKey    = { aid = aid, nameRealm = nameRealm }
    Instances._openSample = { gold = sampleGold(), xp = sampleXP(), entry = entry }
    -- Chat warning on the account hitting the hourly warn threshold (merged
    -- re-entries don't advance the count, so this only fires on real slots).
    if not merged then Instances._maybeWarn(aid, t) end
end

-- EXIT: an inside->outside transition closes the open run with its stats.
function Instances._closeRun()
    local sample = Instances._openSample
    Instances._openKey, Instances._openSample = nil, nil
    if not (sample and sample.entry) then return end
    local e = sample.entry
    local nowE = now()
    e.dur = math.max(0, nowE - (e.t or nowE))
    local goldNow = sampleGold()
    if sample.gold ~= nil and goldNow ~= nil then
        e.gold = goldNow - sample.gold   -- may be negative (spent gold in-run)
    end
    local xpNow = sampleXP()
    if sample.xp ~= nil and xpNow ~= nil then
        -- XP can read negative across a level-up (UnitXP resets past a ding);
        -- stored raw, owner can tune. Below 60 within one run it is a clean gain.
        e.xp = xpNow - sample.xp
    end
end

-- Chat warning (design §6). Setting-gated (DaseekiNexusDB.instancesWarnOnEntry,
-- default ON) — fires once, when the account's rolling-hour count first equals
-- the warn threshold. Plain copy per BRAND_SPEC.
function Instances._maybeWarn(aid, nowE)
    local db = Store and Store.GetSettings and Store.GetSettings()
    if db and db.instancesWarnOnEntry == false then return end   -- explicit opt-out
    local c = Instances.WindowCounts(aid, nowE)
    if c.hour == Instances.WARN_HOURLY and ns.Print then
        ns:Print(Instances.WARN_HOURLY .. " of " .. Instances.HOURLY_CAP .. " hourly instances used.")
    end
end

-- The transition driver, fired on PLAYER_ENTERING_WORLD. Reads IsInInstance and
-- routes entry/exit through the pure classifier.
function Instances.OnWorldChange()
    local isInside = (IsInInstance and IsInInstance()) and true or false
    local kind = Instances.ClassifyTransition(Instances._inside, isInside)
    if kind == "entry" then
        Instances._recordEntry()
    elseif kind == "exit" then
        Instances._closeRun()
    end
    Instances._inside = isInside
end

-- A world-zone change WHILE OUTSIDE an instance breaks the merge chain (the next
-- re-entry into the same name will not merge). Fired on ZONE_CHANGED_NEW_AREA.
function Instances.OnZoneChanged()
    if not Instances._inside then
        Instances._zoneChangedSince = true
    end
end

----------------------------------------------------------------------
-- Event wiring (additive; drives off the existing LOGIN signal — no core edit)
----------------------------------------------------------------------

function Instances.OnLogin()
    -- Seed inside-state so the very first PLAYER_ENTERING_WORLD (login inside an
    -- instance after a /reload) is treated correctly.
    Instances._inside = (IsInInstance and IsInInstance()) and true or false

    ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
        ns:SafeCall(Instances.OnWorldChange)
    end)
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", function()
        ns:SafeCall(Instances.OnZoneChanged)
    end)
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
    local anyAcct = false
    for aid, charMap in pairs(all) do
        anyAcct = true
        local c = view.accounts[aid] or { hour = 0, day = 0 }
        local slotStr = ""
        if c.hour >= Instances.HOURLY_CAP and c.nextHourSlotAt then
            slotStr = string.format(" | next hourly slot at t=%d (%ds)",
                c.nextHourSlotAt, math.max(0, c.nextHourSlotAt - nowE))
        end
        ns:Print(string.format("  acct %s: %d/%d hour, %d/%d day%s",
            (aid ~= "" and aid) or "<self/unset>",
            c.hour, Instances.HOURLY_CAP, c.day, Instances.DAILY_CAP, slotStr))
        for nameRealm, crec in pairs(charMap) do
            local entries = (crec and crec.entries) or {}
            local shown = 0
            for i = #entries, 1, -1 do
                if shown >= 6 then break end
                shown = shown + 1
                local e = entries[i]
                ns:Print(string.format("     %s | %s | t=%d age=%ds dur=%ds gold=%d xp=%d%s",
                    nameRealm, e.name or "?", e.t or 0, nowE - (e.t or nowE),
                    e.dur or 0, e.gold or 0, e.xp or 0, e.merged and " (merged)" or ""))
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

-- Detection transition matrix + merge heuristic cases.
local function testTransitionAndMerge(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- Transition classifier.
    ck(Instances.ClassifyTransition(false, true)  == "entry", "outside->inside = entry")
    ck(Instances.ClassifyTransition(true,  false) == "exit",  "inside->outside = exit")
    ck(Instances.ClassifyTransition(true,  true)  == "none",  "inside->inside = none")
    ck(Instances.ClassifyTransition(false, false) == "none",  "outside->outside = none")

    -- Merge heuristic direct.
    local prev = { t = 1000, name = "Molten Core" }
    ck(Instances.MergeDecision(prev, "Molten Core", 1000 + 600, false) == true,
        "same name, +10m, no zone change -> merged")
    ck(Instances.MergeDecision(prev, "molten core", 1000 + 600, false) == true,
        "merge is case-insensitive")
    ck(Instances.MergeDecision(prev, "Molten Core", 1000 + 600, true) == false,
        "world-zone change breaks the merge")
    ck(Instances.MergeDecision(prev, "Molten Core", 1000 + MERGE_WINDOW + 1, false) == false,
        "beyond the 30m window -> not merged")
    ck(Instances.MergeDecision(prev, "Blackwing Lair", 1000 + 60, false) == false,
        "different instance name -> not merged")
    ck(Instances.MergeDecision(nil, "Molten Core", 1000, false) == false,
        "no prior entry -> not merged")
    ck(Instances.MergeDecision(prev, "Molten Core", 990, false) == false,
        "negative dt (clock skew) -> not merged")

    -- RecordInto applies the heuristic into a live ledger.
    local entries = {}
    local e1, m1 = Instances.RecordInto(entries, "Molten Core", 409, 1000, false)
    ck(m1 == false and #entries == 1, "first MC entry is a fresh slot")
    local _, m2 = Instances.RecordInto(entries, "Molten Core", 409, 1000 + 300, false)
    ck(m2 == true and #entries == 2 and entries[2].merged == true,
        "re-entry within window merges (stored but merged)")
    local _, m3 = Instances.RecordInto(entries, "Molten Core", 409, 1000 + 300, true)
    ck(m3 == false, "re-entry after a zone change is a fresh slot")
    ck(e1.dur == 0 and e1.gold == 0, "new entry stats default to 0")
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
    -- Oldest in-hour is (T-(HOUR-1)); its slot opens at t+HOUR.
    ck(c.nextHourSlotAt == (T - (HOUR - 1)) + HOUR, "nextHourSlotAt = oldest in-window + HOUR")
    ck(c.nextDaySlotAt == (T - HOUR) + DAY, "nextDaySlotAt = oldest in-day + DAY")
    -- Empty account.
    local e = Instances.AccountCounts({}, T)
    ck(e.hour == 0 and e.day == 0 and e.nextHourSlotAt == nil, "empty account -> zero counts, no slot time")
    -- Exactly at nextHourSlotAt the count drops by one (aging boundary).
    local c2 = Instances.AccountCounts(charMap, (T - (HOUR - 1)) + HOUR)
    ck(c2.hour < c.hour, "count decreases once the oldest ages out at nextHourSlotAt")
end

-- Ring capping at RING_CAP.
local function testRingCap(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local entries = {}
    for i = 1, RING_CAP + 15 do
        -- distinct names so nothing merges; ascending t
        Instances.RecordInto(entries, "Zone" .. i, i, 5000 + i * 100, true)
    end
    ck(#entries == RING_CAP, "ring holds at most RING_CAP (" .. #entries .. ")")
    -- Oldest were evicted from the front; newest retained at the back.
    ck(entries[#entries].name == "Zone" .. (RING_CAP + 15), "newest entry retained")
    ck(entries[1].name == "Zone" .. 16, "oldest 15 evicted (front-first)")
end

-- Cross-account aggregation fixture.
local function testCrossAccount(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local saved = Store.data
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
    } }
    local one = Instances.WindowCounts("1", T)
    ck(one.hour == 2, "account 1 has 2 in the hour")
    local view = Instances.AllAccounts(T)
    ck(view.accounts["1"].hour == 2, "cross view: acct 1 hour = 2")
    ck(view.accounts["2"].hour == 2, "cross view: acct 2 hour = 2 (merged excluded)")
    ck(view.total.hour == 4, "aggregate hour across accounts = 4")
    ck(view.total.day == 4, "aggregate day across accounts = 4")
    Store.data = saved
end

-- Inbound merge dedup by (nameRealm, t) + self-immunity + cap.
local function testMergeInbound(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local saved = Store.data
    local savedGet = ns.GetAccountID
    ns.GetAccountID = function() return "1" end   -- WE are account 1
    Store.data = { instances = {
        ["2"] = { ["B-R"] = { entries = {
            { t = 100, name = "MC", merged = false },
            { t = 200, name = "MC", merged = false },
        } } },
    } }
    -- Inbound for account 2: one duplicate t (200) + one new (300).
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
    -- Self-immunity: an inbound for OUR OWN account (1) is refused.
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
            { t = 1500, name = "Zul'Gurub", mapID = 309, dur = 3600, gold = 500, xp = 0, merged = false },
            { t = 1600, name = "Zul'Gurub", mapID = 309, dur = 60, gold = 0, xp = 0, merged = true },
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
    ns.GetAccountID = savedGet
    Store.data = saved
end

function Instances.RunSelfTests(verbose)
    local suites = {
        { name = "transition + merge heuristic", fn = testTransitionAndMerge },
        { name = "rolling-window counts",        fn = testWindowCounts },
        { name = "ring capping",                 fn = testRingCap },
        { name = "cross-account aggregation",    fn = testCrossAccount },
        { name = "inbound merge dedup",          fn = testMergeInbound },
        { name = "segment round-trip (codec)",   fn = testSegmentRoundTrip },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local fails = {}
        local ok = pcall(suite.fn, fails)
        local passed = ok and #fails == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS instances/" .. suite.name)
            elseif not ok then ns:Print("  FAIL instances/" .. suite.name .. " :: error in test")
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
