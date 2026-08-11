-- Daseeki Nexus — core.lua
-- Addon namespace, event dispatch, local callback bus, slash routing,
-- account-ID config accessor, and the init/login lifecycle.
--
-- Clean-room build: reimplements the *functionality* of an unlicensed
-- source addon from a functional spec only. No third-party code or
-- identifiers appear here.

local ADDON, ns = ...

ns.ADDON      = ADDON
ns.DISPLAY    = "Daseeki Nexus"
ns.VERSION    = "1.1.11"      -- addon version; keep in step with the .toc.
                             -- NOT a wire version: Protocol.SCHEMA_VERSION and
                             -- Sync.VERSION are the mesh/sync schema numbers and
                             -- move only when the wire format changes.
ns.CHAT_TAG   = "|cff4fc3f7Daseeki Nexus|r"

----------------------------------------------------------------------
-- Small utilities
----------------------------------------------------------------------

-- Chat print helper (freestanding print() is catalog-verified).
function ns:Print(...)
    print(ns.CHAT_TAG .. ":", ...)
end

-- Surface layout/runtime errors to the real error handler rather than
-- swallowing them (style-guide standing rule). Returns the pcall status
-- so callers can branch, but never hides the traceback.
function ns:SafeCall(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        geterrorhandler()(err)
    end
    return ok, err
end

----------------------------------------------------------------------
-- DETERMINISTIC ITERATION (CLASS 8) — the suite-wide primitives.
--
-- `pairs()` order is a property of a table's LIFETIME (insertion history,
-- resizes, deletions), not of its content. Two clients holding IDENTICAL data
-- walk it differently, and so does the SAME client across two sessions. That is
-- harmless for a walk that visits everything and judges each entry
-- independently; it is a defect the moment the walk is TRUNCATED (a ceiling
-- decides who survives), RETRIED (a bounded queue decides who is served), or
-- FIRST-MATCH-WINS (iteration order decides identity).
--
-- THE HOUSE RULE, from friends.lua:423 (`Plan`) and Brief C's mesh helpers:
-- SORT BEFORE THE CEILING. Truncating an unsorted walk re-rolls the surviving
-- subset per call; truncating a sorted one keeps the same subset every call.
--
-- These live in core.lua rather than in a feature file because the sites that
-- need them span the whole tree (mesh, friends, store, import, timers, the two
-- UI panels) and core.lua is the one file every headless runner loads first.
-- Brief C's `Mesh.SortedKeys` is this same function under its mesh-local name.
----------------------------------------------------------------------

-- Sorted key list for a map, optionally truncated — with the sort applied BEFORE
-- the ceiling, so `limit` keeps a stable subset rather than an arbitrary one.
-- String keys only (every keyed map that reaches a ceiling in this addon is
-- string-keyed: ownerKeys, namespace keys, account ids, Name-Realms, addon ids).
-- `pred(key, value)` optionally filters BEFORE the sort, so a caller's own
-- eligibility rule cannot reintroduce iteration luck by filtering afterwards.
function ns.SortedKeys(tbl, limit, pred)
    local out = {}
    if type(tbl) ~= "table" then return out end
    for k, v in pairs(tbl) do
        if type(k) == "string" and (not pred or pred(k, v)) then
            out[#out + 1] = k
        end
    end
    table.sort(out)
    if limit and #out > limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

-- Account-id order. Account ids are 1-2 digit NUMERIC strings, so a plain string
-- sort puts "10" before "2" and the owner reads their own accounts out of order.
-- Numeric ids sort numerically and beat non-numeric ones; the "" orphan bucket
-- sorts last of all. This is the single ordering used for every account walk
-- (roster winner tiebreak, the instances panel, the debug print).
function ns.AIDLess(a, b)
    a, b = a or "", b or ""
    if a == b then return false end
    local na, nb = tonumber(a), tonumber(b)
    if na and nb then return na < nb end
    if na then return true end          -- numeric beats non-numeric
    if nb then return false end
    return a < b
end

-- Account ids of a map, in ns.AIDLess order, sorted before any ceiling.
function ns.SortedAIDs(tbl, limit, pred)
    local out = {}
    if type(tbl) ~= "table" then return out end
    for k, v in pairs(tbl) do
        if type(k) == "string" and (not pred or pred(k, v)) then
            out[#out + 1] = k
        end
    end
    table.sort(out, ns.AIDLess)
    if limit and #out > limit then
        for i = #out, limit + 1, -1 do out[i] = nil end
    end
    return out
end

----------------------------------------------------------------------
-- THE FIXTURE KIT FOR CLASS-8 ROWS (test-only; ships inert).
--
-- A determinism test that builds its table ONCE proves nothing: it observes one
-- `pairs()` order and calls it stable. So every Class-8 fixture in this addon is
-- built THREE TIMES from three different insertion histories (forward, reverse,
-- and decoys-inserted-then-deleted-then-interleaved) holding IDENTICAL content,
-- and is required to PROVE ITSELF divergent — a fixture whose three histories
-- happen to walk the same way makes its row VACUOUS, which is a failure, not a
-- pass. Transcribed from Brief C's mesh-local kit (mesh.lua §CLASS 8) so every
-- brief's rows clear the same bar.
----------------------------------------------------------------------
ns.OrderFixture = {}

-- Raw pairs() walk of a map, as a comparable string.
function ns.OrderFixture.RawWalk(t)
    local out = {}
    for k in pairs(t) do out[#out + 1] = tostring(k) end
    return table.concat(out, ",")
end

-- An ordered list, as a comparable string.
function ns.OrderFixture.Seq(list)
    local out = {}
    for i = 1, #(list or {}) do out[i] = tostring(list[i]) end
    return table.concat(out, ",")
end

-- Build one map three ways from the same keys. `mk(key)` produces the value.
function ns.OrderFixture.Histories(keys, mk)
    mk = mk or function() return true end
    local A, B, C = {}, {}, {}
    for i = 1, #keys do A[keys[i]] = mk(keys[i]) end                 -- forward
    for i = #keys, 1, -1 do B[keys[i]] = mk(keys[i]) end             -- reverse
    for i = 1, #keys do C["\1decoy" .. i] = true end                 -- churn the
    for i = 1, #keys do C["\1decoy" .. i] = nil end                  -- table's shape
    for i = 2, #keys, 2 do C[keys[i]] = mk(keys[i]) end              -- evens, then
    for i = 1, #keys, 2 do C[keys[i]] = mk(keys[i]) end              -- odds
    return A, B, C
end

-- True when the three histories really do walk differently — i.e. the fixture is
-- unkind enough for the row built on it to mean something.
function ns.OrderFixture.Divergent(A, B, C)
    local RawWalk = ns.OrderFixture.RawWalk
    local a, b, c = RawWalk(A), RawWalk(B), RawWalk(C)
    return not (a == b and b == c)
end

----------------------------------------------------------------------
-- Cross-addon API guard  (ROLLOUT_CONTINUITY_AUDIT NW-6 / release gate D-13)
--
-- Nexus declares "## Dependencies: Daseeki-Core", which guarantees SOME Core is
-- loaded — not that it is new enough. Every DaseekiUI API introduced by a
-- particular Core must therefore be fetched through here, so a stale Core costs
-- the user that one ornament plus one explanatory chat line rather than a Lua
-- error that aborts the whole dashboard build.
--
--     local Hairline = ns:CoreAPI(ns.CORE_KIT_VERSION, "the character cards",
--                                 UI and UI.Hairline)
--     if Hairline then ... end
--
-- Returns the function when it is safe to call, nil otherwise. The probe is the
-- last word in both directions: a Core too old to even have RequireCore has no
-- version to compare, and a Core that reports new enough but is missing the
-- function is still not safe to call.
----------------------------------------------------------------------

-- Core version that introduced the ledger UI kit (UI.Hairline and friends).
ns.CORE_KIT_VERSION = "2.2.0"

local coreAPITold = {}   -- caller label -> true; one line per session per site

function ns:CoreAPI(minVersion, caller, api)
    local DS = _G.DaseekiSuite
    local coreSpoke = false
    if type(DS) == "table" and type(DS.RequireCore) == "function" then
        local ok, current = pcall(DS.RequireCore, minVersion, caller)
        if ok then
            coreSpoke = true
            if not current then return nil end   -- Core printed the line itself
        end
    end
    if type(api) == "function" then return api end
    -- API missing. If Core was never able to answer (it predates RequireCore),
    -- nobody has told the user anything yet, so say it once from here.
    local key = tostring(caller or "?")
    if not coreSpoke and not coreAPITold[key] then
        coreAPITold[key] = true
        ns:Print(string.format(
            "Daseeki Core v%s needed for %s, an older Core is installed — update Daseeki-Core.",
            tostring(minVersion), tostring(caller or "this feature")))
    end
    return nil
end

----------------------------------------------------------------------
-- Event dispatch
--
-- Modules subscribe with ns:RegisterEvent(event, handler). The single
-- shared frame registers each Blizzard event once and fans out to every
-- subscribed handler. handler(event, ...) receives the raw payload.
----------------------------------------------------------------------

local eventFrame = CreateFrame("Frame", "DaseekiNexusEventFrame")
ns.eventFrame = eventFrame

local eventHandlers = {}   -- event -> array of handler fns

function ns:RegisterEvent(event, handler)
    local list = eventHandlers[event]
    if not list then
        list = {}
        eventHandlers[event] = list
        eventFrame:RegisterEvent(event)
    end
    list[#list + 1] = handler
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = eventHandlers[event]
    if not list then return end
    for i = 1, #list do
        local h = list[i]
        local ok, err = pcall(h, event, ...)
        if not ok then
            geterrorhandler()(err)
        end
    end
end)

----------------------------------------------------------------------
-- Local callback bus
--
-- In-process signalling between modules (NOT network traffic). The
-- tracker fires "STATE_CHANGED" here when a live character record moves;
-- the mesh layer (wave N2) subscribes to push those changes. For N1 the
-- bus simply exists and is exercised by the tracker.
----------------------------------------------------------------------

local callbacks = {}   -- name -> array of listener fns

function ns:On(name, listener)
    local list = callbacks[name]
    if not list then
        list = {}
        callbacks[name] = list
    end
    list[#list + 1] = listener
end

function ns:Fire(name, ...)
    local list = callbacks[name]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then
            geterrorhandler()(err)
        end
    end
end

----------------------------------------------------------------------
-- Account-ID config accessor
--
-- Account identity is a short numeric string (1-2 digits) that keys the
-- mesh roster. Stored in DaseekiNexusDB.accountID. Store owns the SV
-- defaults; these accessors are the single point of truth for reads.
----------------------------------------------------------------------

-- Validate a candidate account ID: 1-2 digit numeric string.
function ns:IsValidAccountID(v)
    if type(v) ~= "string" then return false end
    return v:match("^%d%d?$") ~= nil
end

function ns:GetAccountID()
    local db = DaseekiNexusDB
    if db and type(db.accountID) == "string" then
        return db.accountID
    end
    return ""
end

function ns:SetAccountID(v)
    if not ns:IsValidAccountID(v) then
        return false, "account ID must be a 1-2 digit number"
    end
    local db = DaseekiNexusDB
    if not db then return false, "settings not loaded yet" end
    db.accountID = v
    ns:Fire("ACCOUNT_ID_CHANGED", v)
    return true
end

----------------------------------------------------------------------
-- Slash command routing
--
-- /nexus (short /dnx) is the primary slash; /dsn and /daseekinetwork stay
-- registered as compatibility aliases (owner muscle memory). All four share
-- one dispatcher. core.lua owns the dispatcher plus the subcommands that need
-- no feature module (help / settings / account / w / debug); every other
-- subcommand is registered by its owning module via ns:RegisterSubcommand as
-- that module loads (see the .toc order — core.lua is first, so every later
-- file can register unconditionally).
----------------------------------------------------------------------

local subcommands = {}   -- name -> { fn, help }

-- Public registration so later modules can own their own subcommands.
function ns:RegisterSubcommand(name, fn, help)
    subcommands[name] = { fn = fn, help = help }
end

-- Debug sub-command + self-test registries (wave N2 addition).
--
-- Later modules register their own `/dsn debug <name>` handlers and pure-Lua
-- self-test suites here instead of editing the debug dispatcher, so parallel
-- feature branches (mesh, timers) never collide on the same lines.
local debugCommands = {}   -- name -> fn(args)
local selfTests     = {}   -- ordered { name, fn(verbose) -> ok, results }

function ns:RegisterDebugCommand(name, fn)
    debugCommands[name] = fn
end

function ns:RegisterSelfTest(name, fn)
    selfTests[#selfTests + 1] = { name = name, fn = fn }
end

-- Run the protocol suite plus every registered module suite. Returns overall
-- pass boolean; prints per-suite headers when verbose.
function ns:RunRegisteredSelfTests(verbose)
    local allPass = true
    if ns.Protocol and ns.Protocol.RunSelfTests then
        if verbose then ns:Print("selftest: protocol") end
        local ok = ns.Protocol.RunSelfTests(verbose)
        allPass = allPass and ok
    end
    for i = 1, #selfTests do
        if verbose then ns:Print("selftest: " .. selfTests[i].name) end
        local ok = selfTests[i].fn(verbose)
        allPass = allPass and ok
    end
    if verbose then
        ns:Print(allPass and "selftest: ALL SUITES PASS"
                          or "selftest: FAILURES ABOVE")
    end
    return allPass
end

ns._debugCommands = debugCommands

-- Short, chat-appropriate command list. The Help page in the settings hub
-- (options.lua) is the complete reference; this stays skimmable in one screen,
-- so the debug family is summarized on one line rather than enumerated.
local function printHelp()
    ns:Print("commands (primary /nexus; short /dnx; aliases /dsn, /daseekinetwork):")
    ns:Print("  /nexus toggle           - show/hide the dashboard")
    ns:Print("  /nexus x                - cancel-buffs popup (alias: cancelbuffs)")
    ns:Print("  /nexus invite           - invite all online mesh characters")
    ns:Print("  /nexus mover            - show the mover for the pull-timer bars")
    ns:Print("  /nexus resetui          - reset dashboard layout (alias: reset)")
    ns:Print("  /nexus account <id>     - show/set this account's mesh ID")
    ns:Print("  /nexus w <Char[-Server]> <msg> - whisper (server optional -> own realm)")
    ns:Print("  /nexus syncsettings     - push your settings to the mesh")
    ns:Print("  /nexus import [dry]     - import ShadowNetwork settings & data")
    ns:Print("  /nexus import instances [dry] - import NovaInstanceTracker runs")
    ns:Print("  /nexus settings         - open the Daseeki hub to Nexus settings")
    ns:Print("  /nexus debug <sub>      - diagnostics (selftest, timers, mesh, auras, layout, ...)")
    ns:Print("  /nexus help             - this list")
    ns:Print("full list: /nexus settings -> Help.")
end

ns:RegisterSubcommand("help", printHelp, "show command list")

-- Open the Daseeki hub to the Nexus settings section (options.lua owns the
-- pages; this is just the slash entry point). Guards on the hub being present.
ns:RegisterSubcommand("settings", function()
    if _G.DaseekiSuite and DaseekiSuite.Open then
        DaseekiSuite:Open("nexus")
    else
        ns:Print("the Daseeki hub (Daseeki Core) is not available.")
    end
end, "open Nexus settings")

ns:RegisterSubcommand("account", function(rest)
    rest = rest and rest:match("^%s*(.-)%s*$") or ""
    if rest == "" then
        local id = ns:GetAccountID()
        if id == "" then
            ns:Print("no account ID set. Use /nexus account <1-2 digit number>.")
        else
            ns:Print("account ID: " .. id)
        end
        return
    end
    local ok, err = ns:SetAccountID(rest)
    if ok then
        ns:Print("account ID set to " .. rest .. ".")
    else
        ns:Print("could not set account ID: " .. tostring(err))
    end
end, "show/set account ID")

-- Whisper helper (item 12): `/nexus w <Char[-Server]> <message...>`. A bare
-- character name (no "-Server") targets our own realm. Parsing + normalization
-- are pure (ns.ParseWhisper) so the routing is self-testable; the actual
-- SendChatMessage is user-initiated (the owner typed the command).
function ns:ParseWhisper(rest, ownRealm)
    rest = rest and rest:match("^%s*(.-)%s*$") or ""
    if rest == "" then return nil, nil, "usage: /nexus w <Char[-Server]> <message>" end
    local target, message = rest:match("^(%S+)%s+(.+)$")
    if not target or not message or message == "" then
        return nil, nil, "usage: /nexus w <Char[-Server]> <message>"
    end
    if not target:find("-", 1, true) then
        ownRealm = ownRealm or ""
        if ownRealm ~= "" then target = target .. "-" .. ownRealm end
    end
    return target, message
end

ns:RegisterSubcommand("w", function(rest)
    local ownRealm = (GetNormalizedRealmName and GetNormalizedRealmName())
        or (GetRealmName and (GetRealmName():gsub("%s+", ""))) or ""
    local target, message, err = ns:ParseWhisper(rest, ownRealm)
    if not target then
        ns:Print(err)
        return
    end
    if SendChatMessage then
        SendChatMessage(message, "WHISPER", nil, target)
    end
end, "whisper a character (server optional)")

ns:RegisterSubcommand("debug", function(rest)
    rest = rest and rest:match("^%s*(.-)%s*$") or ""
    local sub, args = rest:match("^(%S*)%s*(.-)$")
    sub = (sub or ""):lower()
    if sub == "selftest" or sub == "" then
        ns:RunRegisteredSelfTests(true)
        return
    end
    local handler = debugCommands[sub]
    if handler then
        handler(args)
    else
        ns:Print("unknown debug command: " .. sub)
    end
end, "debug tools")

local function dispatch(msg)
    msg = msg or ""
    local cmd, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    if cmd == "" then
        cmd = "help"
    end
    local entry = subcommands[cmd]
    if entry then
        entry.fn(rest)
    else
        ns:Print("unknown command '" .. cmd .. "'. Try /nexus help.")
    end
end

-- Primary + short slash; /dsn and /daseekinetwork kept as compat aliases
-- (owner muscle memory — cheap to preserve, avoids breaking existing macros).
SLASH_DASEEKINEXUS1 = "/nexus"
SLASH_DASEEKINEXUS2 = "/dnx"
SLASH_DASEEKINEXUS3 = "/dsn"
SLASH_DASEEKINEXUS4 = "/daseekinetwork"
SlashCmdList["DASEEKINEXUS"] = dispatch

----------------------------------------------------------------------
-- Lifecycle
--
-- ADDON_LOADED   -> Store initialises both SavedVariables (defaults +
--                   version-stamped wipe). Must run before any read.
-- PLAYER_LOGIN   -> modules that need a live world go active; Tracker
--                   binds its hooks and takes a first snapshot.
-- PLAYER_LOGOUT  -> retention/flush hooks (final network flush lands N2).
----------------------------------------------------------------------

ns.state = { loaded = false, loggedIn = false }

-- Self-test for the whisper-helper parser (item 12).
ns:RegisterSelfTest("core", function(verbose)
    local pass = true
    local function ck(c, m) if not c then pass = false; if verbose then ns:Print("  FAIL core/" .. m) end end end
    local tgt, msg = ns:ParseWhisper("Bob hi there", "Whitemane")
    ck(tgt == "Bob-Whitemane" and msg == "hi there", "bare name gets own realm")
    tgt, msg = ns:ParseWhisper("Bob-Faerlina hello", "Whitemane")
    ck(tgt == "Bob-Faerlina" and msg == "hello", "explicit realm preserved")
    tgt, msg = ns:ParseWhisper("Bob multiple word message here", "Whitemane")
    ck(tgt == "Bob-Whitemane" and msg == "multiple word message here", "multi-word message kept")
    local t2 = ns:ParseWhisper("", "Whitemane")
    ck(t2 == nil, "empty input rejected")
    local t3 = ns:ParseWhisper("BobOnly", "Whitemane")
    ck(t3 == nil, "target without message rejected")

    ------------------------------------------------------------------
    -- ns:CoreAPI — the NW-6 cross-addon guard. Every branch below must end in
    -- "returns the function" or "returns nil", never in an error.
    ------------------------------------------------------------------
    local G = _G
    local savedSuite = G.DaseekiSuite
    local said = {}
    local realPrint = ns.Print
    ns.Print = function(_, ...) said[#said + 1] = table.concat({ ... }, " ") end
    local probe = function() return "drew" end

    -- (a) Current Core: the API comes back and nobody says anything.
    G.DaseekiSuite = { RequireCore = function() return true end }
    ck(ns:CoreAPI("2.2.0", "case a", probe) == probe, "current Core hands back the API")
    ck(#said == 0, "current Core is silent")

    -- (b) Stale Core: nil back, and Nexus stays quiet because Core printed.
    G.DaseekiSuite = { RequireCore = function() return false end }
    ck(ns:CoreAPI("2.2.0", "case b", probe) == nil, "stale Core withholds the API")
    ck(#said == 0, "stale Core: Core owns the message, Nexus does not double up")

    -- (c) Core predates RequireCore AND lacks the API: Nexus must speak, once.
    G.DaseekiSuite = {}
    ck(ns:CoreAPI("2.2.0", "case c", nil) == nil, "pre-RequireCore Core without the API withholds it")
    ck(#said == 1, "pre-RequireCore Core gets exactly one line from Nexus")
    ck(said[1]:find("2.2.0", 1, true) ~= nil and said[1]:find("case c", 1, true) ~= nil,
        "the line names the version needed and the feature")
    for _ = 1, 10 do ns:CoreAPI("2.2.0", "case c", nil) end
    ck(#said == 1, "still one line after 10 more calls from the same site")

    -- (d) Core absent entirely but the API somehow present -> pass it through.
    G.DaseekiSuite = nil
    ck(ns:CoreAPI("2.2.0", "case d", probe) == probe, "the probe is the last word when Core cannot answer")

    -- (e) A Core whose RequireCore itself errors must not take Nexus with it.
    G.DaseekiSuite = { RequireCore = function() error("boom") end }
    ck(ns:CoreAPI("2.2.0", "case e", probe) == probe, "an erroring RequireCore falls back to the probe")

    -- (f) Core says current but the API is missing anyway -> still not callable.
    G.DaseekiSuite = { RequireCore = function() return true end }
    ck(ns:CoreAPI("2.2.0", "case f", nil) == nil, "a present-but-missing API is never handed back")

    ns.Print = realPrint
    G.DaseekiSuite = savedSuite

    ------------------------------------------------------------------
    -- CLASS 8 (BRIEF E): the shared ordering primitives, and the fixture kit
    -- every Class-8 row in this addon is built on.
    --
    -- These are asserted HERE, once, because six sites across five files now
    -- lean on them: if `ns.SortedKeys` ever stopped sorting before its ceiling,
    -- every one of those rows would go quietly wrong at scale, and each would
    -- have to rediscover it.
    ------------------------------------------------------------------
    local OF = ns.OrderFixture
    local keys = {}
    for i = 1, 40 do keys[i] = string.format("Key%02d", i) end
    local A, B, C = OF.Histories(keys)

    -- THE FIXTURE MUST PROVE ITSELF. If the three insertion histories walked
    -- identically, every assertion built on them would be vacuous — a pass that
    -- means nothing is worse than a failure, so this is a FAILURE.
    ck(OF.Divergent(A, B, C),
        "fixture kit: the three insertion histories did NOT diverge under pairs() — "
        .. "every Class-8 row built on this kit would be vacuous")

    ck(OF.Seq(ns.SortedKeys(A)) == OF.Seq(ns.SortedKeys(B))
        and OF.Seq(ns.SortedKeys(B)) == OF.Seq(ns.SortedKeys(C)),
        "SortedKeys: same content, three lifetimes, one order")

    -- SORT BEFORE THE CEILING is the whole rule: a truncated walk must keep the
    -- SAME subset every call, not merely a same-sized one.
    local cap = 7
    local tA, tB, tC = ns.SortedKeys(A, cap), ns.SortedKeys(B, cap), ns.SortedKeys(C, cap)
    ck(#tA == cap, "SortedKeys: the ceiling is honoured")
    ck(OF.Seq(tA) == OF.Seq(tB) and OF.Seq(tB) == OF.Seq(tC),
        "SortedKeys: the SURVIVING SUBSET is stable across insertion histories")
    ck(OF.Seq(tA) == "Key01,Key02,Key03,Key04,Key05,Key06,Key07",
        "SortedKeys: the survivors are the sorted head, not an arbitrary slice")

    -- The predicate filters BEFORE the sort, so a caller's eligibility rule
    -- cannot smuggle iteration order back in ahead of the ceiling.
    local pA = ns.SortedKeys(A, 3, function(k) return k:sub(-1) == "0" end)
    local pC = ns.SortedKeys(C, 3, function(k) return k:sub(-1) == "0" end)
    ck(OF.Seq(pA) == "Key10,Key20,Key30" and OF.Seq(pA) == OF.Seq(pC),
        "SortedKeys: a predicate filters before the sort, and stays stable")

    ck(#ns.SortedKeys(nil) == 0 and #ns.SortedKeys("nope") == 0,
        "SortedKeys: a non-table sorts to nothing rather than erroring")
    ck(#ns.SortedKeys({ [1] = true, ["a"] = true }) == 1,
        "SortedKeys: non-string keys are not ordered against strings")

    -- Account ids are NUMERIC strings. A plain string sort puts "10" before "2",
    -- which is the owner reading their own accounts out of order.
    local aidKeys = { "1", "2", "3", "9", "10", "11", "", "abc" }
    local aA, aB, aC = OF.Histories(aidKeys)
    ck(OF.Divergent(aA, aB, aC), "aid fixture: the three histories did NOT diverge — row is vacuous")
    ck(OF.Seq(ns.SortedAIDs(aA)) == "1,2,3,9,10,11,,abc",
        "SortedAIDs: numeric ids sort numerically, non-numeric last, orphan bucket after them")
    ck(OF.Seq(ns.SortedAIDs(aA)) == OF.Seq(ns.SortedAIDs(aB))
        and OF.Seq(ns.SortedAIDs(aB)) == OF.Seq(ns.SortedAIDs(aC)),
        "SortedAIDs: one order across three insertion histories")
    ck(ns.AIDLess("2", "10") and not ns.AIDLess("10", "2"), "AIDLess: 2 before 10, numerically")
    ck(not ns.AIDLess("3", "3"), "AIDLess: an aid does not beat itself")
    ck(ns.AIDLess("3", "abc") and not ns.AIDLess("abc", "3"), "AIDLess: numeric beats non-numeric")

    if verbose and pass then ns:Print("  PASS core/parse-whisper + coreapi guard + class-8 primitives") end
    return pass
end)

ns:RegisterEvent("ADDON_LOADED", function(_, loaded)
    if loaded ~= ADDON then return end
    if ns.Store and ns.Store.Init then
        ns.Store.Init()
    end
    ns.state.loaded = true
    ns:Fire("STORE_READY")
end)

ns:RegisterEvent("PLAYER_LOGIN", function()
    ns.state.loggedIn = true
    if ns.Store and ns.Store.OnLogin then
        ns.Store.OnLogin()
    end
    if ns.Tracker and ns.Tracker.OnLogin then
        ns.Tracker.OnLogin()
    end
    if ns.Protocol and ns.Protocol.OnLogin then
        ns.Protocol.OnLogin()
    end
    ns:Fire("LOGIN")
end)

ns:RegisterEvent("PLAYER_LOGOUT", function()
    if ns.Store and ns.Store.OnLogout then
        ns.Store.OnLogout()
    end
    ns:Fire("LOGOUT")
end)
