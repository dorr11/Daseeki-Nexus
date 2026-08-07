--[[
    Daseeki Nexus — friends.lua

    MESH-WIDE AUTO-FRIEND.

    Every character in the mesh that this character CAN be friends with is put on
    this character's friends list, once, up front. The owner's directive: "just
    add all characters from the mesh to each character's friends list that way
    it's always covered for the mail situations later rather than trickling them
    in through mail features" — so the coverage is complete before any consumer
    needs it, and Daseeki-Conduit simply benefits from the outcome (Blizzard's
    send-mail confirmation never appears for a name that is already a friend).

    ── WHAT COUNTS AS FRIENDABLE ─────────────────────────────────────────────────
    A mesh character is added when ALL of these hold:
      (a) same faction as this character   — unknown faction is SKIPPED, never guessed
      (b) same realm as this character
      (c) NOT on the same account as this character
      (d) not already on the friends list
      (e) not blocked by a ledger (ours or Daseeki-Conduit's — see below)

    (c) is answered by the STORE'S ACCOUNT GRAPH, never by a name heuristic:
    DaseekiNexusData.accounts[aid] partitions every known character by owning
    account, and a bucket is ours when it is flagged isSelf or its aid equals our
    own account id (Store.GetSelfAccount / Store.IsSelfAccount write and read
    exactly that). A character that appears in ANY self bucket is ours and is
    skipped — sticky, so a phantom twin filed under a relayer's bucket (see the
    own-account-authority note in store.lua) cannot make our own alt look foreign.
    A character known ONLY from the "" orphan bucket has NO account attribution
    at all: that is unknown, and unknown is skipped.

    ── WHY THE FRIENDS LIST MUST BE CONFIRMED FIRST ──────────────────────────────
    The friends list is SERVER-SIDE. For the first seconds after login
    C_FriendList.GetNumFriends() answers 0 — not "you have no friends" but "the
    client has not been told yet". Diffing against that reads as "nobody is my
    friend", which would re-add everyone the owner has deliberately removed and,
    worse, mark deliberate removals as never-happened. So:

        the pass NEVER runs until we have asked (C_FriendList.ShowFriends) AND a
        FRIENDLIST_UPDATE has come back to us afterwards.

    No backstop "run anyway after N seconds" exists on purpose. If the list never
    confirms, this character simply does nothing this session and tries again at
    the next login. Doing nothing is always recoverable; a wrong diff is not.

    ── THE NEVER-RE-ADD LEDGER ───────────────────────────────────────────────────
    Persisted (additive) at DaseekiNexusData.meshFriends:

        meshFriends = { schema = 1, chars = { ["Me-Realm"] = { [key] = entry } } }
        key   = "<lowered base name>-<lowered space-stripped realm>"
        entry = { s = <state>, ts = <epoch>, n = <add attempts>, why = <text> }

    Scoped per LOGGED-IN CHARACTER because the friends list is per character.
    States, and the only transitions that exist:

        pending      we issued AddFriend; the list has not shown them yet.
        added        we issued AddFriend and then SAW them on a confirmed list.
        preexisting  they were already a friend the first time we considered them.
        blocked      terminal. Never act on this name again, ever.

      pending      -> added    : seen on a confirmed list.
      pending      -> blocked  : MAX_ATTEMPTS AddFriend calls never landed. Quiet
                                 give-up; no error spam, no infinite retry.
      added        -> blocked  : gone from a CONFIRMED list. The owner removed
      preexisting  -> blocked    them on purpose, and that decision is permanent.

    The pending->added confirmation step is what makes "the owner removed them"
    distinguishable from "our add never worked". Without it, a failed add and a
    manual unfriend look identical (ledgered, not on the list) and one of the two
    doctrines has to be broken. With it: an add that never confirmed is retried on
    the next natural trigger (login / roster growth) and never within the same
    session; a confirmed friend that vanishes is a removal, and is blocked.

    preexisting is deliberately blocking too. A character we found already on the
    list is one we must never add — if the owner removes them later, re-adding
    them would undo a deliberate choice just as surely as re-adding one of ours.
    This mirrors Daseeki-Conduit/friends.lua, which marks both cases for the same
    reason; that module solved this doctrine first and is our reference.

    ── CONDUIT'S LEDGER IS HONOURED, NEVER WRITTEN ───────────────────────────────
    Daseeki-Conduit keeps its own never-re-add ledger for MAIL RECIPIENTS at
    DaseekiConduitDB.friended[charKey][dirKey] = true, with dirKey in exactly the
    key shape above. A name the owner unfriended after Conduit added it must not
    come back through the Nexus door, so every pass reads that table (type-guarded,
    absent-safe, READ-ONLY) and skips anything it names. Nexus never writes to it,
    and Conduit's module stays independent — it still covers recipients that are
    not mesh characters at all.

    Conduit's charKey is UnitName().."-"..GetRealmName() with the realm SPACES
    INTACT, while Nexus keys strip them; both spellings are looked up so a
    two-word realm ("Blood Sail Buccaneers") cannot silently miss.

    ── GUARDS ───────────────────────────────────────────────────────────────────
      * friends-list capacity: the plan stops at the cap, quietly. No chat line,
        no doomed AddFriend calls; a freed slot is picked up at the next trigger.
      * AddFriend failure: swallowed (plain pcall, not ns:SafeCall — the owner
        asked for no error spam here). Retried only on the next natural trigger.
      * unknown faction: skipped. Never guessed, never "tried to see".
      * the ignore list is never read or written.
      * a friend is NEVER removed, under any circumstances. There is no code path
        in this file that calls C_FriendList.RemoveFriend or its by-index twin.

    ── PURE / IMPURE SPLIT ──────────────────────────────────────────────────────
    Everything above the RUNTIME section is pure: the roster collector, the
    reconciler, the skip matrix and the planner all take their world (who I am,
    which realm/faction, which names are friends, how full the list is, both
    ledgers) as an injected context. The selftest suite drives them headless under
    a bare Lua 5.1 VM; the runtime section is the only place a WoW API is touched.

    API surface used, verified against wow-api-catalog 1.15.9.68808:
        C_FriendList.AddFriend(name [, notes])            -- no return value
        C_FriendList.GetNumFriends() -> numFriends
        C_FriendList.GetFriendInfoByIndex(index) -> FriendInfo
        C_FriendList.ShowFriends()
    MAX_FRIENDS is NOT in the catalog's globals list for this build, so it is read
    defensively and falls back to the Classic Era cap of 100.
--]]

local ADDON, ns = ...

local Friends = {}
ns.MeshFriends = Friends

Friends.LEDGER_SCHEMA = 1

-- Classic Era's friends-list cap. Read from the client's own MAX_FRIENDS when it
-- exposes one; this is only the fallback for a client that does not.
Friends.FRIEND_CAP_FALLBACK = 100

-- How many times one name may be handed to AddFriend before we give up on it
-- quietly and block it. Counted across sessions (persisted), incremented only
-- when a call is actually ISSUED — never by the reconciler, which runs on every
-- FRIENDLIST_UPDATE (friends logging on and off fire it) and would otherwise
-- burn the budget without a single add being attempted.
Friends.MAX_ATTEMPTS = 3

-- Headless discipline: hard ceilings so a corrupt or absurd store can never turn
-- a login into an unbounded walk. Both are far above any real mesh.
Friends.MAX_ROSTER = 400
Friends.MAX_LEDGER = 800

-- ════════════════════════════════════════════════════════════════════════════
--  PURE LOGIC  (selftest targets — no WoW API below this line until RUNTIME)
-- ════════════════════════════════════════════════════════════════════════════

local function trim(s)
    return (tostring(s or "")):match("^%s*(.-)%s*$")
end

-- Realms compare space-stripped and case-folded, so "Blood Sail Buccaneers" and
-- "BloodsailBuccaneers" are one realm. Returns "" for nothing.
function Friends.NormalizeRealm(realm)
    return (trim(realm):gsub("%s+", "")):lower()
end

-- "Name-Realm" -> base, realm. A bare name yields realm = nil.
function Friends.SplitNameRealm(nameRealm)
    local s = trim(nameRealm)
    local base, realm = s:match("^([^%-]+)%-(.+)$")
    if base then return trim(base), trim(realm) end
    return s, nil
end

-- THE canonical key. Deliberately identical in shape to Conduit's
-- Friends.CanonicalKey so its ledger can be read with our own keys.
function Friends.Key(nameRealm, defaultRealm)
    local base, realm = Friends.SplitNameRealm(nameRealm)
    if base == "" then return nil end
    return base:lower() .. "-" .. Friends.NormalizeRealm(realm or defaultRealm)
end

-- The base name out of a key ("bankalt-whitemane" -> "bankalt").
local function keyBase(key)
    return (key:match("^([^%-]+)") or key)
end

----------------------------------------------------------------------
-- THE ROSTER COLLECTOR  (pure)
--
-- `accounts` is DaseekiNexusData.accounts — the same graph the dashboard reads
-- (ui_shell.lua Dashboard.RosterCandidates walks characters + homeless of every
-- bucket, and so do we). One entry per Name-Realm, merged across every bucket
-- that holds a copy:
--
--   own   — sticky TRUE. Any self bucket holding the name settles it: this is
--           our own character, on our own account, and is never friended.
--   known — TRUE once the name has been seen in a bucket with a real account id
--           (or a self bucket). A name known only from the "" orphan bucket has
--           no account attribution, so we cannot prove it is not ours: skipped.
--   faction — first non-nil wins, EXCEPT that two buckets claiming different
--           factions for one name collapse to nil (conflict = unknown = skip).
--           A name is unique per realm across both factions, so a conflict is
--           always corruption, never news.
--
-- opts = { selfAID = "<our account id>" }
----------------------------------------------------------------------
function Friends.CollectRoster(accounts, opts)
    opts = opts or {}
    local selfAID = opts.selfAID or ""
    local out, count = {}, 0

    if type(accounts) ~= "table" then return out end

    local aids = {}
    for aid in pairs(accounts) do
        if type(aid) == "string" then aids[#aids + 1] = aid end
    end
    table.sort(aids)

    for _, aid in ipairs(aids) do
        local bucket = accounts[aid]
        if type(bucket) == "table" then
            local isSelf  = (bucket.isSelf == true) or (aid ~= "" and aid == selfAID)
            local hasAID  = isSelf or aid ~= ""
            local function consider(nameRealm)
                if type(nameRealm) ~= "string" or nameRealm == "" then return end
                local base, realm = Friends.SplitNameRealm(nameRealm)
                if base == "" or not realm then return end
                local key = Friends.Key(nameRealm)
                if not key then return end
                local e = out[key]
                if not e then
                    if count >= Friends.MAX_ROSTER then return end
                    count = count + 1
                    e = { name = base, realm = Friends.NormalizeRealm(realm),
                          faction = nil, own = false, known = false }
                    out[key] = e
                end
                if isSelf then e.own = true end
                if hasAID then e.known = true end
                local rec = (bucket.characters and bucket.characters[nameRealm])
                         or (bucket.homeless   and bucket.homeless[nameRealm])
                local f = type(rec) == "table" and rec.faction or nil
                if f == "Alliance" or f == "Horde" then
                    if e.faction == nil and not e.factionConflict then
                        e.faction = f
                    elseif e.faction ~= nil and e.faction ~= f then
                        e.faction, e.factionConflict = nil, true
                    end
                end
            end
            for nameRealm in pairs(bucket.characters or {}) do consider(nameRealm) end
            for nameRealm in pairs(bucket.homeless   or {}) do consider(nameRealm) end
        end
    end
    return out
end

-- Keys present in `roster` that `known` has never seen. This is the whole of
-- "the mesh roster grew": a new Name-Realm appearing in the store.
function Friends.NewKeys(roster, known)
    local out = {}
    for key in pairs(roster or {}) do
        if type(key) == "string" and not (known and known[key]) then
            out[#out + 1] = key
        end
    end
    table.sort(out)
    return out
end

----------------------------------------------------------------------
-- THE RECONCILER  (pure, mutates the ledger in place)
--
-- Runs ONLY against a confirmed-populated friends list — that is the entire
-- point of it. Returns changed(bool), confirmed(n), blocked(n).
----------------------------------------------------------------------
function Friends.Reconcile(ledger, ctx)
    ctx = ctx or {}
    if type(ledger) ~= "table" then return false, 0, 0 end
    if not ctx.listConfirmed then return false, 0, 0 end     -- never judge a dark list

    local friends = ctx.friends or {}
    local now     = ctx.now or 0
    local changed, confirmed, blocked = false, 0, 0

    -- CLASS 8 / NX-7 — SORT BEFORE THE CEILING, exactly as `Plan` below already
    -- does (friends.lua:423, the pattern the audit cites as this file's own
    -- correct precedent). This walk is not a display: adjudication here is a
    -- PERMANENT state transition — an entry that reaches MAX_ATTEMPTS is written
    -- "blocked" and is never retried. Truncating an unsorted walk at MAX_LEDGER
    -- meant that, above the ceiling, WHICH entries got sentenced was iteration
    -- luck, re-rolled every session: the same ledger could block a different
    -- eighth-hundred of itself each login, and an entry that never came up was
    -- never judged at all.
    local keys = ns.SortedKeys(ledger, Friends.MAX_LEDGER)
    for i = 1, #keys do
        local key = keys[i]
        local e = ledger[key]
        if type(e) == "table" then
            local isFriend = friends[keyBase(key)] and true or false
            if e.s == "pending" then
                if isFriend then
                    e.s, e.ts = "added", now
                    changed, confirmed = true, confirmed + 1
                elseif (tonumber(e.n) or 0) >= Friends.MAX_ATTEMPTS then
                    -- The name never appeared after every attempt we allow. It is
                    -- not addable (deleted, renamed, cross-faction after all).
                    -- Stop trying, silently.
                    e.s, e.ts, e.why = "blocked", now, "add never landed"
                    changed, blocked = true, blocked + 1
                end
            elseif e.s == "added" or e.s == "preexisting" then
                if not isFriend then
                    -- They were on the list, with our knowledge, and now they are
                    -- not. That is the owner unfriending them. Permanent.
                    e.s, e.ts, e.why = "blocked", now, "removed by you"
                    changed, blocked = true, blocked + 1
                end
            end
        end
    end
    return changed, confirmed, blocked
end

----------------------------------------------------------------------
-- THE SKIP MATRIX  (pure)
--
-- ctx = {
--   enabled       = <bool>,   -- the "Auto-friend mesh characters" setting
--   listConfirmed = <bool>,   -- a FRIENDLIST_UPDATE has answered our request
--   me            = "<my key>",           -- this character, in key form
--   realm         = "<normalized realm>",
--   faction       = "Alliance"|"Horde"|nil,
--   friends       = { [lowered base name] = true },   -- the live friends list
--   ledger        = { [key] = { s =, n = } },         -- OUR ledger, reconciled
--   conduit       = { [key] = true } | nil,           -- Conduit's, read-only
--   attempted     = { [key] = true },                 -- issued THIS session
--   numFriends    = <n>,
--   maxFriends    = <cap>,
-- }
--
-- Returns action, reason:
--   "add"   add them and open a pending ledger entry.
--   "mark"  already a friend and not in our ledger — record "preexisting" so a
--           later deliberate unfriend is never undone by us.
--   "noop"  already a friend and already known. Nothing at all to do.
--   "cap"   the list is full. Quiet stop; no ledger entry, a freed slot retries.
--   "skip"  do nothing at all.
----------------------------------------------------------------------
function Friends.Decide(key, entry, ctx, planned)
    ctx = ctx or {}
    planned = planned or 0

    if not ctx.enabled       then return "skip", "auto-friend is off" end
    if not ctx.listConfirmed then return "skip", "friends list not confirmed" end
    if type(key) ~= "string" or key == "" then return "skip", "malformed key" end
    if type(entry) ~= "table" then return "skip", "malformed entry" end

    local base = trim(entry.name or "")
    if base == "" then return "skip", "malformed name" end

    -- Never ourselves. Checked before the account test so the reason is precise.
    if key == ctx.me then return "skip", "this character" end

    -- (c) same-account exclusion — the store's account graph, never a heuristic.
    if entry.own then return "skip", "same account" end
    if not entry.known then return "skip", "account unknown" end

    -- (b) same realm. A key always carries a realm; an empty one is corruption.
    local er = Friends.NormalizeRealm(entry.realm)
    if er == "" then return "skip", "realm unknown" end
    if er ~= Friends.NormalizeRealm(ctx.realm) then return "skip", "other realm" end

    -- (a) same faction. UNKNOWN IS SKIPPED — we do not "try it and see", because
    -- a doomed attempt still burns a ledger slot and teaches us nothing.
    if entry.faction ~= "Alliance" and entry.faction ~= "Horde" then
        return "skip", "faction unknown"
    end
    if ctx.faction ~= entry.faction then return "skip", "other faction" end

    -- (e) Conduit's ledger. Read-only and absolute: it already recorded that this
    -- character was handled on this toon, so a removal since then was deliberate.
    if ctx.conduit and ctx.conduit[key] then
        return "skip", "handled by Daseeki-Conduit"
    end

    -- (e) our own ledger.
    local led = ctx.ledger and ctx.ledger[key]
    local state = type(led) == "table" and led.s or nil
    if state == "blocked" then
        return "skip", led.why or "blocked"
    end

    -- (d) already a friend.
    if ctx.friends and ctx.friends[base:lower()] then
        if state then return "noop", "already a friend" end
        return "mark", "already a friend"
    end

    -- Reconcile has already turned an "added"/"preexisting" entry whose name is
    -- missing from the confirmed list into "blocked", so reaching here with one
    -- of those states is impossible. Defensive: never re-add either way.
    if state == "added" or state == "preexisting" then
        return "skip", "already handled here"
    end

    -- A pending entry is a retry candidate, but only ONCE per session: one
    -- natural trigger, one attempt. That is what keeps a failing name from
    -- looping against the FRIENDLIST_UPDATE it fires itself.
    if ctx.attempted and ctx.attempted[key] then
        return "skip", "already attempted this session"
    end
    if state == "pending" and (tonumber(led.n) or 0) >= Friends.MAX_ATTEMPTS then
        return "skip", "add never landed"
    end

    if (ctx.numFriends or 0) + planned >= (ctx.maxFriends or Friends.FRIEND_CAP_FALLBACK) then
        return "cap", "friends list is full"
    end

    return "add", nil
end

----------------------------------------------------------------------
-- THE PLAN  (pure)
--
-- One deterministic sweep, key order. Each planned add consumes a friends-list
-- slot, so a batch that would run past the cap stops at exactly the right entry
-- instead of firing doomed AddFriend calls.
--
-- Returns plan(array of { key, entry, action, reason }), refusal(string|nil).
-- A refusal means the pass must not touch ANYTHING — not the game, not the
-- ledger. The plan is empty in that case.
----------------------------------------------------------------------
function Friends.Plan(roster, ctx)
    ctx = ctx or {}
    if not ctx.enabled       then return {}, "auto-friend is off" end
    if not ctx.listConfirmed then return {}, "friends list not confirmed yet" end

    local keys = {}
    for key in pairs(roster or {}) do
        if type(key) == "string" then keys[#keys + 1] = key end
    end
    table.sort(keys)

    local plan, planned = {}, 0
    for i = 1, math.min(#keys, Friends.MAX_ROSTER) do
        local key = keys[i]
        local action, reason = Friends.Decide(key, roster[key], ctx, planned)
        plan[#plan + 1] = { key = key, entry = roster[key], action = action, reason = reason }
        if action == "add" then planned = planned + 1 end
    end
    return plan, nil
end

-- Count the interesting actions in a plan. Pure; used by the runtime for its one
-- chat line and by the selftest for its assertions.
function Friends.Tally(plan)
    local t = { add = 0, mark = 0, noop = 0, cap = 0, skip = 0 }
    for _, step in ipairs(plan or {}) do
        t[step.action] = (t[step.action] or 0) + 1
    end
    return t
end

-- ════════════════════════════════════════════════════════════════════════════
--  STORE ACCESS  (SavedVariables — every key additive, schema unchanged)
-- ════════════════════════════════════════════════════════════════════════════

local function settings()
    return ns.Store and ns.Store.GetSettings and ns.Store.GetSettings() or nil
end

-- The setting. ABSENT MEANS ON: the feature ships enabled, and every save
-- written before the key existed must read as enabled too.
function Friends.IsEnabled()
    local db = settings()
    if not db then return true end
    return db.autoFriendMesh ~= false
end

-- Disabling stops FUTURE passes. It never removes a friend and never touches the
-- ledger, so re-enabling picks up exactly where it left off.
function Friends.SetEnabled(on)
    local db = settings()
    if not db then return end
    db.autoFriendMesh = on and true or false
end

-- This character's key ("Name-Realm" with the realm space-stripped — the same
-- spelling tracker.lua files our own records under).
function Friends.SelfNameRealm()
    local name  = (UnitName and UnitName("player")) or ""
    local realm = (GetRealmName and GetRealmName()) or ""
    return name .. "-" .. (realm:gsub("%s+", ""))
end

-- The ledger for THIS character. Created lazily inside DaseekiNexusData under
-- its own key, versioned independently of STORAGE_VERSION — purely additive, so
-- an existing save grows the table and loses nothing.
function Friends.Ledger()
    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    if type(data) ~= "table" then return {} end
    local mf = data.meshFriends
    if type(mf) ~= "table" then
        mf = { schema = Friends.LEDGER_SCHEMA, chars = {} }
        data.meshFriends = mf
    end
    if type(mf.chars) ~= "table" then mf.chars = {} end
    local me = Friends.SelfNameRealm()
    if type(mf.chars[me]) ~= "table" then mf.chars[me] = {} end
    return mf.chars[me]
end

----------------------------------------------------------------------
-- CONDUIT'S LEDGER  (read-only, absent-safe)
--
-- DaseekiConduitDB.friended[charKey][dirKey] = true. Conduit's charKey keeps the
-- realm's spaces; ours strips them, so both spellings are probed. Returns nil
-- when Conduit is not installed / has never written one — and nil changes
-- nothing about the pass.
----------------------------------------------------------------------
function Friends.ConduitLedger()
    local db = _G.DaseekiConduitDB
    if type(db) ~= "table" then return nil end
    local friended = db.friended
    if type(friended) ~= "table" then return nil end

    local name  = (UnitName and UnitName("player")) or ""
    local realm = (GetRealmName and GetRealmName()) or ""
    local out, any = {}, false
    local candidates = { name .. "-" .. realm, name .. "-" .. (realm:gsub("%s+", "")) }
    for _, ck in ipairs(candidates) do
        local t = friended[ck]
        if type(t) == "table" then
            for k, v in pairs(t) do
                if type(k) == "string" and v then out[k], any = true, true end
            end
        end
    end
    if not any then return nil end
    return out
end

-- ════════════════════════════════════════════════════════════════════════════
--  RUNTIME  (in-game only)
-- ════════════════════════════════════════════════════════════════════════════

Friends._listConfirmed = false   -- a FRIENDLIST_UPDATE has answered our request
Friends._requested     = false   -- we have called ShowFriends this session
Friends._attempted     = {}      -- [key] = true, AddFriend issued this session
Friends._known         = nil     -- last seen roster key set (roster-growth diff)
Friends._lastPlan      = nil     -- for /nexus debug friends

local function friendCap()
    return tonumber(_G.MAX_FRIENDS) or Friends.FRIEND_CAP_FALLBACK
end

-- The live friends list as { [lowered base name] = true }, plus its size.
-- Returns nil when the API is unavailable — the caller then does nothing at all.
function Friends.FriendSet()
    local C = _G.C_FriendList
    if not (C and C.GetNumFriends and C.GetFriendInfoByIndex) then return nil, 0 end
    local set = {}
    local n = C.GetNumFriends() or 0
    for i = 1, n do
        local info = C.GetFriendInfoByIndex(i)
        local nm = info and info.name
        if type(nm) == "string" and nm ~= "" then
            set[(nm:match("^([^%-]+)") or nm):lower()] = true
        end
    end
    return set, n
end

-- Who we are right now, for deciding.
function Friends.LiveContext()
    local faction = _G.UnitFactionGroup and UnitFactionGroup("player") or nil
    if faction ~= "Alliance" and faction ~= "Horde" then faction = nil end
    local me = Friends.SelfNameRealm()
    return {
        me      = Friends.Key(me) or "",
        realm   = Friends.NormalizeRealm((GetRealmName and GetRealmName()) or ""),
        faction = faction,
    }
end

-- Assemble the injected world the pure layer decides against.
function Friends.BuildContext(set, n)
    local live = Friends.LiveContext()
    return {
        enabled       = Friends.IsEnabled(),
        listConfirmed = Friends._listConfirmed and true or false,
        me            = live.me,
        realm         = live.realm,
        faction       = live.faction,
        friends       = set or {},
        ledger        = Friends.Ledger(),
        conduit       = Friends.ConduitLedger(),
        attempted     = Friends._attempted,
        numFriends    = n or 0,
        maxFriends    = friendCap(),
        now           = (_G.time and time()) or 0,
    }
end

-- AddFriend, failure-tolerant. Deliberately a bare pcall rather than ns:SafeCall:
-- the owner's directive for this call is "no error spam", and SafeCall routes to
-- geterrorhandler by design. A refused add leaves a pending ledger entry, which
-- is retried on the next natural trigger and blocked after MAX_ATTEMPTS.
local function addFriendQuietly(name)
    local C = _G.C_FriendList
    if not (C and C.AddFriend) then return false end
    local ok = pcall(C.AddFriend, name)
    return ok
end

----------------------------------------------------------------------
-- THE PASS
--
-- Idempotent by construction: a pass with nothing to do writes nothing, says
-- nothing, and leaves the ledger byte-identical.
----------------------------------------------------------------------
function Friends.RunPass()
    if Friends._running then return end
    if not Friends.IsEnabled() then return end

    -- REFUSAL GATE. An unconfirmed list is not diffable, and nothing below this
    -- line — not one ledger byte — may run against one.
    if not Friends._listConfirmed then return end

    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    if type(data) ~= "table" or type(data.accounts) ~= "table" then return end

    local C = _G.C_FriendList
    if not (C and C.AddFriend) then return end
    local set, n = Friends.FriendSet()
    if not set then return end

    Friends._running = true

    local ctx    = Friends.BuildContext(set, n)
    local ledger = ctx.ledger
    Friends.Reconcile(ledger, ctx)

    local roster = Friends.CollectRoster(data.accounts, { selfAID = ns:GetAccountID() })
    local plan, refusal = Friends.Plan(roster, ctx)
    Friends._lastPlan = plan

    local added = {}
    if not refusal then
        for _, step in ipairs(plan) do
            if step.action == "add" then
                local prev = ledger[step.key]
                local tries = (type(prev) == "table" and tonumber(prev.n) or 0) + 1
                Friends._attempted[step.key] = true
                addFriendQuietly(step.entry.name)
                ledger[step.key] = { s = "pending", ts = ctx.now, n = tries }
                added[#added + 1] = step.entry.name
            elseif step.action == "mark" then
                ledger[step.key] = { s = "preexisting", ts = ctx.now, n = 0 }
            end
            -- "cap" stops nothing here: Plan already emitted "cap" for every
            -- entry past the ceiling and no AddFriend is issued for them. Quiet
            -- by directive — no chat line for a full list.
        end
    end

    -- The roster snapshot is the baseline for the next growth check.
    Friends._known = {}
    for key in pairs(roster) do Friends._known[key] = true end

    Friends._running = false

    if #added == 1 then
        ns:Print(("added %s to your friends list (mesh character on another account)."):format(added[1]))
    elseif #added > 1 then
        ns:Print(("added %d mesh characters from your other accounts to your friends list: %s")
            :format(#added, table.concat(added, ", ")))
    end
end

-- Debounced pass. One timer at a time; the first request wins the slot.
function Friends.SchedulePass(delay)
    if Friends._scheduled then return end
    Friends._scheduled = true
    if _G.C_Timer and C_Timer.After then
        C_Timer.After(delay or 1, function()
            Friends._scheduled = false
            ns:SafeCall(Friends.RunPass)
        end)
    else
        Friends._scheduled = false
        ns:SafeCall(Friends.RunPass)
    end
end

----------------------------------------------------------------------
-- TRIGGER 1 — LOGIN
--
-- ShowFriends asks the server for the list; FRIENDLIST_UPDATE is the answer.
-- Only an update that arrives AFTER our request counts as confirmation, so an
-- early event fired for some other reason cannot green-light a dark list. If no
-- answer ever comes, this character does nothing this session — deliberately.
----------------------------------------------------------------------
local REQUEST_AT = { 5, 15, 30 }   -- seconds after login; bounded, then we stop

function Friends.RequestList()
    local C = _G.C_FriendList
    if not (C and C.ShowFriends) then return end
    Friends._requested = true
    pcall(C.ShowFriends)
end

-- Public read of the refusal gate's state. social.lua (the §12.2 friends trust
-- set) needs the same "is this list real or dark?" answer this module needed
-- first, and must not keep a second copy of it.
function Friends.ListConfirmed()
    return Friends._listConfirmed and true or false
end

-- REQUESTING IS NOT GATED ON THE AUTO-FRIEND SETTING.
--
-- It used to be, and that quietly coupled two features: with "auto-friend mesh
-- characters" off, ShowFriends was never called, FRIENDLIST_UPDATE never
-- confirmed anything, and any other consumer of the confirmed list (social.lua's
-- friends trust set) was dark forever. Asking the server for the friends list is
-- what the default UI does when you open the social pane — it adds, removes and
-- decides nothing. The PASS is still gated: RunPass refuses when the setting is
-- off, and the ledger is untouched.
ns:RegisterEvent("PLAYER_LOGIN", function()
    Friends._listConfirmed = false
    Friends._requested     = false
    Friends._attempted     = {}
    Friends._known         = nil
    for _, at in ipairs(REQUEST_AT) do
        if _G.C_Timer and C_Timer.After then
            C_Timer.After(at, function()
                if Friends._listConfirmed then return end
                ns:SafeCall(Friends.RequestList)
            end)
        end
    end
end)

ns:RegisterEvent("FRIENDLIST_UPDATE", function()
    if not Friends._requested then return end       -- not an answer to us (yet)
    local first = not Friends._listConfirmed
    Friends._listConfirmed = true
    -- Announced on the bus so a consumer never has to race this handler's
    -- registration order to learn the list went live. Fired before the pass so
    -- the trust set is captured from the list as it stands, not as our own
    -- AddFriend calls are about to leave it.
    if first then ns:Fire("FRIENDS_LIST_CONFIRMED") end
    if Friends.IsEnabled() then Friends.SchedulePass(1) end
end)

----------------------------------------------------------------------
-- TRIGGER 2 — ROSTER GROWTH
--
-- mesh.lua fires STORE_REFRESHED whenever the character graph changes. Only a
-- NEW Name-Realm is a reason to run: the pass is idempotent, but a pass per
-- inbound state frame would be noise for nothing.
----------------------------------------------------------------------
ns:On("STORE_REFRESHED", function()
    if not Friends.IsEnabled() then return end
    if not Friends._listConfirmed then return end
    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    if type(data) ~= "table" or type(data.accounts) ~= "table" then return end
    local roster = Friends.CollectRoster(data.accounts, { selfAID = ns:GetAccountID() })
    if Friends._known and #Friends.NewKeys(roster, Friends._known) == 0 then return end
    Friends.SchedulePass(2)
end)

----------------------------------------------------------------------
-- Diagnostics — /nexus debug friends
----------------------------------------------------------------------
ns:RegisterDebugCommand("friends", function()
    ns:Print("mesh auto-friend: " .. (Friends.IsEnabled() and "ON" or "off"))
    ns:Print("  friends list: " .. (Friends._listConfirmed and "confirmed" or
        (Friends._requested and "requested, waiting for FRIENDLIST_UPDATE" or "not requested yet")))
    local set, n = Friends.FriendSet()
    ns:Print(("  entries: %s of %d"):format(set and tostring(n) or "unavailable", friendCap()))
    local conduit = Friends.ConduitLedger()
    local cn = 0
    for _ in pairs(conduit or {}) do cn = cn + 1 end
    ns:Print(("  Conduit ledger: %s"):format(conduit and (cn .. " name(s) honoured") or "absent"))

    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    if not (set and data and data.accounts) then return end
    local ctx    = Friends.BuildContext(set, n)
    local roster = Friends.CollectRoster(data.accounts, { selfAID = ns:GetAccountID() })
    local plan, refusal = Friends.Plan(roster, ctx)
    if refusal then
        ns:Print("  pass would refuse: " .. refusal)
        return
    end
    if #plan == 0 then
        ns:Print("  no mesh characters known yet.")
        return
    end
    for _, step in ipairs(plan) do
        local e = step.entry
        ns:Print(("  %s (%s/%s)%s -> %s%s"):format(
            tostring(e.name), tostring(e.realm ~= "" and e.realm or "?"),
            tostring(e.faction or "?"), e.own and " [own account]" or "",
            step.action, step.reason and (" — " .. step.reason) or ""))
    end
end)

-- ════════════════════════════════════════════════════════════════════════════
--  SELFTEST  (rule-per-rule, through the real collector + planner)
--
--  Every assertion below drives the SHIPPING functions — CollectRoster builds
--  the roster from a real accounts-graph fixture, Reconcile and Plan are the
--  ones the pass calls. The executor's ledger writes are replayed by a tiny
--  in-suite applier that mirrors RunPass's loop exactly, so "second pass adds
--  nothing" is a statement about the shipped logic, not about the test.
-- ════════════════════════════════════════════════════════════════════════════

ns:RegisterSelfTest("meshfriends", function(verbose)
    local pass = true
    local function ck(cond, msg)
        if not cond then
            pass = false
            if verbose then ns:Print("  FAIL meshfriends/" .. msg) end
        end
    end

    local ME_KEY = "tester-testrealm"

    -- A bounded, hand-built accounts graph in exactly the store's shape.
    --   aid "1" (self)  : Tester (us), Bankalt (our own alt — must be skipped)
    --   aid "2"         : Meshmate (same faction), Crossy (other faction),
    --                     Faceless (faction never captured), Offrealm
    --   aid ""  (orphan): Nobody (no account attribution at all)
    local function fixture()
        return {
            ["1"] = {
                isSelf = true,
                characters = {
                    ["Tester-TestRealm"]  = { faction = "Horde" },
                    ["Bankalt-TestRealm"] = { faction = "Horde" },
                },
                homeless = {},
            },
            ["2"] = {
                isSelf = false,
                characters = {
                    ["Meshmate-TestRealm"] = { faction = "Horde" },
                    ["Crossy-TestRealm"]   = { faction = "Alliance" },
                    ["Faceless-TestRealm"] = { faction = nil },
                    ["Offrealm-Faerlina"]  = { faction = "Horde" },
                },
                homeless = {},
            },
            [""] = {
                isSelf = false,
                characters = { ["Nobody-TestRealm"] = { faction = "Horde" } },
                homeless = {},
            },
        }
    end

    local function baseCtx(over)
        local c = {
            enabled = true, listConfirmed = true,
            me = ME_KEY, realm = "testrealm", faction = "Horde",
            friends = {}, ledger = {}, conduit = nil, attempted = {},
            numFriends = 0, maxFriends = 100, now = 1000,
        }
        for k, v in pairs(over or {}) do c[k] = v end
        return c
    end

    local function actionOf(plan, key)
        for _, s in ipairs(plan) do if s.key == key then return s.action, s.reason end end
        return nil
    end

    -- The executor's ledger loop, verbatim in behaviour, plus a fake friends
    -- list so "the add landed" can be simulated (or not).
    local function apply(plan, ctx, opts)
        opts = opts or {}
        local added = {}
        for _, step in ipairs(plan) do
            if step.action == "add" then
                local prev = ctx.ledger[step.key]
                local tries = (type(prev) == "table" and tonumber(prev.n) or 0) + 1
                ctx.attempted[step.key] = true
                ctx.ledger[step.key] = { s = "pending", ts = ctx.now, n = tries }
                added[#added + 1] = step.entry.name
                if not opts.addsFail then
                    ctx.friends[step.entry.name:lower()] = true
                    ctx.numFriends = ctx.numFriends + 1
                end
            elseif step.action == "mark" then
                ctx.ledger[step.key] = { s = "preexisting", ts = ctx.now, n = 0 }
            end
        end
        return added
    end

    ------------------------------------------------------------------
    -- 0. The collector reads the account graph the way the store writes it.
    ------------------------------------------------------------------
    local roster = Friends.CollectRoster(fixture(), { selfAID = "1" })
    ck(roster["meshmate-testrealm"] ~= nil, "collector: a peer character is collected")
    ck(roster["bankalt-testrealm"] and roster["bankalt-testrealm"].own == true,
        "collector: a self-bucket character is flagged own")
    ck(roster["meshmate-testrealm"].own == false, "collector: a peer character is not own")
    ck(roster["nobody-testrealm"] and roster["nobody-testrealm"].known == false,
        "collector: the orphan bucket gives no account attribution")
    ck(roster["meshmate-testrealm"].known == true, "collector: a real aid is attribution")
    ck(roster["faceless-testrealm"].faction == nil, "collector: an uncaptured faction stays nil")
    ck(roster["offrealm-faerlina"].realm == "faerlina", "collector: realm normalized off the key")

    -- Own-ness is STICKY: a phantom twin of our own alt filed under a peer's
    -- bucket must not make it look foreign (store.lua own-account authority).
    local twinned = fixture()
    twinned["2"].characters["Bankalt-TestRealm"] = { faction = "Horde" }
    local tRoster = Friends.CollectRoster(twinned, { selfAID = "1" })
    ck(tRoster["bankalt-testrealm"].own == true, "collector: own-ness survives a phantom twin")

    -- selfAID alone identifies our bucket even when isSelf was never stamped.
    local unflagged = fixture()
    unflagged["1"].isSelf = false
    local uRoster = Friends.CollectRoster(unflagged, { selfAID = "1" })
    ck(uRoster["bankalt-testrealm"].own == true, "collector: our aid marks our bucket without isSelf")

    -- Two buckets disagreeing about faction collapses to unknown, never a guess.
    local conflict = fixture()
    conflict["1"].homeless = { ["Meshmate-TestRealm"] = { faction = "Alliance" } }
    local cRoster = Friends.CollectRoster(conflict, { selfAID = "1" })
    ck(cRoster["meshmate-testrealm"].faction == nil, "collector: conflicting factions read as unknown")

    ------------------------------------------------------------------
    -- 1..5, 10. The skip matrix, rule per rule, through the real planner.
    ------------------------------------------------------------------
    local ctx  = baseCtx()
    local plan = Friends.Plan(roster, ctx)
    ck(actionOf(plan, "meshmate-testrealm") == "add",  "rule: same-faction cross-account is added")
    ck(actionOf(plan, "bankalt-testrealm")  == "skip", "rule: same account is skipped")
    ck(select(2, actionOf(plan, "bankalt-testrealm")) == "same account", "rule: and says why")
    ck(actionOf(plan, "crossy-testrealm")   == "skip", "rule: cross-faction is skipped")
    ck(actionOf(plan, "offrealm-faerlina")  == "skip", "rule: off-realm is skipped")
    ck(actionOf(plan, "tester-testrealm")   == "skip", "rule: self is skipped")
    ck(select(2, actionOf(plan, "tester-testrealm")) == "this character", "rule: self says why")
    ck(actionOf(plan, "faceless-testrealm") == "skip", "rule: unknown faction is skipped")
    ck(select(2, actionOf(plan, "faceless-testrealm")) == "faction unknown", "rule: and never guesses")
    ck(actionOf(plan, "nobody-testrealm")   == "skip", "rule: unknown account is skipped")
    ck(Friends.Tally(plan).add == 1, "rule: exactly one add out of the whole fixture")

    ------------------------------------------------------------------
    -- 6. Already a friend -> no add. First sighting records "preexisting".
    ------------------------------------------------------------------
    local fCtx  = baseCtx({ friends = { meshmate = true }, numFriends = 1 })
    local fPlan = Friends.Plan(roster, fCtx)
    ck(actionOf(fPlan, "meshmate-testrealm") == "mark", "rule: an existing friend is marked, not added")
    ck(Friends.Tally(fPlan).add == 0, "rule: an existing friend costs zero adds")
    apply(fPlan, fCtx)
    ck(fCtx.ledger["meshmate-testrealm"].s == "preexisting", "ledger: preexisting recorded")
    local fPlan2 = Friends.Plan(roster, fCtx)
    ck(actionOf(fPlan2, "meshmate-testrealm") == "noop", "rule: a known existing friend is a no-op")

    -- ...and a preexisting friend the owner later removes is blocked, not re-added.
    fCtx.friends = {}
    fCtx.numFriends = 0
    Friends.Reconcile(fCtx.ledger, fCtx)
    ck(fCtx.ledger["meshmate-testrealm"].s == "blocked", "ledger: removing a preexisting friend blocks it")
    ck(actionOf(Friends.Plan(roster, fCtx), "meshmate-testrealm") == "skip",
        "rule: a removed preexisting friend is never re-added")

    ------------------------------------------------------------------
    -- 7. THE LEDGER, adversarially.
    ------------------------------------------------------------------
    -- (a) A blocked entry written in a PRIOR session (all we have is the table).
    local pCtx = baseCtx({ ledger = { ["meshmate-testrealm"] = { s = "blocked", ts = 1, n = 1,
                                                                 why = "removed by you" } } })
    Friends.Reconcile(pCtx.ledger, pCtx)
    ck(pCtx.ledger["meshmate-testrealm"].s == "blocked", "ledger: a prior-session block survives reconcile")
    ck(actionOf(Friends.Plan(roster, pCtx), "meshmate-testrealm") == "skip",
        "ledger: a prior-session block skips the add")

    -- (b) SAME SESSION: add -> confirmed -> the owner unfriends -> we must not
    --     re-add on the very next pass.
    local sCtx  = baseCtx()
    local sPlan = Friends.Plan(roster, sCtx)
    apply(sPlan, sCtx)                                   -- add lands, list updates
    ck(sCtx.ledger["meshmate-testrealm"].s == "pending", "ledger: an issued add is pending")
    Friends.Reconcile(sCtx.ledger, sCtx)
    ck(sCtx.ledger["meshmate-testrealm"].s == "added", "ledger: seeing them confirms the add")
    sCtx.friends["meshmate"] = nil                       -- the owner unfriends, mid-session
    sCtx.numFriends = sCtx.numFriends - 1
    sCtx.attempted = {}                                  -- a fresh trigger would clear this
    Friends.Reconcile(sCtx.ledger, sCtx)
    ck(sCtx.ledger["meshmate-testrealm"].s == "blocked", "ledger: a mid-session unfriend is blocked")
    ck(sCtx.ledger["meshmate-testrealm"].why == "removed by you", "ledger: and attributed to the owner")
    local sPlan2 = Friends.Plan(roster, sCtx)
    ck(actionOf(sPlan2, "meshmate-testrealm") == "skip", "ledger: no re-add in the same session")
    ck(Friends.Tally(sPlan2).add == 0, "ledger: the re-add pass adds nothing at all")

    -- (c) An add that NEVER lands stays retryable — once per trigger — and then
    --     gives up quietly instead of looping forever.
    local rCtx = baseCtx()
    for i = 1, Friends.MAX_ATTEMPTS do
        rCtx.attempted = {}                              -- next natural trigger
        local rp = Friends.Plan(roster, rCtx)
        ck(actionOf(rp, "meshmate-testrealm") == "add", "ledger: a failed add retries on trigger " .. i)
        apply(rp, rCtx, { addsFail = true })
        Friends.Reconcile(rCtx.ledger, rCtx)
    end
    ck(rCtx.ledger["meshmate-testrealm"].s == "blocked", "ledger: an add that never lands gives up")
    ck(rCtx.ledger["meshmate-testrealm"].why == "add never landed", "ledger: and says so, quietly")
    rCtx.attempted = {}
    ck(actionOf(Friends.Plan(roster, rCtx), "meshmate-testrealm") == "skip",
        "ledger: the give-up is terminal")

    -- (d) Within ONE session a pending add is attempted exactly once, so the
    --     FRIENDLIST_UPDATE our own AddFriend fires cannot start a loop.
    local lCtx = baseCtx()
    local lPlan = Friends.Plan(roster, lCtx)
    apply(lPlan, lCtx, { addsFail = true })
    ck(actionOf(Friends.Plan(roster, lCtx), "meshmate-testrealm") == "skip",
        "ledger: no second attempt inside one session")

    ------------------------------------------------------------------
    -- 7e. CONDUIT'S ledger is honoured, and its absence changes nothing.
    ------------------------------------------------------------------
    local cdCtx = baseCtx({ conduit = { ["meshmate-testrealm"] = true } })
    local cdPlan = Friends.Plan(roster, cdCtx)
    ck(actionOf(cdPlan, "meshmate-testrealm") == "skip", "conduit: its ledger skips the add")
    ck(select(2, actionOf(cdPlan, "meshmate-testrealm")) == "handled by Daseeki-Conduit",
        "conduit: and says who blocked it")
    ck(next(cdCtx.ledger) == nil, "conduit: a Conduit-blocked name writes nothing to OUR ledger")
    ck(actionOf(Friends.Plan(roster, baseCtx({ conduit = nil })), "meshmate-testrealm") == "add",
        "conduit: absent DaseekiConduitDB changes nothing")
    ck(actionOf(Friends.Plan(roster, baseCtx({ conduit = {} })), "meshmate-testrealm") == "add",
        "conduit: an empty Conduit ledger changes nothing")

    ------------------------------------------------------------------
    -- 8. AN UNPOPULATED LIST: the pass refuses, and ledgers NOBODY.
    ------------------------------------------------------------------
    local dark = baseCtx({ listConfirmed = false, friends = {}, numFriends = 0 })
    local dPlan, dRefusal = Friends.Plan(roster, dark)
    ck(#dPlan == 0 and dRefusal ~= nil, "dark list: the pass refuses to plan")
    ck(Friends.Reconcile(dark.ledger, dark) == false, "dark list: reconcile refuses too")
    ck(next(dark.ledger) == nil, "dark list: nobody is ledgered")
    -- The trap this exists for: a dark list would otherwise read every confirmed
    -- friend as removed and block them all forever.
    local trap = baseCtx({ listConfirmed = false, friends = {},
                           ledger = { ["meshmate-testrealm"] = { s = "added", ts = 1, n = 1 } } })
    Friends.Reconcile(trap.ledger, trap)
    ck(trap.ledger["meshmate-testrealm"].s == "added", "dark list: a confirmed friend is not judged removed")

    -- Disabled behaves the same way for future passes and touches nothing.
    local offCtx = baseCtx({ enabled = false })
    local offPlan, offRefusal = Friends.Plan(roster, offCtx)
    ck(#offPlan == 0 and offRefusal ~= nil, "setting: off means no plan at all")
    ck(next(offCtx.ledger) == nil, "setting: off writes nothing")

    ------------------------------------------------------------------
    -- 9. THE CAP. Quiet stop at exactly the right entry.
    ------------------------------------------------------------------
    local big = {}
    for i = 1, 8 do
        big[("peer%d-testrealm"):format(i)] =
            { name = ("Peer%d"):format(i), realm = "testrealm", faction = "Horde",
              own = false, known = true }
    end
    local capCtx  = baseCtx({ numFriends = 97, maxFriends = 100 })
    local capPlan = Friends.Plan(big, capCtx)
    local capT    = Friends.Tally(capPlan)
    ck(capT.add == 3, "cap: exactly the free slots are used")
    ck(capT.cap == 5, "cap: everything past the ceiling is a quiet cap, not an add")
    ck(actionOf(capPlan, "peer4-testrealm") == "cap", "cap: the stop lands on the right entry")
    apply(capPlan, capCtx)
    ck(capCtx.ledger["peer4-testrealm"] == nil, "cap: a capped name is not ledgered")
    ck(Friends.Tally(Friends.Plan(big, baseCtx({ numFriends = 100, maxFriends = 100 }))).add == 0,
        "cap: a full list adds nothing")

    ------------------------------------------------------------------
    -- 11. IDEMPOTENCE. A second pass over an unchanged world does nothing.
    ------------------------------------------------------------------
    local iCtx  = baseCtx()
    local i1    = Friends.Plan(roster, iCtx)
    ck(Friends.Tally(i1).add == 1, "idempotence: the first pass adds")
    apply(i1, iCtx)
    Friends.Reconcile(iCtx.ledger, iCtx)
    iCtx.attempted = {}                                   -- a brand new trigger
    local i2 = Friends.Plan(roster, iCtx)
    ck(Friends.Tally(i2).add == 0, "idempotence: the second pass adds nothing")
    ck(Friends.Tally(i2).mark == 0, "idempotence: and re-marks nothing")
    local before = iCtx.ledger["meshmate-testrealm"].s
    apply(i2, iCtx)
    ck(iCtx.ledger["meshmate-testrealm"].s == before, "idempotence: the ledger is unchanged")

    ------------------------------------------------------------------
    -- 12. ROSTER GROWTH. Exactly the new character is added.
    ------------------------------------------------------------------
    local knownSet = {}
    for key in pairs(roster) do knownSet[key] = true end

    local grown = fixture()
    grown["2"].characters["Newbie-TestRealm"] = { faction = "Horde" }
    local gRoster = Friends.CollectRoster(grown, { selfAID = "1" })
    local newKeys = Friends.NewKeys(gRoster, knownSet)
    ck(#newKeys == 1 and newKeys[1] == "newbie-testrealm", "growth: exactly one new key is seen")
    ck(#Friends.NewKeys(roster, knownSet) == 0, "growth: an unchanged roster reports no growth")

    iCtx.attempted = {}
    local gPlan = Friends.Plan(gRoster, iCtx)
    ck(Friends.Tally(gPlan).add == 1, "growth: exactly one add")
    ck(actionOf(gPlan, "newbie-testrealm") == "add", "growth: and it is the new character")
    ck(actionOf(gPlan, "meshmate-testrealm") == "noop", "growth: the existing friend stays a no-op")

    ------------------------------------------------------------------
    -- Key shape must stay byte-identical to Conduit's, or the cross-ledger
    -- read silently matches nothing.
    ------------------------------------------------------------------
    ck(Friends.Key("Bankalt-Blood Sail Buccaneers") == "bankalt-bloodsailbuccaneers",
        "key: spaces stripped and case folded, Conduit-compatible")
    ck(Friends.Key("Bankalt", "TestRealm") == "bankalt-testrealm", "key: a bare name takes the default realm")
    ck(Friends.Key("") == nil, "key: an empty name has no key")

    ------------------------------------------------------------------
    -- Ceilings hold on absurd input (headless discipline).
    ------------------------------------------------------------------
    local huge = { ["9"] = { isSelf = false, characters = {}, homeless = {} } }
    for i = 1, Friends.MAX_ROSTER + 50 do
        huge["9"].characters[("Bulk%d-TestRealm"):format(i)] = { faction = "Horde" }
    end
    local hRoster = Friends.CollectRoster(huge, { selfAID = "1" })
    local hCount = 0
    for _ in pairs(hRoster) do hCount = hCount + 1 end
    ck(hCount <= Friends.MAX_ROSTER, "ceiling: the collector stops at MAX_ROSTER")
    ck(#Friends.Plan(hRoster, baseCtx()) <= Friends.MAX_ROSTER, "ceiling: the plan stops at MAX_ROSTER")
    ck(Friends.CollectRoster(nil) ~= nil and next(Friends.CollectRoster(nil)) == nil,
        "ceiling: a missing accounts table collects nothing")

    ------------------------------------------------------------------
    -- NX-7 (CLASS 8): Reconcile sorts before MAX_LEDGER.
    --
    -- The stake: adjudication in Reconcile is PERMANENT. An entry that has spent
    -- its MAX_ATTEMPTS is written "blocked" and is never retried. So above the
    -- ceiling, an unsorted walk did not merely reorder work — it chose, by
    -- iteration luck and afresh every session, WHICH names got sentenced and
    -- which were never looked at at all.
    --
    -- The fixture is MAX_LEDGER + 200 exhausted-pending entries built from three
    -- different insertion histories holding IDENTICAL content, and it asserts its
    -- own divergence first: if the three histories walked the same way, the row
    -- below would prove nothing and that is a failure, not a pass.
    ------------------------------------------------------------------
    do
        local OF = ns.OrderFixture
        local lkeys = {}
        for i = 1, Friends.MAX_LEDGER + 200 do
            lkeys[i] = string.format("bulk%04d-testrealm", i)
        end
        -- Every entry: pending, out of attempts, and not on the friends list —
        -- so every one of them is eligible to be blocked this pass. Which 800
        -- actually are is the whole question.
        local mk = function() return { s = "pending", n = Friends.MAX_ATTEMPTS, ts = 0 } end
        local L1, L2, L3 = OF.Histories(lkeys, mk)

        ck(OF.Divergent(L1, L2, L3),
            "NX-7 fixture is not divergent — the three ledger insertion histories "
            .. "walked in the same pairs() order, so this row proves nothing")

        local rctx = { listConfirmed = true, friends = {}, now = 7000 }
        local function blockedSet(ledger)
            local _, _, nBlocked = Friends.Reconcile(ledger, rctx)
            local out = {}
            for k, e in pairs(ledger) do
                if e.s == "blocked" then out[#out + 1] = k end
            end
            table.sort(out)
            return table.concat(out, ","), nBlocked
        end
        local s1, n1 = blockedSet(L1)
        local s2, n2 = blockedSet(L2)
        local s3, n3 = blockedSet(L3)

        ck(n1 == Friends.MAX_LEDGER, "NX-7: the ceiling still holds (" .. tostring(n1)
            .. " adjudicated, expected " .. Friends.MAX_LEDGER .. ")")
        ck(s1 == s2 and s2 == s3 and n1 == n2 and n2 == n3,
            "NX-7: the SENTENCED SET differed across insertion histories — a ledger "
            .. "over MAX_LEDGER blocks a different subset of itself each session")
        ck(s1:sub(1, 20) == "bulk0001-testrealm,b",
            "NX-7: the adjudicated subset is the sorted head, not an arbitrary slice")

        -- And the ordering must not have changed the VERDICT for anything the
        -- pre-fix walk would also have reached: a ledger under the ceiling is
        -- judged entry by entry, identically, and order is irrelevant there.
        local small = { ["a-testrealm"] = { s = "pending", n = Friends.MAX_ATTEMPTS },
                        ["b-testrealm"] = { s = "added",   n = 0 },
                        ["c-testrealm"] = { s = "pending", n = 0 } }
        local ch, conf, blk = Friends.Reconcile(small,
            { listConfirmed = true, friends = { ["c"] = true }, now = 10 })
        ck(ch == true and conf == 1 and blk == 2,
            "NX-7: under the ceiling the verdicts are unchanged (1 confirmed, 2 blocked)")
        ck(small["c-testrealm"].s == "added" and small["a-testrealm"].s == "blocked"
            and small["b-testrealm"].s == "blocked",
            "NX-7: and each verdict landed on the right entry")
    end

    if verbose and pass then ns:Print("  PASS meshfriends/rules + ledger + cap + growth + NX-7 order") end
    return pass
end)
