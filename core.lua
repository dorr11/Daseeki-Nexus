-- Daseeki Network — core.lua
-- Addon namespace, event dispatch, local callback bus, slash routing,
-- account-ID config accessor, and the init/login lifecycle.
--
-- Clean-room build: reimplements the *functionality* of an unlicensed
-- source addon from a functional spec only. No third-party code or
-- identifiers appear here.

local ADDON, ns = ...

ns.ADDON      = ADDON
ns.DISPLAY    = "Daseeki Network"
ns.VERSION    = "0.1.0-n1"
ns.CHAT_TAG   = "|cff4fc3f7Daseeki Network|r"

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
-- Event dispatch
--
-- Modules subscribe with ns:RegisterEvent(event, handler). The single
-- shared frame registers each Blizzard event once and fans out to every
-- subscribed handler. handler(event, ...) receives the raw payload.
----------------------------------------------------------------------

local eventFrame = CreateFrame("Frame", "DaseekiNetworkEventFrame")
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
-- mesh roster. Stored in DaseekiNetworkDB.accountID. Store owns the SV
-- defaults; these accessors are the single point of truth for reads.
----------------------------------------------------------------------

-- Validate a candidate account ID: 1-2 digit numeric string.
function ns:IsValidAccountID(v)
    if type(v) ~= "string" then return false end
    return v:match("^%d%d?$") ~= nil
end

function ns:GetAccountID()
    local db = DaseekiNetworkDB
    if db and type(db.accountID) == "string" then
        return db.accountID
    end
    return ""
end

function ns:SetAccountID(v)
    if not ns:IsValidAccountID(v) then
        return false, "account ID must be a 1-2 digit number"
    end
    local db = DaseekiNetworkDB
    if not db then return false, "settings not loaded yet" end
    db.accountID = v
    ns:Fire("ACCOUNT_ID_CHANGED", v)
    return true
end

----------------------------------------------------------------------
-- Slash command routing
--
-- /dsn and /daseekinetwork share one dispatcher. Subcommands mirror the
-- functional spec's surface (toggle / x / invite / coord / resetui /
-- help) as stubs this wave, plus `debug selftest` which runs the
-- protocol scaffolding's pure-Lua self-tests.
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

local function printHelp()
    ns:Print("commands:")
    ns:Print("  /dsn toggle           - show/hide the dashboard (wave N3)")
    ns:Print("  /dsn x                - cancel-buffs popup (wave N3)")
    ns:Print("  /dsn invite            - mass alt-invite (wave N4)")
    ns:Print("  /dsn coord             - manage coordinate overrides (wave N3)")
    ns:Print("  /dsn resetui           - reset dashboard layout (wave N3)")
    ns:Print("  /dsn account <id>      - show/set this account's mesh ID")
    ns:Print("  /dsn settings          - open the Daseeki hub to Network settings")
    ns:Print("  /dsn debug selftest    - run protocol self-tests")
    ns:Print("  /dsn help              - this list")
end

-- Built-in subcommands. Feature stubs announce their target wave so an
-- in-game tester knows they are intentionally inert, not broken.
local function stub(wave)
    return function()
        ns:Print("that feature arrives in wave " .. wave .. ".")
    end
end

ns:RegisterSubcommand("help",    printHelp, "show command list")
ns:RegisterSubcommand("toggle",  stub("N3"), "dashboard toggle")
ns:RegisterSubcommand("x",       stub("N3"), "cancel-buffs popup")
ns:RegisterSubcommand("invite",  stub("N4"), "mass invite")
ns:RegisterSubcommand("coord",   stub("N3"), "coordinate overrides")
ns:RegisterSubcommand("coords",  stub("N3"), "coordinate overrides")
ns:RegisterSubcommand("resetui", stub("N3"), "reset dashboard layout")
ns:RegisterSubcommand("reset",   stub("N3"), "reset dashboard layout")

-- Open the Daseeki hub to the Network settings section (options.lua owns the
-- pages; this is just the slash entry point). Guards on the hub being present.
ns:RegisterSubcommand("settings", function()
    if _G.DaseekiSuite and DaseekiSuite.Open then
        DaseekiSuite:Open("network")
    else
        ns:Print("the Daseeki hub (Daseeki Core) is not available.")
    end
end, "open Network settings")

ns:RegisterSubcommand("account", function(rest)
    rest = rest and rest:match("^%s*(.-)%s*$") or ""
    if rest == "" then
        local id = ns:GetAccountID()
        if id == "" then
            ns:Print("no account ID set. Use /dsn account <1-2 digit number>.")
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
        ns:Print("unknown command '" .. cmd .. "'. Try /dsn help.")
    end
end

SLASH_DASEEKINETWORK1 = "/dsn"
SLASH_DASEEKINETWORK2 = "/daseekinetwork"
SlashCmdList["DASEEKINETWORK"] = dispatch

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
