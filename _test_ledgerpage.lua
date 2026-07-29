-- Real-Lua 5.1 harness for ui_ledgerpage.lua (WAVE R1-B).
-- Self-contained: stubs the WoW load surface, loads the pure-logic + shared-model
-- files this page depends on (core/store/tracker/ui_shell/ui_ledgerpage), then runs
-- ONLY the "ledgerpage" self-test suite (isolated from other suites' dep needs).
-- Usage:  lua5.1 _test_ledgerpage.lua [NEXUS_DIR]   (defaults to this file's dir)

local DIR = arg[1] or (arg[0]:match("^(.*)[\\/][^\\/]+$")) or "."
DIR = (DIR:gsub("\\", "/"))
local function P(f) return DIR .. "/" .. f end

-- ── WoW-ish globals (chainable frame mock; DaseekiUI intentionally ABSENT so the
--    deferred-render contract is exercised — the page must track state frameless) ──
local frameMeta = {}
frameMeta.__index = function(t, k) return function(_, ...) return t end end
local function newFrame() return setmetatable({}, frameMeta) end
_G.CreateFrame = function() return newFrame() end
_G.UIParent = newFrame(); _G.WorldFrame = newFrame(); _G.Minimap = newFrame()
_G.GameTooltip = newFrame(); _G.UISpecialFrames = {}
_G.hooksecurefunc = function() end
_G.SlashCmdList = {}
_G.InCombatLockdown = function() return false end

local _t = 1700000000
_G.GetServerTime = function() return _t end
_G.time = function() return _t end
_G.GetTime = function() return 54321.0 end
_G.date = os.date
_G.UnitName = function() return "Tester" end
_G.GetRealmName = function() return "TestRealm" end
_G.UnitFactionGroup = function() return "Horde" end
_G.UnitLevel = function() return 60 end
_G.UnitClass = function() return "Warlock", "WARLOCK" end
_G.GetLocale = function() return "enUS" end
_G.geterrorhandler = function() return function(e) print("  [errh] " .. tostring(e)) end end
_G.RAID_CLASS_COLORS = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1 } end })
_G.C_Spell = { GetSpellTexture = function() return "Interface\\Icons\\Temp" end }
_G.C_Item  = { GetItemIconByID = function() return "Interface\\Icons\\Temp" end }
_G.C_Timer = { After = function() end, NewTicker = function() return newFrame() end, NewTimer = function() return newFrame() end }
_G.C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end, SendAddonMessage = function() return 0 end }
_G.C_PartyInfo = { InviteUnit = function() end }
_G.DaseekiNexusDB = { accountID = "1" }
_G.DaseekiNexusData = {}
_G.require = nil

-- WoW stdlib aliases the addon uses as bare globals.
_G.strmatch, _G.strfind, _G.strsub, _G.strlen = string.match, string.find, string.sub, string.len
_G.strlower, _G.strupper, _G.strrep = string.lower, string.upper, string.rep
_G.strtrim = function(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
_G.format, _G.gsub, _G.gmatch = string.format, string.gsub, string.gmatch
_G.tinsert, _G.tremove, _G.tsort = table.insert, table.remove, table.sort
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.tContains = function(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
_G.max, _G.min, _G.floor, _G.ceil, _G.abs = math.max, math.min, math.floor, math.ceil, math.abs

-- ── load addon files ──────────────────────────────────────────────────────────
local ADDON, ns = "DaseekiNexus", {}
local SUITES = {}
local function loadAddon(f)
    local fn, err = loadfile(P(f))
    if not fn then print("COMPILE FAIL " .. f .. " :: " .. tostring(err)); return false end
    local ok, rerr = pcall(fn, ADDON, ns)
    if not ok then print("  (load note: " .. f .. " :: " .. tostring(rerr) .. ")") end
    return ok
end

loadAddon("core.lua")
-- Record every registered suite by name so we can run just ours.
local origRST = ns.RegisterSelfTest
ns.RegisterSelfTest = function(self, name, fn) SUITES[name] = fn; return origRST(self, name, fn) end

loadAddon("store.lua")
loadAddon("tracker.lua")
loadAddon("ui_shell.lua")
loadAddon("ui_ledgerpage.lua")

if ns.Store and ns.Store.Init then pcall(ns.Store.Init) end

-- ── run the ledgerpage suite only ─────────────────────────────────────────────
assert(ns.Dashboard, "ns.Dashboard missing — ui_shell did not load its shared model")
assert(ns.LedgerPage, "ns.LedgerPage missing — ui_ledgerpage did not load")
local suite = SUITES["ledgerpage"]
assert(suite, "ledgerpage self-test suite not registered")
print("== ledgerpage self-test ==")
local ok = suite(true)
print(ok and "\nLEDGERPAGE: ALL PASS" or "\nLEDGERPAGE: FAILURES ABOVE")
os.exit(ok and 0 or 1)
