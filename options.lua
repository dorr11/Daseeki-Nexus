-- Daseeki Nexus — options.lua  (WAVE N3c: HUB SETTINGS)
-- Every Settings/Auto/Auras surface from the UI spec (§§2/7/8) recomposed as
-- DaseekiUI flow-API pages living in the Daseeki hub (design decision D1). The
-- dashboard keeps a gear button that jumps here.
--
-- Clean-room: no unlicensed-source code or identifiers. This file owns options.lua plus
-- one additive core.lua hunk (a /dsn settings subcommand → hub open). It calls,
-- never edits, the parallel-owned surfaces (ns.HUD.ShowMover / ns.HUD.TestAlert)
-- through nil-guarded soft guards with a defined expected signature:
--     ns.HUD.ShowMover()                    -- open the pull-bar mover overlay
--     ns.HUD.TestAlert(buffKey, eventKey)   -- fire one test alert through the
--                                              dispatcher for a matrix cell
--
-- Section map (spec's 9 sub-tabs → 7 scannable pages, style-guide consolidation):
--   General          = General + Locations + Colors
--   Mesh & Accounts  = Mesh (Generate credentials · Copy/Paste setup bundle ·
--                      Setup guide wizard) + Accounts + Tombstones
--   Auras            = per-faction thresholds + Rend/Battle-Shout class rules
--   Automation       = Auto (Group / Accept Summon / Gossip / Quest / Interact)
--   Timers           = Raid overrides + pull-bar geometry + Felwood pins/songflower
--   Alerts           = event×channel alert matrix + sound channel
--   Blacklist        = Blacklist / Whitelist + sync + purge
--
-- Every control maps 1:1 to a field in the store defaults tree (store.lua). No
-- schema changes: absent-in-store spec affordances are documented, never faked.

local ADDON, ns = ...

local Options = {}
ns.Options = Options

----------------------------------------------------------------------
-- Constants / catalogs (single source; no magic literals below)
----------------------------------------------------------------------

local QUESTION = "Interface\\Icons\\INV_Misc_QuestionMark"

-- The nine configurable world-buff auras (spec §2). FFF is excluded per spec.
-- Labels use the reference's "ABBR (Source)" format (round-3 item 31). spellID
-- drives the row icon only (cosmetic — GetSpellTexture, guarded).
local AURA_DEFS = {
    { key = "dmf",      label = "DMF (Sayge's Fortune)",  spellID = 23768 },  -- Sayge's Dark Fortune
    { key = "ony",      label = "Ony (Rallying Cry)",     spellID = 22888 },  -- Rallying Cry
    { key = "dmtAP",    label = "DMT AP (Fengus' Ferocity)", spellID = 22817 },  -- Fengus' Ferocity
    { key = "dmtSP",    label = "DMT SP (Slip'kik's Savvy)", spellID = 22820 },  -- Slip'kik's Savvy
    { key = "dmtStam",  label = "DMT Stam (Mol'dar's Moxie)", spellID = 22818 },  -- Mol'dar's Moxie
    { key = "songflower", label = "SF (Songflower Serenade)", spellID = 15366 },  -- Songflower Serenade
    { key = "zg",       label = "ZG (Spirit of Zandalar)", spellID = 24425 },  -- Spirit of Zandalar
    { key = "rend",     label = "Rend (Warchief's)",      spellID = 16609 },  -- Warchief's Blessing
    { key = "battleShout", label = "BS (NPC)",            spellID = 6673  },  -- Battle Shout (NPC)
}

-- The full ten summon-trigger buffs (round-3 item 23). Rendered as "ABBR - Full
-- Name" rows with spell icons. FFF is the seasonal buff (no stable spellID here —
-- cosmetic question-mark fallback).
--
-- KEY NAMESPACE — DO NOT "TIDY" THESE INTO THE AURA KEYS. The auto-summon
-- trigger keys are the ones auto.lua's Auto.SUMMON_TRIGGER_BUFFS defines, and
-- they are named after the BUFF, not its source. They are deliberately NOT the
-- aura/threshold keys used by AURA_DEFS and Store.AURA_THRESHOLD_SEEDS:
--     Ony      -> "dragonslayer"   (NOT "ony")
--     ZG       -> "zandalar"       (NOT "zg")
--     Rend     -> "warchief"       (NOT "rend")
--     DMT AP   -> "fengus"         (NOT "dmtAP")
--     DMT SP   -> "slipkik"        (NOT "dmtSP")
--     DMT Stam -> "moldar"         (NOT "dmtStam")
-- (dmf / songflower / battleShout / fff are spelled the same in both spaces,
-- which is exactly why the mismatch below was not obvious.)
--
-- These six carried the AURA keys until this batch, so ticking "Ony", "ZG",
-- "Rend" or any DMT box wrote a key Auto.ScanTriggerBuffs never reads — the box
-- appeared to work and did nothing. Store.SUMMON_TRIGGER_SEEDS seeds the engine
-- keys, so the seeded set would have rendered half-unticked against the old
-- table. The store's seeder also treats a triggers table holding ONLY these dead
-- keys as unseeded, so an install carrying the stale ticks still gets the
-- spec'd set (see Store.SeedAutoSummonDefaults).
local TRIGGER_DEFS = {
    { key = "dmf",         abbr = "DMF",      name = "Sayge's Dark Fortune",  spellID = 23768 },
    { key = "dragonslayer", abbr = "Ony",     name = "Rallying Cry of the Dragonslayer", spellID = 22888 },
    { key = "zandalar",    abbr = "ZG",       name = "Spirit of Zandalar",    spellID = 24425 },
    { key = "fengus",      abbr = "DMT AP",   name = "Fengus' Ferocity",      spellID = 22817 },
    { key = "slipkik",     abbr = "DMT SP",   name = "Slip'kik's Savvy",      spellID = 22820 },
    { key = "moldar",      abbr = "DMT Stam", name = "Mol'dar's Moxie",       spellID = 22818 },
    { key = "songflower",  abbr = "SF",       name = "Songflower Serenade",   spellID = 15366 },
    { key = "warchief",    abbr = "Rend",     name = "Warchief's Blessing",   spellID = 16609 },
    { key = "battleShout", abbr = "BS",       name = "Battle Shout",          spellID = 6673  },
    { key = "fff",         abbr = "FFF",      name = "Fervor of the Fallen (seasonal)", spellID = nil },
}
-- Exposed so the store selftest can assert the UI offers a checkbox for every
-- key the engine reads. Without that assertion the aura-key mismatch above is
-- invisible to every headless gate: the boxes render, they just do nothing.
Options.TRIGGER_DEFS = TRIGGER_DEFS

-- Classes for the Rend rule cycler (all nine) and the Battle Shout cycler
-- (melee/hunter only, per spec §2).
local REND_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local BS_CLASSES   = { "WARRIOR", "ROGUE", "HUNTER" }
-- Slip'kik's Savvy / DMT SP covers all 9 classes (same as Rend); defaults live
-- in store.lua (physical = ignored, casters = optional), editable per faction.
local SLIPKIK_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

-- THE class-rule grid roster: one row per class-ruled buff the Auras page draws.
-- `optKey` is the EXACT, CASE-SENSITIVE key this page writes into
-- GetFactionSettings().auraOpts, and it must be byte-identical to the matching
-- AURA_META[slot].thresholdKey that ui_shell reads back through
-- Dashboard.CLASS_RULED_KEYS / Dashboard.ClassRuleState. A case slip ("dmtsp"
-- for "dmtSP") writes a map nothing ever reads: the owner's click appears to
-- take, and the rule can never fire. buildAuras loops this table and the
-- "options" suite asserts it against the display side both ways, so a fourth
-- class-ruled buff cannot be added on one side only.
local CLASS_RULE_GRIDS = {
    { optKey = "rend",        classes = REND_CLASSES,
      title = "Rend — Required Classes" },
    { optKey = "battleShout", classes = BS_CLASSES,
      title = "Battle Shout — Required Classes" },
    -- Slip'kik's Savvy (DMT SP): physical damage users typically don't want it,
    -- so it ships ignored for War/Rogue/Hunter and optional for casters.
    { optKey = "dmtSP",       classes = SLIPKIK_CLASSES,
      title = "Slip'kik's Savvy (DMT SP) — Required Classes" },
}
Options.CLASS_RULE_GRIDS = CLASS_RULE_GRIDS

local CLASS_LABEL  = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue",
    PRIEST = "Priest", SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}
-- Classic faction availability for faction-filtered class rows (Gossip buff-type).
local CLASS_FACTION = { PALADIN = "Alliance", SHAMAN = "Horde" }

-- Alert matrix keys (mirror store.ALERT_BUFF_KEYS / ALERT_EVENT_TYPES exactly).
-- Per-buff meta drives the event-major layout's icon + name (round-3 item 13);
-- ALERT_BUFF_LABEL is retained as the short-name fallback.
local ALERT_BUFF_LABEL = {
    rend = "Rend", onyH = "Onyxia (Horde)", onyA = "Onyxia (Alliance)",
    nefH = "Nefarian (Horde)", nefA = "Nefarian (Alliance)",
    zg = "Zandalar", battleShout = "Battle Shout", dmf = "Darkmoon Faire",
}
local ALERT_BUFF_META = {
    rend        = { name = "Rend",             spellID = 16609 },
    onyH        = { name = "Onyxia (Horde)",   spellID = 22888 },
    onyA        = { name = "Onyxia (Alliance)", spellID = 22888 },
    nefH        = { name = "Nefarian (Horde)", spellID = nil },
    nefA        = { name = "Nefarian (Alliance)", spellID = nil },
    zg          = { name = "Zandalar",         spellID = 24425 },
    battleShout = { name = "Battle Shout",     spellID = 6673  },
    dmf         = { name = "Darkmoon Faire",   spellID = 23768 },
}
-- Reference sub-header names for the event-major matrix (round-3 item 13).
local ALERT_EVENT_LABEL = {
    questHandin = "Quest Hand-in Alerts", pullTimer = "Pull Timer / Buff Incoming",
    npcDied = "NPC Died", npcRespawned = "NPC Respawned",
    cdWarning = "CD Warning (5min / 1min)", cdExpired = "CD Expired",
    buffGain = "Buff Gain Notice",
}
-- Which buff rows appear under each event sub-header. Mirrors the reference's
-- per-event sets (round-3 items 13/24). ENGINE DEPENDENCY: the engine agent owns
-- the authoritative mapping (anticipated ns.Store.ALERT_EVENT_BUFFS); this is the
-- pre-merge fallback and is superseded by that table when present.
local ALERT_EVENT_BUFFS_FALLBACK = {
    questHandin  = { "rend", "onyH", "onyA", "nefH", "nefA", "zg" },
    pullTimer    = { "rend", "onyH", "onyA", "nefH", "nefA", "zg", "battleShout" },
    npcDied      = { "onyH", "onyA", "nefH", "nefA" },
    npcRespawned = { "onyH", "onyA", "nefH", "nefA" },
    cdWarning    = { "onyH", "onyA", "rend" },
    cdExpired    = { "onyH", "onyA", "rend" },
    buffGain     = { "rend", "onyH", "onyA", "nefH", "nefA", "zg", "battleShout", "dmf" },
}
local function alertEventBuffs(evt)
    local eng = ns.Store and ns.Store.ALERT_EVENT_BUFFS
    if type(eng) == "table" and type(eng[evt]) == "table" then return eng[evt] end
    return ALERT_EVENT_BUFFS_FALLBACK[evt] or {}
end
-- Event order for the matrix: prefer the engine's ALERT_EVENT_TYPES, else fallback.
local function alertEventOrder()
    local eng = ns.Store and ns.Store.ALERT_EVENT_TYPES
    if type(eng) == "table" and #eng > 0 then return eng end
    return { "questHandin", "pullTimer", "npcDied", "npcRespawned", "cdWarning", "cdExpired", "buffGain" }
end

-- Curated Blizzard sound choices (design D3 — built-in SoundKit IDs, zero shipped
-- assets). Store keeps the string key; the map resolves it to an ID for Test.
local SOUND_CHOICES = {
    { value = "",                  text = "None" },
    { value = "RaidWarning",       text = "Raid Warning" },
    { value = "AuctionWindowOpen", text = "Auction Open" },
    { value = "TellMessage",       text = "Whisper" },
    { value = "ReadyCheck",        text = "Ready Check" },
    { value = "PVPFlagTaken",      text = "Flag Taken" },
    { value = "LevelUp",           text = "Level Up" },
}
local SOUNDKIT_MAP = {
    RaidWarning = 8959, AuctionWindowOpen = 5274, TellMessage = 3081,
    ReadyCheck = 8960, PVPFlagTaken = 8232, LevelUp = 888,
}
local SOUND_CHANNELS = { "Master", "SFX", "Music", "Ambience", "Dialog" }

-- (The old event-level soundKeys UI was retired when the alert matrix went
-- event-major with per-row sound dropdowns — round-3 item 13/14.)

-- (Interact NPCs table removed — the Interact feature is cut suite-wide, owner
-- feedback 2b.)

-- DMF Sayge fortune buff-types (spec §7 Gossip).
local DMF_BUFF_TYPES = {
    "damage", "agility", "intellect", "spirit", "stamina", "strength", "armor", "resistance",
}
-- Effect text mirrors the reference's descriptive dropdown labels (round-3 item 30).
local DMF_BUFF_TYPE_LABEL = {
    damage = "Damage (+10% Dmg)", agility = "Agility (+10% Agi)",
    intellect = "Intellect (+10% Int)", spirit = "Spirit (+10% Spi)",
    stamina = "Stamina (+10% Sta)", strength = "Strength (+10% Str)",
    armor = "Armor (+25% Armor)", resistance = "Resistance (+25 All Res)",
}

-- Zanza pick keys (spec §7 Quest — Yojamba Zanza buffs).
local ZANZA_PICKS = {
    { key = "swiftness", label = "Swiftness of Zanza" },
    { key = "spirit",    label = "Spirit of Zanza" },
    { key = "sheen",     label = "Sheen of Zanza" },
}

local MESH_CAP = 8

----------------------------------------------------------------------
-- Mesh credential kit — generate / validate / setup-bundle codec.
--
-- All pure (no WoW globals except math.random, per mesh.lua's RNG convention)
-- so the harness can round-trip them. The bundle REUSES ns.Mesh.Pack/Unpack (the
-- LibSerialize→Deflate→channel-encode pipeline) — no new crypto is introduced —
-- and carries ONLY {channel, token}. The Account ID is deliberately excluded: it
-- must differ per account, so sharing it would break the mesh.
----------------------------------------------------------------------

-- Case-sensitive alphanumeric charset (matches Lua %w exactly: no underscore).
local CRED_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
local function randCred(n)
    local t = {}
    for i = 1, n do
        local idx = (math.random and math.random(1, #CRED_CHARS)) or 1
        t[i] = CRED_CHARS:sub(idx, idx)
    end
    return table.concat(t)
end

-- Well-formedness checks mirror mesh.lua/buildMesh: channel 16+ alnum (we mint
-- 20), token EXACTLY 6 alnum. Kept local + exposed for the wizard and harness.
local function validChannel(c) return type(c) == "string" and #c >= 16 and c:match("^%w+$") ~= nil end
local function validToken(t)   return type(t) == "string" and #t == 6  and t:match("^%w+$") ~= nil end
Options.ValidChannel, Options.ValidToken = validChannel, validToken

-- Strong random credentials. Generation NEVER enables the mesh by itself — the
-- caller writes the fields and the user still flips Enable.
function Options.GenerateChannel() return randCred(20) end
function Options.GenerateToken()   return randCred(6)  end

-- Setup bundle: "DSKB1" prefix + Mesh.Pack{ c=channel, t=token }. Returns the
-- copy/paste string, or nil if the credentials are malformed or the codec libs
-- are absent.
local BUNDLE_PREFIX = "DSKB1"
function Options.EncodeBundle(channel, token)
    if not (validChannel(channel) and validToken(token)) then return nil end
    if not (ns.Mesh and ns.Mesh.Pack) then return nil end
    local body = ns.Mesh.Pack({ c = channel, t = token })
    if type(body) ~= "string" or body == "" then return nil end
    return BUNDLE_PREFIX .. body
end

-- Reverse of EncodeBundle. Trims only surrounding whitespace (the encoded body
-- has none internally). Returns channel, token on success; nil on any malformed
-- input (missing/wrong prefix, undecodable body, or credentials that fail
-- validation) so callers can print one clean error.
function Options.DecodeBundle(str)
    if type(str) ~= "string" then return nil end
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    if str:sub(1, #BUNDLE_PREFIX) ~= BUNDLE_PREFIX then return nil end
    local body = str:sub(#BUNDLE_PREFIX + 1)
    if body == "" or not (ns.Mesh and ns.Mesh.Unpack) then return nil end
    local tbl = ns.Mesh.Unpack(body)
    if type(tbl) ~= "table" then return nil end
    if not (validChannel(tbl.c) and validToken(tbl.t)) then return nil end
    return tbl.c, tbl.t
end

-- Merged pin-size write-through (IA cleanup: five Felwood sliders → two). One
-- control writes the legacy base key AND both split keys additively, so every
-- historical reader (worldPinSize fallback, worldFlowerSize/worldTuberSize splits)
-- keeps working. No store key is ever removed — only the redundant CONTROLS are.
local function writeWorldPinSize(fw, v)
    if type(fw) ~= "table" then return end
    fw.worldPinSize   = v   -- legacy base key (fallback source for old readers)
    fw.worldFlowerSize = v  -- split key
    fw.worldTuberSize  = v  -- split key
end
local function writeMinimapPinSize(fw, v)
    if type(fw) ~= "table" then return end
    fw.minimapPinSize   = v
    fw.minimapFlowerSize = v
    fw.minimapTuberSize  = v
end
Options._writeWorldPinSize   = writeWorldPinSize
Options._writeMinimapPinSize = writeMinimapPinSize

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function DB()  return ns.Store and ns.Store.GetSettings and ns.Store.GetSettings() or nil end
local function TS()  local db = DB(); return db and db.timerSettings or nil end

-- Faction scope shared across the Auras + Automation pages. Only one of those
-- pages is visible at a time; each rebuilds from this on show.
--
-- THE TRAP THIS KILLS (owner bug, Slip'kik's Savvy): this used to be a hardcoded
-- `{ faction = "Alliance" }`. The scope is module-local and NOT persisted, so it
-- reset to Alliance on every reload — and the class-rule grids on the Auras page
-- write straight into GetFactionSettings(scope.faction).auraOpts. A Horde-only
-- owner opening Auras and ticking "Shaman = required" for Slip'kik therefore
-- wrote SHAMAN into factionSettings.ALLIANCE.auraOpts.dmtSP.required, while
-- every Horde card kept reading the untouched Horde map and rendered the buff
-- amber/optional. The page silently answered a question he never asked ("what
-- about your Alliance characters?"). Nothing in the UI said which faction table
-- the click was landing in, and the one faction he does not play was the default.
--
-- The scope now OPENS ON THE PLAYER'S OWN FACTION. That kills the whole class of
-- bug, not just the Slip'kik instance: every per-faction control on both pages
-- (thresholds, class rules, autoGossip, autoSummon triggers) inherits it.
--
-- Deliberately still not persisted across reloads: with the default correct,
-- persistence only buys "remember that I was inspecting my off-faction alts",
-- which is worth less than a new SavedVariables key and its migration.
local scope = { faction = nil }

-- The faction the scoped pages should open on. Resolved LAZILY, not at file
-- load: options.lua is parsed during ADDON_LOADED, and UnitFactionGroup is not
-- reliably answerable that early. The answer is cached only once it is a real
-- faction, so a transient nil (pre-login, or a neutral-start Pandaren-style
-- edge case that Classic does not have but costs nothing to survive) falls back
-- WITHOUT sticking — the next call retries and self-heals.
local function ScopeFaction()
    if scope.faction == "Horde" or scope.faction == "Alliance" then return scope.faction end
    local f = UnitFactionGroup and UnitFactionGroup("player")
    if f == "Horde" or f == "Alliance" then scope.faction = f; return f end
    return "Alliance"   -- transient fallback; NOT cached, so it is retried
end

-- Sole writer for the scope. `nil` (or anything not a real faction) clears the
-- cache, so the next read re-resolves from UnitFactionGroup.
local function SetScopeFaction(v)
    scope.faction = (v == "Horde" or v == "Alliance") and v or nil
end

-- Self-test / diagnostic hooks (see the "options" suite at the foot of this file).
Options.ScopeFaction    = ScopeFaction
Options.SetScopeFaction = SetScopeFaction

local function FS() return ns.Store and ns.Store.GetFactionSettings and ns.Store.GetFactionSettings(ScopeFaction()) or nil end

-- Per-page refresher registries (called on faction toggle / section show).
-- `alerts` is the split-off event matrix page (was folded into `timers`); `wizard`
-- serves the first-run setup dialog's live get/set widgets.
-- `meshLive` is a SUBSET of `mesh`: only the rows that track state which changes
-- on its own (peer online/last-seen, account count, tombstone expiry). The 2s
-- live ticker repaints that subset instead of the whole Mesh page, so the
-- credential fields, checkboxes and status lines are simply never in the
-- ticker's path (cheaper, and one less way to stomp on a field being edited).
local refreshers = { auras = {}, automation = {}, mesh = {}, general = {}, timers = {},
                     alerts = {}, blacklist = {}, wizard = {}, instances = {}, help = {},
                     meshLive = {} }
local function register(page, fn) local l = refreshers[page]; l[#l + 1] = fn end
-- Register a live Mesh row on BOTH lists: the ticker refreshes it every 2s, and a
-- normal refreshPage("mesh") still covers it like any other row.
local function registerLive(fn) register("mesh", fn); register("meshLive", fn) end
local function refreshPage(page)
    local l = refreshers[page]
    for i = 1, #l do
        local ok, err = pcall(l[i])
        if not ok then geterrorhandler()(err) end
    end
end

----------------------------------------------------------------------
-- Edit-focus guard (live-refresh clobber fix)
--
-- Every page refresher repaints its widgets from the store, and the Mesh page
-- runs a 2s live ticker on top of that. A repaint that SetText()s an editbox the
-- user is CURRENTLY typing in wipes the in-progress input. On the masked
-- Channel/Token fields it read as the field "nulling out" mid-word, because the
-- mask of a still-empty stored value is the empty string.
--
-- Rule: never SetText an editbox that owns keyboard focus. The test is made per
-- call against HasFocus() and NOTHING is remembered between calls -- so the
-- instant focus goes away (Enter commits, Escape reverts, clicking away
-- abandons) the very next refresh paints the stored value again, exactly as
-- before this fix.
----------------------------------------------------------------------

-- Resolve a widget to its EditBox: accepts a raw EditBox or a DaseekiUI editbox
-- host frame (which carries the real box on .editBox). Returns nil for anything
-- that is not an editbox (labels, checkboxes, tables) so callers stay honest.
local function editBoxOf(w)
    if type(w) ~= "table" then return nil end
    local eb = w.editBox or w
    if type(eb) ~= "table" or type(eb.HasFocus) ~= "function" then return nil end
    return eb
end

-- True only while the user is actually typing in this widget.
local function isEditing(w)
    local eb = editBoxOf(w)
    return (eb and eb:HasFocus()) and true or false
end

-- Make a widget's own .Refresh focus-safe wherever it is called from: page
-- refreshers, the live ticker, and the DaseekiUI builder's own OnShow. Idempotent.
-- The unguarded repaint stays reachable as .RefreshForce for the few explicit
-- user actions that must repaint right now (see forceRepaint).
local function guardEdit(w)
    if type(w) ~= "table" or type(w.Refresh) ~= "function" or w._focusGuarded then return w end
    local raw = w.Refresh
    w._focusGuarded = true
    w.RefreshForce = raw
    w.Refresh = function(...)
        if isEditing(w) then return end
        return raw(...)
    end
    return w
end

-- Repaint a field NOW, on an explicit user action (reveal toggle, Reset button).
-- If the field is mid-edit, `commit ~= false` runs the box's own Enter handler
-- first so the keystrokes are SAVED rather than painted over; commit == false
-- drops them (that is what "Reset to default" means).
local function forceRepaint(w, commit)
    local eb = editBoxOf(w)
    if eb and eb:HasFocus() then
        local onEnter = (commit ~= false) and eb.GetScript and eb:GetScript("OnEnterPressed")
        if onEnter then onEnter(eb) else eb:ClearFocus() end
    end
    local fn = type(w) == "table" and (w.RefreshForce or w.Refresh)
    if fn then fn() end
end

-- Icon for an aura spell (cosmetic; guarded, question-mark fallback).
local function auraIcon(spellID)
    if spellID and GetSpellTexture then
        local tex = GetSpellTexture(spellID)
        if tex then return tex end
    end
    return QUESTION
end

-- Hex "RRGGBB" -> r,g,b in 0..1 (nil-safe). Bad input -> mid-grey.
local function hexToRGB(hex)
    if type(hex) ~= "string" or #hex < 6 then return 0.5, 0.5, 0.5 end
    local r = tonumber(hex:sub(1, 2), 16) or 128
    local g = tonumber(hex:sub(3, 4), 16) or 128
    local b = tonumber(hex:sub(5, 6), 16) or 128
    return r / 255, g / 255, b / 255
end
local function sanitizeHex(s)
    s = tostring(s or ""):gsub("[^0-9A-Fa-f]", ""):upper()
    return s:sub(1, 6)
end

-- Class color r,g,b — matches the rest of the suite (Dashboard.ClassColor): the
-- user's classColors override first, then Blizzard's RAID_CLASS_COLORS.
local function classColor(class)
    local db = DB()
    local hex = db and db.classColors and db.classColors[class]
    if type(hex) == "string" and #hex >= 6 then return hexToRGB(hex) end
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 0.8, 0.8, 0.8
end

-- Newline-joined string <-> ["Name-Realm"]=true map (multi-line list editing).
local function mapToLines(map)
    local out = {}
    for k in pairs(map or {}) do out[#out + 1] = k end
    table.sort(out)
    return table.concat(out, "\n")
end
local function linesToMap(text)
    local map = {}
    for line in tostring(text or ""):gmatch("[^\r\n]+") do
        local nr = line:gsub("^%s+", ""):gsub("%s+$", "")
        if nr ~= "" then
            -- Auto-capitalize the character part (before the realm dash).
            local name, realm = nr:match("^([^-]+)-(.+)$")
            if name then
                nr = name:sub(1, 1):upper() .. name:sub(2):lower() .. "-" .. realm
            end
            map[nr] = true
        end
    end
    return map
end
local function countMap(map)
    local n = 0
    for _ in pairs(map or {}) do n = n + 1 end
    return n
end

-- Count distinct real accounts known (non-orphan) for the mesh-capacity readout.
local function knownAccountCount()
    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    if not data or not data.accounts then return 0 end
    local n = 0
    for aid in pairs(data.accounts) do
        if aid ~= "" then n = n + 1 end
    end
    return n
end

-- "N ago" relative-time label.
local function agoLabel(epoch)
    if not epoch or epoch <= 0 then return "never" end
    local now = (ns.Store and ns.Store.Now and ns.Store.Now()) or 0
    local d = now - epoch
    if d < 0 then d = 0 end
    if d < 60 then return d .. "s ago" end
    if d < 3600 then return math.floor(d / 60) .. "m ago" end
    if d < 86400 then return math.floor(d / 3600) .. "h ago" end
    return math.floor(d / 86400) .. "d ago"
end

-- Soft guards for parallel-owned HUD surfaces (defined signature above).
local function hudShowMover()
    if ns.HUD and ns.HUD.ShowMover then ns:SafeCall(ns.HUD.ShowMover) end
end
-- Fire one preview alert through the HUD. Signature mirrors hud.lua
-- HUD.TestAlert(buffKey, eventType). Soft-guarded (HUD is a later TOC file), but
-- the "HUD pending" placeholder is gone now that the HUD ships.
local function hudTestAlert(buffKey, eventKey)
    if ns.HUD and ns.HUD.TestAlert then ns:SafeCall(ns.HUD.TestAlert, buffKey, eventKey) end
end

-- Sound catalog sourced from the HUD (authoritative runtime list); falls back
-- to the local static list if the HUD module is somehow absent.
local function soundChoices()
    local src = ns.HUD and ns.HUD.SOUNDS
    if type(src) == "table" and #src > 0 then
        local out = {}
        for _, s in ipairs(src) do out[#out + 1] = { value = s.key, text = s.label } end
        return out
    end
    return SOUND_CHOICES
end
-- Resolve a stored sound key to a SoundKit id (+ optional FrameXML member name)
-- via the HUD catalog first, then the local map.
local function soundIdForKey(key)
    local src = ns.HUD and ns.HUD.SOUNDS
    if type(src) == "table" then
        for _, s in ipairs(src) do if s.key == key then return s.id, s.member end end
    end
    return SOUNDKIT_MAP[key or ""]
end

-- Inline multi-line text editor as a flow block (round-3 items 29 / 33). A
-- token-skinned bordered viewport wrapping a multi-line EditBox; commits the whole
-- buffer on focus-lost via opts.set(text), reverts on Escape. opts:
--   { height = <px>, get = function()->string, set = function(text), register = "page" }
-- Returns the host frame (with .Refresh + .editBox).
local function buildTextArea(flow, opts)
    local UI = DaseekiUI
    local height = opts.height or 96
    local host = UI.FlatFrame(flow.pane.child, "inset", "border")
    host.uiHeight, host._fillWidth = height, true

    local scroll = CreateFrame("ScrollFrame", nil, host)
    scroll:SetPoint("TOPLEFT", host, "TOPLEFT", 5, -5)
    scroll:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -5, 5)
    scroll:SetClipsChildren(true); scroll:EnableMouseWheel(true)

    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true); box:SetAutoFocus(false); box:SetMaxLetters(0)
    box:SetFontObject(UI.fonts.body); box:SetTextInsets(2, 2, 2, 2)
    box:SetWidth(1)
    scroll:SetScrollChild(box)

    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, box:GetHeight() - self:GetHeight())
        if maxs > 0 then self:SetVerticalScroll(math.max(0, math.min(maxs, self:GetVerticalScroll() - delta * 24)))
        elseif UI.ForwardWheelToPane then UI.ForwardWheelToPane(self, delta) end
    end)
    -- Clicking anywhere in the viewport focuses the editbox.
    scroll:EnableMouse(true)
    scroll:SetScript("OnMouseDown", function() box:SetFocus() end)

    local function commit()
        if opts.set then opts.set(box:GetText() or "") end
    end
    box:SetScript("OnEditFocusLost", commit)
    box:SetScript("OnEscapePressed", function(self)
        self:SetText(opts.get and (opts.get() or "") or ""); self:ClearFocus()
    end)

    host.editBox = box
    host.Refresh = function() box:SetText(opts.get and (opts.get() or "") or "") end
    guardEdit(host)   -- never repaint the buffer out from under a typist
    host.arrange = function(width)
        host:SetWidth(width); host:SetHeight(height)
        -- Fill the viewport; the multiline editbox scrolls its own content natively
        -- when the cursor moves past the visible area (short name lists rarely overflow).
        box:SetWidth(math.max(1, width - 12))
        box:SetHeight(math.max(1, height - 10))
        return height
    end
    UI.Skin(host, function() end)
    flow.pane:AddBlock(host, host.arrange, 8, 0)
    host.Refresh()
    if opts.register then register(opts.register, host.Refresh) end
    return host
end

-- Forward declarations (kept local so nothing leaks into _G).
local buildCoordPane, buildClassColors, buildClassRuleGrid
local buildAccountsTable, buildTombstonesTable

----------------------------------------------------------------------
-- 1. GENERAL  (General + Locations + Colors)
----------------------------------------------------------------------

-- Coordinate-override list state (two-pane list+editor, style-guide rule 10).
local coord = { selected = nil }

local function coordList() local db = DB(); return db and db.coordinateOverrides or {} end

local function buildGeneral(flow)
    local UI = DaseekiUI
    local DS = _G.DaseekiSuite

    -- ── Behaviour ─────────────────────────────────────────────────────────────
    local sec = flow:AddSection("General")
    sec:Hint("Core behaviour for this account.")
    -- Parent/child: the lock toggle indents beneath its minimap-button parent
    -- (round-3 item 16).
    local r1 = sec:AddRow({ vAlign = "center" })
    register("general", r1:Checkbox({
        label = "Show minimap button",
        get = function() local db = DB(); return db and not db.minimap.hide end,
        set = function(v) local db = DB(); if db then db.minimap.hide = not v end end,
    }).Refresh)
    local rLock = sec:AddRow({ vAlign = "center" })
    rLock._indent = rLock._indent + 20
    register("general", rLock:Checkbox({
        label = "Lock button position (no dragging)",
        get = function() local db = DB(); return db and db.minimap.lock end,
        set = function(v) local db = DB(); if db then db.minimap.lock = v and true or false end end,
    }).Refresh)

    local r2 = sec:AddRow({ vAlign = "center" })
    register("general", r2:Checkbox({
        label = "Auto-convert party to raid",
        get = function() local db = DB(); return db and db.autoConvertToRaid end,
        set = function(v) local db = DB(); if db then db.autoConvertToRaid = v and true or false end end,
    }).Refresh)
    register("general", r2:Checkbox({
        label = "Auto-promote assistant",
        get = function() local db = DB(); return db and db.autoAssistAll end,
        set = function(v) local db = DB(); if db then db.autoAssistAll = v and true or false end end,
    }).Refresh)

    -- Location-data status line (round-3 item 16): green when every own
    -- active-faction level-60 has a usable location, amber when some are missing.
    local locStatus = sec:AddRow():Label("")
    local function locationDataStatus()
        local bucket = ns.Store and ns.Store.GetSelfAccount and ns.Store.GetSelfAccount(false)
        if not bucket then return 0, 0 end
        local myFaction = UnitFactionGroup and UnitFactionGroup("player") or nil
        local total, missing = 0, 0
        for _, rec in pairs(bucket.characters or {}) do
            if (not myFaction) or rec.faction == myFaction or rec.faction == nil then
                if (rec.level or 0) >= 60 then
                    total = total + 1
                    local loc = rec.location
                    local manual = ns.Store.GetManualLocation and ns.Store.GetManualLocation(rec.nameRealm)
                    if (not loc or loc == "") and (not manual or manual == "") then missing = missing + 1 end
                end
            end
        end
        return total, missing
    end
    register("general", function()
        local total, missing = locationDataStatus()
        if total == 0 then
            locStatus._label:SetText("|cff888888No tracked level-60 characters yet.|r")
        elseif missing == 0 then
            locStatus._label:SetText("|cff66dd66All own active-faction characters have usable location data.|r")
        else
            locStatus._label:SetText("|cffddaa44" .. missing .. " own character(s) are missing location data.|r")
        end
    end)

    -- ── Data management ───────────────────────────────────────────────────────
    local dm = flow:AddSection("Data Management")
    dm:Hint("Local operation — excludes aura thresholds, Paladins/Shamans, and the Auto-Invite Whitelist.")
    local dmRow = dm:AddRow()
    dmRow:Button({ text = "Export Settings", width = 140, onClick = function()
        local db = DB(); if not db then return end
        local blob = { classColors = db.classColors, coordinateOverrides = db.coordinateOverrides,
                       factionSettings = db.factionSettings, timerSettings = db.timerSettings }
        local str
        if ns.Mesh and ns.Mesh.Pack then str = ns.Mesh.Pack(blob) end
        DS.ShowTextDialog("Export Settings", str or "(serialization unavailable)", true)
    end })
    dmRow:Button({ text = "Import Settings", width = 140, onClick = function()
        DS.ShowTextDialog("Import Settings (paste string)", "", false, function(txt)
            local db = DB(); if not db then return end
            local blob = ns.Mesh and ns.Mesh.Unpack and ns.Mesh.Unpack(txt)
            if not blob then ns:Print("import failed: unreadable string."); return end
            UI.Confirm({
                title = "Import Settings",
                text = "Overwrite class colors, coordinate overrides, faction settings and timer settings with the imported values?",
                acceptText = "Import", danger = true,
                onAccept = function()
                    if blob.classColors then db.classColors = blob.classColors end
                    if blob.coordinateOverrides then db.coordinateOverrides = blob.coordinateOverrides end
                    if blob.factionSettings then db.factionSettings = blob.factionSettings end
                    if blob.timerSettings then db.timerSettings = blob.timerSettings end
                    ns:Print("settings imported.")
                    refreshPage("general")
                end,
            })
        end)
    end })

    local cf = dm:AddRow()
    cf:Button({ text = "Copy Alliance → Horde", width = 180, onClick = function()
        Options.CopyFaction("Alliance", "Horde")
    end })
    cf:Button({ text = "Copy Horde → Alliance", width = 180, onClick = function()
        Options.CopyFaction("Horde", "Alliance")
    end })
    dm:Hint("Cross-faction copy excludes aura thresholds, Paladin/Shaman rows and the invite whitelist.")

    -- Mesh status line above the Sync button (round-3 item 16).
    local meshStatus = dm:AddRow():Label("")
    register("general", function()
        local aid = ns:GetAccountID()
        local online = 0
        for _, p in pairs((ns.Mesh and ns.Mesh.peers) or {}) do
            if p.online then online = online + 1 end
        end
        meshStatus._label:SetText("Mesh: AID " .. (aid ~= "" and aid or "(unset)") ..
            " |cff888888|||r Online: " .. online .. " peer(s)")
    end)
    dm:AddRow():Button({ text = "Sync Settings to Mesh", width = 200, onClick = function()
        if not (ns.Mesh and ns.Mesh.IsEnabled and ns.Mesh.IsEnabled()) then
            ns:Print("mesh is not enabled — nothing to sync to."); return
        end
        local names = {}
        for _, p in pairs(ns.Mesh.peers or {}) do
            if p.online and p.name then names[#names + 1] = (p.aid or "?") end
        end
        UI.Confirm({
            title = "Sync Settings to Mesh",
            text = "Push these settings to online accounts: " ..
                   (#names > 0 and table.concat(names, ", ") or "(none online)") .. "?",
            acceptText = "Sync",
            onAccept = function()
                local id = ns.Mesh.SyncSettings()
                ns:Print(id and "settings sync sent." or "sync could not start.")
            end,
        })
    end })

    -- ── Locations (numbered coordinate-override table) ───────────────────────
    local loc = flow:AddSection("Locations")
    buildCoordPane(loc)

    -- ── Class colors ──────────────────────────────────────────────────────────
    local col = flow:AddSection("Colors")
    col:Hint("Customize class colors used for character names across every Nexus roster and list.")
    buildClassColors(col)
end

-- Copy one faction's automation block to the other, excluding the spec's
-- non-copyable fields (aura thresholds, Paladin/Shaman gossip rows, whitelist).
function Options.CopyFaction(from, to)
    local db = DB(); if not db then return end
    local src, dst = db.factionSettings[from], db.factionSettings[to]
    if not src or not dst then return end
    DaseekiUI.Confirm({
        title = "Copy " .. from .. " → " .. to,
        text = "Overwrite " .. to .. " automation settings from " .. from ..
               "? (Aura thresholds, Paladin/Shaman gossip rows and the invite whitelist are preserved.)",
        acceptText = "Copy", danger = true,
        onAccept = function()
            -- Deep-ish copy of the copyable sub-blocks.
            local function clone(t)
                if type(t) ~= "table" then return t end
                local o = {}; for k, v in pairs(t) do o[k] = clone(v) end; return o
            end
            -- autoGroup: everything except the whitelist.
            local keepWL = dst.autoGroup.whitelist
            dst.autoGroup = clone(src.autoGroup)
            dst.autoGroup.whitelist = keepWL
            dst.autoSummon = clone(src.autoSummon)
            -- autoGossip: copy but keep Paladin/Shaman buffType rows on the target.
            local keepPal = dst.autoGossip.dmf.buffType.PALADIN
            local keepSha = dst.autoGossip.dmf.buffType.SHAMAN
            dst.autoGossip = clone(src.autoGossip)
            dst.autoGossip.dmf.buffType.PALADIN = keepPal
            dst.autoGossip.dmf.buffType.SHAMAN = keepSha
            dst.autoQuest = clone(src.autoQuest)
            -- auraOpts.thresholds preserved; Rend/BS rules copy (they are class rules,
            -- not thresholds).
            dst.auraOpts.rend = clone(src.auraOpts.rend)
            dst.auraOpts.battleShout = clone(src.auraOpts.battleShout)
            dst.auraOpts.dmtSP = clone(src.auraOpts.dmtSP)
            ns:Print(from .. " → " .. to .. " copied.")
            refreshPage("general")
        end,
    })
end

-- Numbered coordinate-override table (round-3 item 15): header row
-- (# · Name · X · Y · Tolerance) over up to 15 rows, each with a per-row "Here",
-- plus Reset to Defaults. The store keeps box-bounds (minX/maxX/minY/maxY); the UI
-- presents centre X/Y + a symmetric Tolerance and converts to bounds on save.
local COORD_CAP = 15
-- Column x-offsets (shared by header + rows; measured from the block's left edge).
local CC = { num = 4, name = 28, x = 188, y = 262, tol = 336, here = 410, del = 462 }
local CW = { name = 152, x = 66, y = 66, tol = 66, here = 46, del = 58 }

function buildCoordPane(flow)
    local UI = DaseekiUI

    -- Hint with the reference's colored tolerance callouts (round-3 item 15).
    flow:Hint("Relabels a character's location when they stand near a point. Coordinates accurate to 6 decimals. " ..
        "Default tolerance |cff69ccf00.02|r (custom) / |cffffd100.08|r (normal).")

    local function fmt(v) return string.format("%.6f", v or 0) end
    local function cx(r)  return ((r.minX or 0) + (r.maxX or 0)) / 2 end
    local function cy(r)  return ((r.minY or 0) + (r.maxY or 0)) / 2 end
    local function tolOf(r) return math.abs((r.maxX or 0) - (r.minX or 0)) / 2 end
    local function setCX(r, n)  local t = tolOf(r); r.minX = n - t; r.maxX = n + t end
    local function setCY(r, n)  local t = tolOf(r); r.minY = n - t; r.maxY = n + t end
    local function setTolR(r, t) local X, Y = cx(r), cy(r); r.minX = X - t; r.maxX = X + t; r.minY = Y - t; r.maxY = Y + t end

    local host = CreateFrame("Frame", nil, flow.pane.child)
    host._rows = {}
    local ROW_H, HDR_H = 28, 22

    -- Header fontstrings (aligned to the same column offsets as data rows).
    local function mkHdr(text, x, w)
        local fs = host:CreateFontString(nil, "OVERLAY"); fs:SetFontObject(UI.fonts.small)
        fs:SetPoint("TOPLEFT", host, "TOPLEFT", x, -3); if w then fs:SetWidth(w) end
        fs:SetText(text); return fs
    end
    local h1 = mkHdr("#", CC.num, 20)
    local h2 = mkHdr("Name", CC.name, CW.name)
    local h3 = mkHdr("X", CC.x, CW.x)
    local h4 = mkHdr("Y", CC.y, CW.y)
    local h5 = mkHdr("Tolerance", CC.tol, CW.tol)
    UI.Skin(host, function()
        for _, fs in ipairs({ h1, h2, h3, h4, h5 }) do fs:SetTextColor(UI.Color("muted")) end
    end)

    local rebuild   -- forward
    -- Focus-guarded cell paint: a rebuild fires whenever ANY cell commits (and on
    -- Here / Del / Add), which would otherwise rewrite the sibling cell the user
    -- has just clicked into and is typing in.
    local function paintCell(cell, text)
        if not isEditing(cell) then cell:SetText(text) end
    end
    local function makeCell(row, x, w)
        local box = CreateFrame("EditBox", nil, row, "BackdropTemplate")
        box:SetSize(w, 22); box:SetPoint("LEFT", row, "LEFT", x, 0)
        box:SetAutoFocus(false); box:SetFontObject(UI.fonts.body); box:SetTextInsets(6, 6, 0, 0)
        UI.Skin(box, function(self)
            self:SetBackdrop(UI.FLAT_BACKDROP)
            self:SetBackdropColor(UI.Color("inset")); self:SetBackdropBorderColor(UI.Color("controlBorder"))
        end)
        return box
    end

    rebuild = function()
        local rules = coordList()
        for _, r in ipairs(host._rows) do r:Hide() end
        for i = 1, #rules do
            local row = host._rows[i]
            if not row then
                row = CreateFrame("Frame", nil, host); row:SetHeight(ROW_H)
                row.num = row:CreateFontString(nil, "OVERLAY"); row.num:SetFontObject(UI.fonts.body)
                row.num:SetPoint("LEFT", row, "LEFT", CC.num, 0); row.num:SetWidth(20)
                row.name = makeCell(row, CC.name, CW.name)
                row.x    = makeCell(row, CC.x,   CW.x)
                row.y    = makeCell(row, CC.y,   CW.y)
                row.tol  = makeCell(row, CC.tol, CW.tol)
                row.here = UI.MakeButton(row, { text = "Here", width = CW.here, height = 22, variant = "quiet" })
                row.here:ClearAllPoints(); row.here:SetPoint("LEFT", row, "LEFT", CC.here, 0)
                row.del  = UI.MakeButton(row, { text = "Del", width = CW.del, height = 22, variant = "danger" })
                row.del:ClearAllPoints(); row.del:SetPoint("LEFT", row, "LEFT", CC.del, 0)
                UI.Skin(row, function() row.num:SetTextColor(UI.Color("muted")) end)
                host._rows[i] = row
            end
            local idx = i
            row.num:SetText(tostring(idx))
            paintCell(row.name, rules[idx].label or "")
            paintCell(row.x,   fmt(cx(rules[idx])))
            paintCell(row.y,   fmt(cy(rules[idx])))
            paintCell(row.tol, fmt(tolOf(rules[idx])))
            local function bindText(box, apply)
                box:SetScript("OnEnterPressed", function(self) apply(self:GetText()); self:ClearFocus(); rebuild() end)
                box:SetScript("OnEditFocusLost", function(self) apply(self:GetText()); rebuild() end)
                box:SetScript("OnEscapePressed", function(self) rebuild(); self:ClearFocus() end)
            end
            bindText(row.name, function(t) local r = coordList()[idx]; if r then r.label = t end end)
            bindText(row.x,   function(t) local r = coordList()[idx]; local n = tonumber(t); if r and n then setCX(r, n) end end)
            bindText(row.y,   function(t) local r = coordList()[idx]; local n = tonumber(t); if r and n then setCY(r, n) end end)
            bindText(row.tol, function(t) local r = coordList()[idx]; local n = tonumber(t); if r and n then setTolR(r, n) end end)
            row.here:SetScript("OnClick", function()
                local r = coordList()[idx]; if not r then return end
                local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
                local pos = mapID and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
                if not pos then ns:Print("could not read your position here."); return end
                local px, py = pos:GetXY()
                setCX(r, px); setCY(r, py); if tolOf(r) <= 0 then setTolR(r, 0.02) end
                local info = mapID and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
                if info and info.name then r.zone = info.name; if (r.label or "") == "" then r.label = info.name end end
                rebuild()
            end)
            row.del:SetScript("OnClick", function()
                table.remove(coordList(), idx); rebuild()
            end)
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", host, "TOPLEFT", 0, -(HDR_H + (i - 1) * ROW_H))
            row:SetPoint("TOPRIGHT", host, "TOPRIGHT", 0, -(HDR_H + (i - 1) * ROW_H))
            row:Show()
        end
        if flow.pane and flow.pane.Layout then flow.pane:Layout() end
    end

    host.arrange = function(width)
        local n = #coordList()
        local h = HDR_H + math.max(1, n) * ROW_H
        host:SetWidth(width); host:SetHeight(h)
        return h
    end
    coord._rebuild = rebuild
    register("general", rebuild)
    UI.Skin(host, function() end)
    flow.pane:AddBlock(host, host.arrange, 8, 0)
    rebuild()

    -- Add row + Reset to Defaults (round-3 item 15).
    local act = flow:AddRow()
    act:Button({ text = "Add Location", width = 130, onClick = function()
        local rules = coordList()
        if #rules >= COORD_CAP then ns:Print("location limit is " .. COORD_CAP .. "."); return end
        -- A new rule is born UNSCOPED, so `zone` is omitted (nil) rather than "".
        -- An empty string is not "no zone" to the coordinate matcher — it
        -- compares unequal to every real zone name, so a rule stored that way
        -- could never match anywhere, in any zone. The per-row "Here" button
        -- stamps a real zone when the user wants the rule scoped to one.
        rules[#rules + 1] = { name = "", label = "New Location",
                              minX = 0, maxX = 0.02, minY = 0, maxY = 0.02 }
        rebuild()
    end })
    act:Button({ text = "Reset to Defaults", width = 160, variant = "danger", onClick = function()
        UI.Confirm({ title = "Reset Locations", danger = true,
            text = "Restore the default location rules? Your custom rules are removed.",
            acceptText = "Reset",
            onAccept = function()
                local db = DB(); if not db then return end
                -- A17.3: this button used to carry its OWN literal copy of the
                -- seeds, so it re-installed the oversized boxes the store had
                -- just been taught to shrink — "Reset to Defaults" was the one
                -- way to reintroduce the bug. Ask the store for the defaults
                -- instead; one definition, no drift. (Fallback keeps the button
                -- working if the export is ever absent.)
                if ns.Store and type(ns.Store.DefaultCoordinateOverrides) == "function" then
                    db.coordinateOverrides = ns.Store.DefaultCoordinateOverrides()
                else
                    db.coordinateOverrides = {}
                end
                rebuild()
            end })
    end })
end

-- Class-color rows: swatch + class name + hex editbox, plus Reset All.
function buildClassColors(flow)
    local UI = DaseekiUI
    local DEFAULTS = {
        WARRIOR = "C79C6E", PALADIN = "F58CBA", HUNTER = "ABD473", ROGUE = "FFF569",
        PRIEST = "FFFFFF", SHAMAN = "0070DE", MAGE = "69CCF0", WARLOCK = "9482C9", DRUID = "FF7D0A",
    }
    for _, class in ipairs(REND_CLASSES) do
        local row = flow:AddRow({ vAlign = "center" })
        -- swatch
        local sw = UI.FlatFrame(row, "panel", "border")
        sw:SetSize(18, 18); sw.uiWidth, sw.uiHeight = 18, 18
        row._items[#row._items + 1] = { w = sw }
        -- Class name rendered in its own (live) color (round-3 item 17).
        local nameLbl = row:Label(CLASS_LABEL[class] or class); nameLbl.uiWidth = 90; nameLbl._label:SetWidth(90)
        local function paint()
            local db = DB(); local hex = db and db.classColors[class] or DEFAULTS[class]
            sw:SetBackdropColor(hexToRGB(hex))
            nameLbl._label:SetTextColor(hexToRGB(hex))
        end
        local box = row:EditBox({
            width = 90,
            get = function() local db = DB(); return db and (db.classColors[class] or DEFAULTS[class]) or "" end,
            set = function(v)
                local db = DB(); if not db then return end
                db.classColors[class] = sanitizeHex(v)
                paint()
            end,
        })
        box._fillWidth = false
        box.editBox:SetMaxLetters(6)
        guardEdit(box)
        row:Button({ text = "Reset", width = 66, variant = "quiet", pin = "right", onClick = function()
            local db = DB(); if not db then return end
            db.classColors[class] = DEFAULTS[class]
            -- Explicit reset: discard any half-typed hex, then repaint the default.
            forceRepaint(box, false)
            paint()
        end })
        register("general", function() if box.Refresh then box.Refresh() end; paint() end)
        UI.Skin(sw, paint)
    end
    flow:AddRow():Button({ text = "Reset All Colors", width = 160, variant = "danger", onClick = function()
        UI.Confirm({ title = "Reset Class Colors", danger = true,
            text = "Restore all class colors to the Blizzard palette?", acceptText = "Reset",
            onAccept = function()
                local db = DB(); if not db then return end
                for k, v in pairs(DEFAULTS) do db.classColors[k] = v end
                refreshPage("general")
            end })
    end })
end

----------------------------------------------------------------------
-- 2. MESH & ACCOUNTS
----------------------------------------------------------------------

local function buildMesh(flow)
    local UI = DaseekiUI
    local DS = _G.DaseekiSuite

    flow:AddSection("Mesh")
    flow:Hint("Your accounts meet on a private hidden channel. Set the same channel and token on every account, then enable.")

    -- Read helpers for the two credential fields. ENGINE DEPENDENCY (round-3 item
    -- 38): mesh.channel is added by the engine agent; defensive `or ""` fallback
    -- keeps this field harmless until that key lands.
    local function chanRaw() local db = DB(); return (db and db.mesh.channel) or "" end
    local function tokRaw()  local db = DB(); return (db and db.mesh.token) or "" end

    -- Configured = both credentials present and well-formed. Declared up here because
    -- the Enable toggle (which now leads the section) and the configured-status line
    -- both close over it (round-3 item 38).
    local function isConfigured()
        local c, t = chanRaw(), tokRaw()
        return #c >= 16 and c:match("^%w+$") and #t == 6 and t:match("^%w+$") and true or false
    end

    -- Reusable masked credential field (label + masked editbox + Show/Hide + status).
    local function maskedField(labelText, width, getRaw, setRaw, validate)
        local row = flow:AddRow({ vAlign = "center" })
        local lbl = row:Label(labelText); lbl.uiWidth = 64; lbl._label:SetWidth(64)
        local revealed = { on = false }
        local status
        local box
        box = row:EditBox({
            width = width,
            get = function()
                local t = getRaw()
                if revealed.on then return t end
                return (t ~= "" and string.rep("*", #t)) or ""
            end,
            set = function(v)
                v = tostring(v or ""):gsub("%s", "")
                if v:match("^%*+$") then return end   -- ignore edits to the mask
                setRaw(v)
                if status then status._label:SetText(validate(v)) end
            end,
        })
        box._fillWidth = false
        -- THE reported bug: this field is masked, so a live-ticker repaint mid-typing
        -- painted the mask of the still-unsaved value ("" -> the field emptied itself
        -- as you typed). Guarded, the box is left alone until focus leaves it.
        guardEdit(box)
        local eyeBtn
        eyeBtn = row:Button({ text = "Show", width = 48, variant = "quiet", onClick = function()
            revealed.on = not revealed.on
            eyeBtn._label:SetText(revealed.on and "Hide" or "Show")
            -- Reveal/hide must repaint even while focused; commit first so toggling
            -- mid-edit saves what you typed instead of discarding it.
            forceRepaint(box)
        end })
        status = row:Label("")
        register("mesh", function()
            if box.Refresh then box.Refresh() end
            status._label:SetText(validate(getRaw()))
        end)
        return box
    end

    -- Enable toggle leads the section — it is the master switch (owner task 2a).
    -- WIRED to StartJoinSequence / OnDisable.
    local enRow = flow:AddRow({ vAlign = "center" })
    register("mesh", enRow:Checkbox({
        label = "Enable mesh",
        get = function() local db = DB(); return db and db.mesh.enabled end,
        set = function(v)
            local db = DB(); if not db then return end
            if v and not isConfigured() then
                ns:Print("set a channel and token first.")
                if db.mesh then db.mesh.enabled = false end
                refreshPage("mesh")
                return
            end
            db.mesh.enabled = v and true or false
            if not ns.Mesh then return end
            if v then
                if ns.Mesh.StartJoinSequence then ns:SafeCall(ns.Mesh.StartJoinSequence) end
                ns:Print("mesh enabled — joining channel.")
            else
                if ns.Mesh.OnDisable then ns:SafeCall(ns.Mesh.OnDisable) end
                ns:Print("mesh disabled — left channel.")
            end
            refreshPage("mesh")
        end,
    }).Refresh)

    -- Account ID leads the credential group — the mesh keys off this identity, so it
    -- sits directly above the channel/token (relocated here from General per owner).
    local acctRow = flow:AddRow({ vAlign = "center" })
    -- Inline-left "Account ID" label on the same 64px column as the Channel/Token
    -- fields below (style law: no naked inputs). Owner round-1 density note.
    local acctLbl = acctRow:Label("Account ID"); acctLbl.uiWidth = 64; acctLbl._label:SetWidth(64)
    local acctStatus
    local acctBox = acctRow:EditBox({
        width = 70,
        get = function() return ns:GetAccountID() end,
        set = function(v)
            v = tostring(v or ""):gsub("%s", "")
            local ok, err = ns:SetAccountID(v)
            if acctStatus then
                if ok then acctStatus._label:SetText("|cff66dd66saved|r")
                else acctStatus._label:SetText("|cffdd6666" .. (err or "invalid") .. "|r") end
            end
        end,
    })
    acctBox._fillWidth = false
    guardEdit(acctBox)   -- same page, same 2s ticker: same guard
    acctStatus = acctRow:Label("")
    flow:Hint("1-2 digits (e.g., 1, 02). Must be different on each account.")

    maskedField("Channel", 200, chanRaw,
        function(v) local db = DB(); if db then db.mesh.channel = v end end,
        function(v)
            if v == "" then return "" end
            if #v >= 16 and v:match("^%w+$") then return "|cff66dd66valid|r" end
            return "|cffddaa44needs 16+ alphanumerics|r"
        end)
    flow:Hint("16+ alphanumeric, case sensitive, same on all accounts.")

    maskedField("Token", 160, tokRaw,
        function(v) local db = DB(); if db then db.mesh.token = v end end,
        function(v)
            if v == "" then return "" end
            if #v == 6 and v:match("^%w+$") then return "|cff66dd66valid|r" end
            return "|cffddaa44needs 6 alphanumerics|r"
        end)
    flow:Hint("Exactly 6 alphanumeric, same on all accounts.")

    -- Not-configured status line beneath the credentials (round-3 item 38).
    local cfgStatus = flow:AddRow():Label("")
    register("mesh", function()
        if isConfigured() then
            cfgStatus._label:SetText("|cff66dd66Channel and token set — ready to enable.|r")
        else
            cfgStatus._label:SetText("|cffddaa44Set a channel and token first.|r")
        end
    end)

    -- ── Credential actions: ONE compact row + ONE combined hint (owner round-1
    -- density pass). Previously three stacked button groups each with its own hint.
    -- The four setup actions now sit on a single row; functional wiring (generate /
    -- bundle encode-decode / setup guide) is unchanged. Generate's success is shown
    -- by the chat notice + the "ready to enable" status line above (cfgStatus), so
    -- the old inline "Generated…" label is retired rather than duplicating it.
    local actRow  = flow:AddRow({ vAlign = "center" })
    local actLine = flow:AddRow():Label("")   -- register-owned new-here prompt (below)

    actRow:Button({ text = "Generate", width = 96, onClick = function()
        local db = DB(); if not db then return end
        local c, t = Options.GenerateChannel(), Options.GenerateToken()
        db.mesh.channel, db.mesh.token = c, t
        ns:Print("credentials generated. Copy the setup bundle to your other accounts, then enable the mesh.")
        refreshPage("mesh")
    end })

    actRow:Button({ text = "Copy bundle", width = 110, onClick = function()
        local str = Options.EncodeBundle(chanRaw(), tokRaw())
        if not str then
            ns:Print("set a valid channel and token first (Generate does this).")
            return
        end
        if DS and DS.ShowTextDialog then
            DS.ShowTextDialog("Copy setup bundle", str, true)
        else
            ns:Print("setup bundle: " .. str)
        end
    end })

    actRow:Button({ text = "Paste bundle", width = 110, variant = "quiet", onClick = function()
        if not (DS and DS.ShowTextDialog) then
            ns:Print("paste is unavailable — update Daseeki Core.")
            return
        end
        DS.ShowTextDialog("Paste setup bundle", "", false, function(txt)
            local c, t = Options.DecodeBundle(txt)
            if not c then
                ns:Print("that bundle could not be read. Copy the whole string and try again.")
                return
            end
            local db = DB(); if not db then return end
            db.mesh.channel, db.mesh.token = c, t
            local aid = ns:GetAccountID()
            if aid == "" or not ns:IsValidAccountID(aid) then
                ns:Print("Channel and token accepted. Set this account's ID, then enable the mesh.")
            else
                ns:Print("Channel and token accepted. Enable the mesh, then relog.")
            end
            refreshPage("mesh")
        end)
    end })

    actRow:Button({ text = "Setup guide", width = 104, onClick = function()
        Options.ShowSetupWizard()
    end })

    -- New-here prompt (register-owned): shown until the mesh is configured, then
    -- clears. Same trigger the old guideLine used, now on the shared action line.
    register("mesh", function()
        if isConfigured() then
            actLine._label:SetText("")
        else
            actLine._label:SetText("|cffddaa44New here? Open the Setup guide to connect this account in three steps.|r")
        end
    end)

    flow:Hint("Generate credentials on your first account, Copy the bundle, then Paste it on each other account (Setup guide walks you through it). The Account ID stays unique per account and is never shared in the bundle.")

    -- Suppress mesh-disabled alert — a notification preference. It formerly shared the
    -- Enable row; since Enable now leads the section alone, this keeps its own row
    -- rather than crowding a third checkbox onto the transport-toggle row below.
    local suppRow = flow:AddRow({ vAlign = "center" })
    register("mesh", suppRow:Checkbox({
        label = "Suppress mesh-disabled alert",
        get = function() local db = DB(); return db and db.mesh.optOut end,
        set = function(v) local db = DB(); if db then db.mesh.optOut = v and true or false end end,
    }).Refresh)

    local alRow = flow:AddRow({ vAlign = "center" })
    register("mesh", alRow:Checkbox({
        label = "Auto-leave standard chat channels",
        get = function() local db = DB(); return db and db.mesh.autoLeaveChannel end,
        set = function(v) local db = DB(); if db then db.mesh.autoLeaveChannel = v and true or false end end,
    }).Refresh)
    register("mesh", alRow:Checkbox({
        label = "Hard-throttle mesh sends",
        get = function() local db = DB(); return db and db.hardThrottle end,
        set = function(v) local db = DB(); if db then db.hardThrottle = v and true or false end end,
    }).Refresh)

    -- ── Active accounts table (round-3 item 32) ───────────────────────────────
    local acc = flow:AddSection("Accounts")
    -- (Section description intentionally omitted — owner crossed out the
    -- "Account-wide. Local management only…" line; header + table remain.)
    local capLabel = acc:AddRow():Label("Mesh capacity: 1 / " .. MESH_CAP)
    registerLive(function()
        capLabel._label:SetText("Mesh capacity: " .. math.min(MESH_CAP, math.max(1, knownAccountCount())) .. " / " .. MESH_CAP)
    end)

    -- Column header row (aligned to buildAccountsTable's column offsets: the table
    -- host insets its scroll by 4px, so header x = 4 + column offset).
    do
        local hdr = CreateFrame("Frame", nil, acc.pane.child); hdr:SetHeight(16)
        local function hl(text, x, w)
            local fs = hdr:CreateFontString(nil, "OVERLAY"); fs:SetFontObject(UI.fonts.small)
            fs:SetPoint("LEFT", hdr, "LEFT", x, 0); if w then fs:SetWidth(w) end; fs:SetText(text); return fs
        end
        local cells = { hl("AID", 12, 44), hl("Status", 60, 80), hl("Characters", 144, 70),
                        hl("Last seen", 218, 90), hl("Action", 0) }
        cells[5]:ClearAllPoints(); cells[5]:SetPoint("RIGHT", hdr, "RIGHT", -12, 0)
        UI.Skin(hdr, function() for _, c in ipairs(cells) do c:SetTextColor(UI.Color("muted")) end end)
        acc.pane:AddBlock(hdr, function(width) hdr:SetWidth(width); return 16 end, 6, acc._indent)
    end
    buildAccountsTable(acc)

    -- ── Tombstones (round-3 item 32) ──────────────────────────────────────────
    local tomb = flow:AddSection("Tombstones")
    tomb:Hint("Deleted accounts are hidden here and blocked from re-adding until the tombstone expires.")
    buildTombstonesTable(tomb)
end

----------------------------------------------------------------------
-- First-run setup wizard (movable, ESC-closable Classic dialog).
--
-- A single taller dialog with three ruled step-sections (Expert A r3 §7: not a
-- web carousel). Reuses the DaseekiUI flow widgets via UI.CreatePane, exactly as
-- the Help tab does. Each step shows a live done/needed status; the actions are
-- the same Generate / Copy-Paste bundle / Enable paths the settings page exposes.
----------------------------------------------------------------------

local function buildWizardContent(flow)
    local DS = _G.DaseekiSuite

    -- Step 1 — Account ID (unique per account).
    flow:AddSection("Step 1 — Name this account")
    flow:Hint("Give this account a unique ID: 1-2 digits, different on every account. It is how the mesh tells your accounts apart.")
    local s1 = flow:AddRow({ vAlign = "center" })
    s1:Label("Account ID")
    local s1status
    local s1box = s1:EditBox({   -- guarded below; the wizard re-refreshes on every set
        width = 70,
        get = function() return ns:GetAccountID() end,
        set = function(v)
            v = tostring(v or ""):gsub("%s", "")
            local ok, err = ns:SetAccountID(v)
            if s1status then
                s1status._label:SetText(ok and "|cff66dd66saved|r" or ("|cffdd6666" .. (err or "invalid") .. "|r"))
            end
            refreshPage("wizard")
        end,
    })
    s1box._fillWidth = false
    guardEdit(s1box)
    s1status = s1:Label("")
    register("wizard", function()
        if s1box.Refresh then s1box.Refresh() end
        local aid = ns:GetAccountID()
        if aid ~= "" and ns:IsValidAccountID(aid) then s1status._label:SetText("|cff66dd66done|r")
        else s1status._label:SetText("|cffddaa44needed|r") end
    end)

    -- Step 2 — credentials (Generate on account 1, Paste on the rest).
    flow:AddSection("Step 2 — Create or join a mesh")
    flow:Hint("On your first account, Generate credentials then Copy the setup bundle. On each other account, Paste that bundle.")
    local s2 = flow:AddRow({ vAlign = "center" })
    s2:Button({ text = "Generate credentials", width = 180, onClick = function()
        local db = DB(); if not db then return end
        db.mesh.channel = Options.GenerateChannel()
        db.mesh.token   = Options.GenerateToken()
        ns:Print("credentials generated. Copy the setup bundle to your other accounts.")
        refreshPage("wizard"); refreshPage("mesh")
    end })
    local s2b = flow:AddRow({ vAlign = "center" })
    s2b:Button({ text = "Copy setup bundle", width = 160, onClick = function()
        local db = DB(); if not db then return end
        local str = Options.EncodeBundle(db.mesh.channel or "", db.mesh.token or "")
        if not str then ns:Print("generate or paste credentials first."); return end
        if DS and DS.ShowTextDialog then DS.ShowTextDialog("Copy setup bundle", str, true)
        else ns:Print("setup bundle: " .. str) end
    end })
    s2b:Button({ text = "Paste setup bundle", width = 160, variant = "quiet", onClick = function()
        if not (DS and DS.ShowTextDialog) then ns:Print("paste is unavailable — update Daseeki Core."); return end
        DS.ShowTextDialog("Paste setup bundle", "", false, function(txt)
            local c, t = Options.DecodeBundle(txt)
            if not c then ns:Print("that bundle could not be read. Copy the whole string and try again."); return end
            local db = DB(); if not db then return end
            db.mesh.channel, db.mesh.token = c, t
            ns:Print("Channel and token accepted. Set this account's ID, then enable the mesh.")
            refreshPage("wizard"); refreshPage("mesh")
        end)
    end })
    local s2status = flow:AddRow():Label("")
    register("wizard", function()
        local db = DB()
        local c = (db and db.mesh and db.mesh.channel) or ""
        local t = (db and db.mesh and db.mesh.token) or ""
        if validChannel(c) and validToken(t) then
            s2status._label:SetText("|cff66dd66Channel and token set.|r")
        else
            s2status._label:SetText("|cffddaa44No channel or token yet — Generate or Paste.|r")
        end
    end)

    -- Step 3 — enable + relog.
    flow:AddSection("Step 3 — Enable the mesh")
    flow:Hint("Turn the mesh on, then log out and back in once on this account. Characters appear across your accounts within seconds.")
    local s3 = flow:AddRow({ vAlign = "center" })
    register("wizard", s3:Checkbox({
        label = "Enable mesh",
        get = function() local db = DB(); return db and db.mesh.enabled end,
        set = function(v)
            local db = DB(); if not db then return end
            local c, t = db.mesh.channel or "", db.mesh.token or ""
            if v and not (validChannel(c) and validToken(t)) then
                ns:Print("set a channel and token first.")
                db.mesh.enabled = false
                refreshPage("wizard"); return
            end
            db.mesh.enabled = v and true or false
            if ns.Mesh then
                if v and ns.Mesh.StartJoinSequence then ns:SafeCall(ns.Mesh.StartJoinSequence)
                elseif (not v) and ns.Mesh.OnDisable then ns:SafeCall(ns.Mesh.OnDisable) end
            end
            ns:Print(v and "mesh enabled — joining channel. Relog to connect." or "mesh disabled.")
            refreshPage("wizard"); refreshPage("mesh")
        end,
    }).Refresh)
    flow:Hint("Coming from ShadowNetwork? /nexus import copies everything — channel, token, characters and settings.")
end

-- Build (once) and show the movable ESC-closable wizard frame.
function Options.ShowSetupWizard()
    local UI = DaseekiUI
    if not (UI and UI.CreatePane and UI.FlatFrame and UI.MakeButton) then
        ns:Print("the setup guide needs Daseeki Core — please update.")
        return
    end
    local f = Options._wizardFrame
    if not f then
        f = CreateFrame("Frame", "DaseekiNexusSetupWizard", UIParent)
        f:SetSize(460, 480)
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        f:SetFrameStrata("DIALOG")
        f:SetMovable(true); f:EnableMouse(true); f:RegisterForDrag("LeftButton")
        f:SetScript("OnDragStart", f.StartMoving)
        f:SetScript("OnDragStop", f.StopMovingOrSizing)
        f:SetClampedToScreen(true)
        if type(UISpecialFrames) == "table" then
            table.insert(UISpecialFrames, "DaseekiNexusSetupWizard")   -- ESC closes
        end

        local bg = UI.FlatFrame(f, "panel", "accent"); bg:SetAllPoints(f)

        local title = f:CreateFontString(nil, "OVERLAY")
        title:SetFontObject(UI.fonts.accent)
        title:SetPoint("TOP", f, "TOP", 0, -10)
        title:SetText("Mesh Setup Guide")

        local close = UI.MakeButton(f, { text = "\195\151", variant = "quiet", width = 24, height = 20,
            onClick = function() f:Hide() end })
        close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

        local host = CreateFrame("Frame", nil, f)
        host:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -38)
        host:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 12)

        local pane = UI.CreatePane(host)
        f._pane = pane
        ns:SafeCall(function() buildWizardContent(pane.flow) end)
        Options._wizardFrame = f
    end
    refreshPage("wizard")
    if f._pane and f._pane.Layout then f._pane:Layout() end
    f:Show()
end

-- A simple token-skinned data table with a fixed column layout + live rebuild.
local function makeTable(parent, columns, rowH, viewH)
    local UI = DaseekiUI
    local host = UI.FlatFrame(parent, "inset", "border")
    host.uiHeight, host._fillWidth = viewH, true
    local scroll = CreateFrame("ScrollFrame", nil, host)
    scroll:SetPoint("TOPLEFT", host, "TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -4, 4)
    scroll:SetClipsChildren(true); scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll); child:SetSize(1, 1)
    scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, child:GetHeight() - self:GetHeight())
        if maxs > 0 then self:SetVerticalScroll(math.max(0, math.min(maxs, self:GetVerticalScroll() - delta * 24)))
        elseif UI.ForwardWheelToPane then UI.ForwardWheelToPane(self, delta) end
    end)
    host._scroll, host._child, host._rows = scroll, child, {}
    host.arrange = function(width) host:SetWidth(width); host:SetHeight(viewH); child:SetWidth(math.max(1, width - 8)); return viewH end
    return host
end

function buildAccountsTable(flow)
    local UI = DaseekiUI
    local ROW_H, VIEW_H = 30, 168
    local host = makeTable(flow.pane.child, nil, ROW_H, VIEW_H)

    local function rebuild()
        local child = host._child
        for _, r in ipairs(host._rows) do r:Hide() end
        local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
        local accounts = (data and data.accounts) or {}
        local selfID = ns:GetAccountID()
        local list = {}
        for aid, bucket in pairs(accounts) do
            if aid ~= "" then list[#list + 1] = { aid = aid, bucket = bucket } end
        end
        table.sort(list, function(a, b) return (tonumber(a.aid) or 0) < (tonumber(b.aid) or 0) end)
        local i = 0
        for _, entry in ipairs(list) do
            i = i + 1
            local row = host._rows[i]
            if not row then
                row = CreateFrame("Frame", nil, child); row:SetHeight(ROW_H)
                row.bg = row:CreateTexture(nil, "BACKGROUND"); row.bg:SetAllPoints()
                row.aid = row:CreateFontString(nil, "OVERLAY"); row.aid:SetFontObject(UI.fonts.body)
                row.aid:SetPoint("LEFT", row, "LEFT", 8, 0); row.aid:SetWidth(44)
                row.status = row:CreateFontString(nil, "OVERLAY"); row.status:SetFontObject(UI.fonts.small)
                row.status:SetPoint("LEFT", row, "LEFT", 56, 0); row.status:SetWidth(80)
                row.chars = row:CreateFontString(nil, "OVERLAY"); row.chars:SetFontObject(UI.fonts.small)
                row.chars:SetPoint("LEFT", row, "LEFT", 140, 0); row.chars:SetWidth(70)
                row.seen = row:CreateFontString(nil, "OVERLAY"); row.seen:SetFontObject(UI.fonts.small)
                row.seen:SetPoint("LEFT", row, "LEFT", 214, 0); row.seen:SetWidth(90)
                row.del = UI.MakeButton(row, { text = "Delete", width = 66, height = 20, variant = "danger" })
                row.del:ClearAllPoints(); row.del:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                UI.Skin(row, function() row.bg:SetColorTexture(UI.Color(i % 2 == 0 and "raised" or "panel", 0.6))
                    row.status:SetTextColor(UI.Color("muted")); row.chars:SetTextColor(UI.Color("muted"))
                    row.seen:SetTextColor(UI.Color("muted")); row.aid:SetTextColor(UI.Color("text")) end)
                host._rows[i] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(i - 1) * ROW_H)
            row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -(i - 1) * ROW_H)
            local isSelf = (entry.aid == selfID) or (entry.bucket.isSelf == true)
            local peer = ns.Mesh and ns.Mesh.peers and ns.Mesh.peers[entry.aid]
            local nChars = 0; for _ in pairs(entry.bucket.characters or {}) do nChars = nChars + 1 end
            row.aid:SetText("#" .. entry.aid)
            -- Status glyphs (round-3 item 32): ● green You / ● green Online / ○ grey Offline.
            if isSelf then row.status:SetText("|cff66dd66\226\151\143 You|r")
            elseif peer and peer.online then row.status:SetText("|cff66dd66\226\151\143 Online|r")
            else row.status:SetText("|cff888888\226\151\139 Offline|r") end
            row.chars:SetText(nChars .. " char" .. (nChars == 1 and "" or "s"))
            row.seen:SetText(agoLabel(peer and peer.lastSeen))
            local aid = entry.aid
            row.del:SetEnabled(not isSelf)
            row.del:SetScript("OnClick", function()
                if isSelf then return end
                UI.Confirm({ title = "Remove Account #" .. aid, danger = true,
                    text = "Remove account #" .. aid .. " and its characters? It is blocked from re-adding for 14 days.",
                    acceptText = "Remove",
                    onAccept = function()
                        if ns.Store and ns.Store.TombstoneAccount then ns.Store.TombstoneAccount(aid) end
                        if ns.Mesh and ns.Mesh.peers then ns.Mesh.peers[aid] = nil end
                        rebuild()
                    end })
            end)
            row:Show()
        end
        child:SetHeight(math.max(1, i * ROW_H))
        if i == 0 then child:SetHeight(1) end
    end
    host._rebuild = rebuild
    registerLive(rebuild)   -- peer online / last-seen move on their own: ticker row
    UI.Skin(host, rebuild)
    flow.pane:AddBlock(host, host.arrange, 10, 0)
end

function buildTombstonesTable(flow)
    local UI = DaseekiUI
    local ROW_H, VIEW_H = 28, 120
    local host = makeTable(flow.pane.child, nil, ROW_H, VIEW_H)
    local TTL = 14 * 86400

    local function rebuild()
        local child = host._child
        for _, r in ipairs(host._rows) do r:Hide() end
        local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
        local deleted = (data and data.deletedAIDs) or {}
        local list = {}
        for aid, epoch in pairs(deleted) do list[#list + 1] = { aid = aid, epoch = epoch } end
        table.sort(list, function(a, b) return (tonumber(a.aid) or 0) < (tonumber(b.aid) or 0) end)
        local now = (ns.Store and ns.Store.Now and ns.Store.Now()) or 0
        local i = 0
        for _, entry in ipairs(list) do
            i = i + 1
            local row = host._rows[i]
            if not row then
                row = CreateFrame("Frame", nil, child); row:SetHeight(ROW_H)
                row.bg = row:CreateTexture(nil, "BACKGROUND"); row.bg:SetAllPoints()
                row.aid = row:CreateFontString(nil, "OVERLAY"); row.aid:SetFontObject(UI.fonts.body)
                row.aid:SetPoint("LEFT", row, "LEFT", 8, 0); row.aid:SetWidth(60)
                row.exp = row:CreateFontString(nil, "OVERLAY"); row.exp:SetFontObject(UI.fonts.small)
                row.exp:SetPoint("LEFT", row, "LEFT", 72, 0); row.exp:SetWidth(160)
                row.rm = UI.MakeButton(row, { text = "Remove", width = 70, height = 20, variant = "quiet" })
                row.rm:ClearAllPoints(); row.rm:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                UI.Skin(row, function() row.bg:SetColorTexture(UI.Color(i % 2 == 0 and "raised" or "panel", 0.6))
                    row.exp:SetTextColor(UI.Color("muted")); row.aid:SetTextColor(UI.Color("text")) end)
                host._rows[i] = row
            end
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -(i - 1) * ROW_H)
            row:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -(i - 1) * ROW_H)
            local rem = (entry.epoch + TTL) - now
            row.aid:SetText("#" .. entry.aid)
            row.exp:SetText(rem > 0 and ("expires in " .. agoLabel(now - rem):gsub(" ago", "")) or "expired")
            local aid = entry.aid
            row.rm:SetScript("OnClick", function()
                local d = ns.Store and ns.Store.GetData and ns.Store.GetData()
                if d and d.deletedAIDs then d.deletedAIDs[aid] = nil end
                rebuild()
            end)
            row:Show()
        end
        child:SetHeight(math.max(1, i * ROW_H)); if i == 0 then child:SetHeight(1) end
        -- Empty state (round-3 item 32).
        if not host._empty then
            host._empty = child:CreateFontString(nil, "OVERLAY"); host._empty:SetFontObject(UI.fonts.small)
            host._empty:SetPoint("TOPLEFT", child, "TOPLEFT", 8, -6)
            UI.Skin(host._empty, function(self) self:SetTextColor(UI.Color("muted")) end)
        end
        host._empty:SetText("(No active tombstones.)")
        host._empty:SetShown(i == 0)
    end
    host._rebuild = rebuild
    registerLive(rebuild)   -- expiry countdown ticks on its own: ticker row
    UI.Skin(host, rebuild)
    flow.pane:AddBlock(host, host.arrange, 10, 0)
end

----------------------------------------------------------------------
-- Faction toggle header (shared by Auras + Automation)
----------------------------------------------------------------------

local function factionHeader(flow, page)
    local row = flow:AddRow({ vAlign = "center" })
    row:Label("Faction")
    local seg = row:SegmentedChoice({
        choices = { { value = "Alliance", text = "Alliance" }, { value = "Horde", text = "Horde" } },
        get = function() return ScopeFaction() end,
        set = function(v) SetScopeFaction(v); refreshPage(page) end,
    })
    register(page, function() if seg.Refresh then seg.Refresh() end end)
end

----------------------------------------------------------------------
-- 3. AURAS  (per-faction thresholds + Rend / Battle Shout class rules)
----------------------------------------------------------------------

local function buildAuras(flow)
    local UI = DaseekiUI
    flow:Hint("These settings/information are saved per faction.")
    factionHeader(flow, "auras")

    -- ── Threshold table (Aura · Normal · Minimum, in minutes) ────────────────
    flow:AddSection("Duration Thresholds")
    flow:Hint("Minutes remaining below which a buff turns yellow (Normal) then red (Minimum).")

    -- Column header row — each cell sized so the two muted numeric headers sit
    -- EXACTLY over their editboxes. Data row is icon(18) + gap(8) + name(168) +
    -- gap + nBox(82) + gap + mBox(82); the "Aura" header spans icon+gap+name = 194.
    local hdr = flow:AddRow()
    local hAura = hdr:Label("Aura"); hAura.uiWidth = 194; hAura:SetWidth(194)
    local hNorm = hdr:Label("Normal (min)", { muted = true }); hNorm.uiWidth = 82; hNorm:SetWidth(82)
    local hMin  = hdr:Label("Minimum (min)", { muted = true }); hMin.uiWidth = 82; hMin:SetWidth(82)

    for _, def in ipairs(AURA_DEFS) do
        local row = flow:AddRow({ vAlign = "center" })
        -- icon
        local ico = CreateFrame("Frame", nil, row); ico:SetSize(18, 18)
        ico.uiWidth, ico.uiHeight = 18, 18
        local tex = ico:CreateTexture(nil, "ARTWORK"); tex:SetAllPoints()
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92); tex:SetTexture(auraIcon(def.spellID))
        row._items[#row._items + 1] = { w = ico }
        local lbl = row:Label(def.label); lbl.uiWidth = 168; lbl:SetWidth(168)
        local function thr()
            local fs = FS(); if not fs then return nil end
            fs.auraOpts.thresholds[def.key] = fs.auraOpts.thresholds[def.key] or {}
            return fs.auraOpts.thresholds[def.key]
        end
        local nBox = row:EditBox({
            width = 82, numeric = true,
            get = function() local t = thr(); local v = t and t.normal; return v and tostring(math.floor(v / 60)) or "" end,
            set = function(v) local t = thr(); if t then t.normal = (tonumber(v) or 0) * 60 end end,
        })
        nBox._fillWidth = false
        local mBox = row:EditBox({
            width = 82, numeric = true,
            get = function() local t = thr(); local v = t and t.minimum; return v and tostring(math.floor(v / 60)) or "" end,
            set = function(v) local t = thr(); if t then t.minimum = (tonumber(v) or 0) * 60 end end,
        })
        mBox._fillWidth = false
        guardEdit(nBox); guardEdit(mBox)
        register("auras", function() if nBox.Refresh then nBox.Refresh() end; if mBox.Refresh then mBox.Refresh() end end)
    end

    -- ── Darkmoon Faire cooldown announcement ─────────────────────────────────
    -- Sits directly under the threshold table so it reads with the DMF row at
    -- the top of it. Wires the existing DaseekiNexusDB.dmfPushAnnounce, which
    -- tracker.lua reads through Tracker.DMFPushAnnounceEnabled when the debuff
    -- bar pushes the hidden DMF cooldown aura off (spec §5 / A8.4).
    --
    -- DEFAULT ON, and ABSENT counts as ON -- so the getter must test `~= false`,
    -- NOT plain truthiness, or an older SavedVariables file with no key would
    -- render an unticked box while the engine happily announced. The setter
    -- writes a real boolean, which also settles the key for good.
    --
    -- Account-wide, unlike everything else on this page; the hint says so.
    local dmfSec = flow:AddSection("Darkmoon Faire")
    local dmfRow = dmfSec:AddRow({ vAlign = "center" })
    register("auras", dmfRow:Checkbox({
        label = "Announce DMF cooldown clear in chat",
        get = function() local db = DB(); return db and db.dmfPushAnnounce ~= false end,
        set = function(v) local db = DB(); if db then db.dmfPushAnnounce = v and true or false end end,
    }).Refresh)
    dmfSec:Hint("When the debuff bar pushes the hidden DMF cooldown off, say so in SAY, "
        .. "and in RAID or PARTY when grouped, so everyone knows their fortune is back up. "
        .. "This setting is account-wide.")

    -- ── Rend / Battle Shout class rules (cycling buttons) ─────────────────────
    for _, g in ipairs(CLASS_RULE_GRIDS) do
        buildClassRuleGrid(flow, g.title, g.optKey, g.classes)
    end
end

-- A grid of cycling buttons: each class steps Required → Optional → Ignored.
-- State lives in FS().auraOpts[optKey].{required,optional,ignored}[class].
function buildClassRuleGrid(flow, title, optKey, classes)
    local UI = DaseekiUI
    flow:AddSection(title)
    flow:Hint("Required = red when missing · Optional = yellow · Ignored = hidden.")

    local STATES = { "required", "optional", "ignored" }
    -- Lowercase colored pill text (round-3 item 31).
    local STATE_LABEL = { required = "required", optional = "optional", ignored = "ignored" }
    local function getState(class)
        local fs = FS(); if not fs then return "ignored" end
        local o = fs.auraOpts[optKey]
        if o.required[class] then return "required" end
        if o.optional[class] then return "optional" end
        return "ignored"
    end
    local function setState(class, st)
        local fs = FS(); if not fs then return end
        local o = fs.auraOpts[optKey]
        o.required[class], o.optional[class], o.ignored[class] = nil, nil, nil
        if st == "required" then o.required[class] = true
        elseif st == "optional" then o.optional[class] = true
        else o.ignored[class] = true end
    end
    local function nextState(st)
        for i, s in ipairs(STATES) do if s == st then return STATES[(i % #STATES) + 1] end end
        return "ignored"
    end

    -- State -> token (Required = green, Optional = amber, Ignored = grey).
    local STATE_TOKEN = { required = "ok", optional = "warn", ignored = "faint" }

    -- One clickable cell: class-colored name on the left + a small state pill on
    -- the right (state word in its state color, bordered). Click cycles the state.
    local CELL_W, PILL_W = 156, 74
    local function makeClassCell(parent, class)
        local cell = CreateFrame("Button", nil, parent)
        cell:SetSize(CELL_W, 24)
        cell.uiWidth, cell.uiHeight = CELL_W, 24

        local name = cell:CreateFontString(nil, "OVERLAY")
        name:SetFontObject(UI.fonts.body)
        name:SetPoint("LEFT", cell, "LEFT", 2, 0)
        name:SetText(CLASS_LABEL[class] or class)

        local pill = CreateFrame("Frame", nil, cell, "BackdropTemplate")
        pill:SetSize(PILL_W, 18)
        pill:SetPoint("RIGHT", cell, "RIGHT", -2, 0)
        local pl = pill:CreateFontString(nil, "OVERLAY")
        pl:SetFontObject(UI.fonts.small)
        pl:SetPoint("CENTER", pill, "CENTER", 0, 0)

        local function paint()
            name:SetTextColor(classColor(class))
            local stt = getState(class)
            local tok = STATE_TOKEN[stt] or "faint"
            pl:SetText(STATE_LABEL[stt])
            pl:SetTextColor(UI.Color(tok))
            pill:SetBackdrop(UI.FLAT_BACKDROP)
            pill:SetBackdropColor(UI.Color(tok, 0.18))
            pill:SetBackdropBorderColor(UI.Color(tok))
        end
        cell._paint = paint
        cell:SetScript("OnClick", function() setState(class, nextState(getState(class))); paint() end)
        UI.Skin(cell, paint)   -- repaint on theme change (class colors + tokens)
        return cell
    end

    local perRow, i = 3, 0
    local row
    for _, class in ipairs(classes) do
        if i % perRow == 0 then row = flow:AddRow({ vAlign = "center" }) end
        i = i + 1
        local cell = makeClassCell(row, class)
        row._items[#row._items + 1] = { w = cell }
        register("auras", cell._paint)
    end
end

----------------------------------------------------------------------
-- 4. AUTOMATION  (Group / Accept Summon / Gossip / Quest / Interact)
----------------------------------------------------------------------

local function buildAutomation(flow)
    local UI = DaseekiUI
    local DS = _G.DaseekiSuite
    factionHeader(flow, "automation")

    -- ── Auto-accept invites (category grid) ────────────────────────────────────
    local grp = flow:AddSection("Auto-Accept Invites From")
    grp:Hint("Automatically accept party invitations from characters in these categories.")
    local acceptCats = {
        { label = "Known roster",   key = "acceptFromRoster"  },
        { label = "Guild",          key = "acceptFromGuild"   },
        { label = "Friends & BNet", key = "acceptFromFriends" },
        { label = "Anyone",         key = "acceptFromAnyone"  },
    }
    local acceptItems = {}
    for _, it in ipairs(acceptCats) do
        acceptItems[#acceptItems + 1] = {
            label = it.label,
            get = function() local fs = FS(); return fs and fs.autoGroup[it.key] end,
            set = function(v) local fs = FS(); if fs then fs.autoGroup[it.key] = v and true or false end end,
        }
    end
    local acceptGrid = grp:AddChecklist(acceptItems)
    register("automation", function() for _, b in ipairs(acceptGrid._boxes) do b:Refresh() end end)

    -- ── Whisper-keyword invite (per-category send gates, round-3 item 22) ───────
    -- The reference has four SEPARATE whisper-invite category checkboxes (parallel
    -- to the four accept-from gates). ENGINE DEPENDENCY: the send-category keys
    -- (sendToGuild/sendToFriends/sendToAnyone) are added by the engine agent; only
    -- sendToRoster exists today, so the other three read nil (unchecked) until merge.
    local kwSec = flow:AddSection("Auto-Invite On Whisper Keyword")
    kwSec:Hint("When someone whispers you the keyword, invite them if they fall in one of these categories.")
    local sendCats = {
        { label = "Known roster",   key = "sendToRoster"  },
        { label = "Guild",          key = "sendToGuild"   },
        { label = "Friends & BNet", key = "sendToFriends" },
        { label = "Anyone",         key = "sendToAnyone"  },
    }
    local sendItems = {}
    for _, it in ipairs(sendCats) do
        sendItems[#sendItems + 1] = {
            label = it.label,
            get = function() local fs = FS(); return fs and fs.autoGroup[it.key] end,
            set = function(v) local fs = FS(); if fs then fs.autoGroup[it.key] = v and true or false end end,
        }
    end
    local sendGrid = kwSec:AddChecklist(sendItems)
    register("automation", function() for _, b in ipairs(sendGrid._boxes) do b:Refresh() end end)
    local kw = kwSec:AddRow({ vAlign = "center" })
    kw:Label("Keyword:")
    local kwBox = kw:EditBox({
        width = 100,
        get = function() local fs = FS(); return fs and fs.autoGroup.inviteKeyword or "" end,
        set = function(v) local fs = FS(); if fs then fs.autoGroup.inviteKeyword = tostring(v or ""):gsub("%s", "") end end,
    })
    kwBox._fillWidth = false
    guardEdit(kwBox)
    register("automation", function() if kwBox.Refresh then kwBox.Refresh() end end)

    -- ── Invite whitelist (Enable toggle + inline editor, round-3 items 35 / 29) ──
    -- ENGINE DEPENDENCY: autoGroup.whitelistEnabled is added by the engine agent.
    -- Fallback preserves the prior "true-when-populated" semantics: when the key is
    -- absent (nil), the list is treated as enabled while it has entries.
    local wlSec = flow:AddSection("Auto-Invite Whitelist")
    wlSec:Hint("Characters listed here bypass the category filter in both directions. One Name-Realm per line. Auto-capitalized on save.")
    register("automation", wlSec:Checkbox({
        label = "Enable Whitelist",
        get = function()
            local fs = FS(); if not fs then return false end
            local v = fs.autoGroup.whitelistEnabled
            if v == nil then return countMap(fs.autoGroup.whitelist) > 0 end
            return v
        end,
        set = function(v) local fs = FS(); if fs then fs.autoGroup.whitelistEnabled = v and true or false end end,
    }).Refresh)
    buildTextArea(wlSec, {
        height = 96, register = "automation",
        get = function() local fs = FS(); return fs and mapToLines(fs.autoGroup.whitelist) or "" end,
        set = function(txt) local fs = FS(); if fs then fs.autoGroup.whitelist = linesToMap(txt); refreshPage("automation") end end,
    })

    -- ── Accept Summon ──────────────────────────────────────────────────────────
    local asx = flow:AddSection("Accept Summon")
    asx:Hint("Automatically accept a warlock or meeting-stone summon when it lands. " ..
        "A buff counts as \"fresh\" if it was gained within the window below. " ..
        "Auto-accept fires only while at least one Buff Trigger below is fresh (or Always Accept is on).")
    local asr = asx:AddRow({ vAlign = "center" })
    register("automation", asr:Checkbox({
        label = "Auto-accept summon",
        get = function() local fs = FS(); return fs and fs.autoSummon.enabled end,
        set = function(v) local fs = FS(); if fs then fs.autoSummon.enabled = v and true or false end end,
    }).Refresh)
    register("automation", asr:Checkbox({
        label = "Always accept",
        get = function() local fs = FS(); return fs and fs.autoSummon.alwaysAccept end,
        set = function(v) local fs = FS(); if fs then fs.autoSummon.alwaysAccept = v and true or false end end,
    }).Refresh)
    register("automation", asr:Checkbox({
        label = "Drop on taxi / PvP",
        get = function() local fs = FS(); return fs and fs.autoSummon.dropOnTaxiPvp end,
        set = function(v) local fs = FS(); if fs then fs.autoSummon.dropOnTaxiPvp = v and true or false end end,
    }).Refresh)

    local win = asx:AddRow({ vAlign = "center" })
    local winLbl = win:Label("Auto-accept window (seconds)"); winLbl.uiWidth = 190; winLbl._label:SetWidth(190)
    local winBox = win:EditBox({
        width = 60, numeric = true,
        get = function() local fs = FS(); return fs and tostring(fs.autoSummon.freshBuffWindow or 0) or "" end,
        set = function(v)
            local fs = FS(); if not fs then return end
            local n = tonumber(v) or 45
            if n < 5 then n = 5 elseif n > 3600 then n = 3600 end
            fs.autoSummon.freshBuffWindow = n
        end,
    })
    winBox._fillWidth = false
    guardEdit(winBox)
    win:Label("(5-3600)", { muted = true })
    register("automation", function() if winBox.Refresh then winBox.Refresh() end end)

    -- Buff triggers sub-group (round-3 item 23): all ten trigger buffs, each as an
    -- icon + "ABBR - Full Name" checkbox row (two per row for compactness).
    -- ENGINE DEPENDENCY: the authoritative key set is ns.Store.SUMMON_TRIGGER_KEYS
    -- (the store's mirror of auto.lua's Auto.SUMMON_TRIGGER_BUFFS). This used to
    -- read ns.Store.SUMMON_TRIGGER_BUFFS, which no file ever defined -- so the
    -- merge below was dead and the fallback ran every time. That hid the fact
    -- that TRIGGER_DEFS was keyed by AURA keys; both are fixed in this batch, and
    -- a store selftest now asserts the two key sets match exactly.
    --
    -- TRIGGER_DEFS supplies labels/icons AND the owner-approved display ORDER, so
    -- the engine list is used only to confirm membership: keys are rendered in
    -- TRIGGER_DEFS order, with any engine key missing from it appended.
    local bt = flow:AddSection("Buff Triggers")
    bt:Hint("Accept a pending summon when one of these buffs is freshly gained.")
    local triggerKeys = ns.Store and ns.Store.SUMMON_TRIGGER_KEYS
    local function trigMeta(key)
        for _, d in ipairs(TRIGGER_DEFS) do if d.key == key then return d end end
        return { key = key, abbr = key, name = key, spellID = nil }
    end
    local trigList = {}
    if type(triggerKeys) == "table" and #triggerKeys > 0 then
        -- Engine-authoritative membership, TRIGGER_DEFS display order.
        local want, taken = {}, {}
        for _, k in ipairs(triggerKeys) do want[k] = true end
        for _, d in ipairs(TRIGGER_DEFS) do
            if want[d.key] then trigList[#trigList + 1] = d; taken[d.key] = true end
        end
        -- Anything the engine knows and the UI catalog does not: append it rather
        -- than silently drop it (a visible raw-key row is a loud bug report).
        for _, k in ipairs(triggerKeys) do
            if not taken[k] then trigList[#trigList + 1] = trigMeta(k) end
        end
    else
        trigList = TRIGGER_DEFS
    end
    local btRow, perRow, count = nil, 2, 0
    for _, def in ipairs(trigList) do
        if count % perRow == 0 then btRow = bt:AddRow({ vAlign = "center" }) end
        count = count + 1
        -- icon
        local ico = CreateFrame("Frame", nil, btRow); ico:SetSize(18, 18); ico.uiWidth, ico.uiHeight = 18, 18
        local tex = ico:CreateTexture(nil, "ARTWORK"); tex:SetAllPoints()
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92); tex:SetTexture(auraIcon(def.spellID))
        btRow._items[#btRow._items + 1] = { w = ico }
        local key = def.key
        local cb = btRow:Checkbox({
            label = def.abbr .. " - " .. def.name,
            get = function() local fs = FS(); return fs and fs.autoSummon.triggers[key] end,
            set = function(v) local fs = FS(); if fs then fs.autoSummon.triggers[key] = v and true or nil end end,
        })
        cb.uiWidth = 230
        register("automation", cb.Refresh)
    end

    -- ── Gossip ─────────────────────────────────────────────────────────────────
    local gos = flow:AddSection("Gossip")
    gos:Hint("Automatically pick the right gossip option at these NPCs and portals.")
    local gr = gos:AddRow({ vAlign = "center" })
    register("automation", gr:Checkbox({
        label = "Dire Maul tribute",
        get = function() local fs = FS(); return fs and fs.autoGossip.dmt end,
        set = function(v) local fs = FS(); if fs then fs.autoGossip.dmt = v and true or false end end,
    }).Refresh)
    register("automation", gr:Checkbox({
        label = "BWL Orb of Command",
        get = function() local fs = FS(); return fs and fs.autoGossip.bwl end,
        set = function(v) local fs = FS(); if fs then fs.autoGossip.bwl = v and true or false end end,
    }).Refresh)

    local dr = gos:AddRow({ vAlign = "center" })
    register("automation", dr:Checkbox({
        label = "DMF: auto-select Sayge fortune",
        get = function() local fs = FS(); return fs and fs.autoGossip.dmf.enabled end,
        set = function(v) local fs = FS(); if fs then fs.autoGossip.dmf.enabled = v and true or false end end,
    }).Refresh)
    register("automation", dr:Checkbox({
        label = "Skip fortune cookie",
        get = function() local fs = FS(); return fs and fs.autoGossip.dmf.skipCookie end,
        set = function(v) local fs = FS(); if fs then fs.autoGossip.dmf.skipCookie = v and true or false end end,
    }).Refresh)
    gos:Hint("|cffffd100Caution: Sayge's fortune is permanent for the day — choose the per-class buff carefully.|r")

    gos:Label("Sayge buff type per class", { muted = true })
    local choices = {}
    for _, t in ipairs(DMF_BUFF_TYPES) do choices[#choices + 1] = { value = t, text = DMF_BUFF_TYPE_LABEL[t] } end
    local gossipRows = {}
    for _, class in ipairs(REND_CLASSES) do
        local row = gos:AddRow({ vAlign = "center" })
        local lbl = row:Label(CLASS_LABEL[class] or class); lbl.uiWidth = 90; lbl:SetWidth(90)
        local dd = row:Dropdown({
            width = 130, choices = choices,
            get = function() local fs = FS(); return fs and fs.autoGossip.dmf.buffType[class] or "damage" end,
            set = function(v) local fs = FS(); if fs then fs.autoGossip.dmf.buffType[class] = v end end,
        })
        gossipRows[class] = { row = row, dd = dd,
            blk = gos.pane.blocks[#gos.pane.blocks] }
        -- faction-filter cond block
        local blk = gos.pane.blocks[#gos.pane.blocks]
        local origArrange = blk.arrange
        blk.arrange = function(width)
            local reqF = CLASS_FACTION[class]
            if reqF and reqF ~= ScopeFaction() then row:Hide(); return 0 end
            row:Show(); return origArrange(width)
        end
        blk._baseGap = blk.topGap
        register("automation", function()
            local reqF = CLASS_FACTION[class]
            blk.topGap = (reqF and reqF ~= ScopeFaction()) and 0 or blk._baseGap
            if dd.Refresh then dd.Refresh() end
        end)
    end

    -- ── Quest ──────────────────────────────────────────────────────────────────
    local q = flow:AddSection("Quest")
    q:Hint("Automatically turn in these repeatable buff quests and pick your rewards.")
    local qa = q:AddRow({ vAlign = "center" })
    register("automation", qa:Checkbox({
        label = "Winterspring E'ko",
        get = function() local fs = FS(); return fs and fs.autoQuest.eko end,
        set = function(v) local fs = FS(); if fs then fs.autoQuest.eko = v and true or false end end,
    }).Refresh)
    register("automation", qa:Checkbox({
        label = "Yojamba coins",
        get = function() local fs = FS(); return fs and fs.autoQuest.zgCoins end,
        set = function(v) local fs = FS(); if fs then fs.autoQuest.zgCoins = v and true or false end end,
    }).Refresh)
    local qb = q:AddRow({ vAlign = "center" })
    register("automation", qb:Checkbox({
        label = "Blasted Lands R.O.I.D.S.",
        get = function() local fs = FS(); return fs and fs.autoQuest.roids end,
        set = function(v) local fs = FS(); if fs then fs.autoQuest.roids = v and true or false end end,
    }).Refresh)
    register("automation", qb:Checkbox({
        label = "Auto-repair at Rin'wosho",
        get = function() local fs = FS(); return fs and fs.autoQuest.autoRepair end,
        set = function(v) local fs = FS(); if fs then fs.autoQuest.autoRepair = v and true or false end end,
    }).Refresh)

    -- Zanza parent + indented sub-picks (round-3 item 30).
    local zr = q:AddRow({ vAlign = "center" })
    register("automation", zr:Checkbox({
        label = "Zanza buffs",
        get = function() local fs = FS(); return fs and fs.autoQuest.zanza.enabled end,
        set = function(v) local fs = FS(); if fs then fs.autoQuest.zanza.enabled = v and true or false end end,
    }).Refresh)
    local zpick = q:AddRow({ vAlign = "center" })
    zpick._indent = zpick._indent + 20
    -- Zanza pick membership (priority list). Order fixed; membership toggled.
    local function pickIndex(list, key) for i, k in ipairs(list or {}) do if k == key then return i end end return nil end
    for _, pick in ipairs(ZANZA_PICKS) do
        register("automation", zpick:Checkbox({
            label = pick.label,
            get = function() local fs = FS(); return fs and pickIndex(fs.autoQuest.zanza.priority, pick.key) ~= nil end,
            set = function(v)
                local fs = FS(); if not fs then return end
                local pr = fs.autoQuest.zanza.priority
                local idx = pickIndex(pr, pick.key)
                if v and not idx then pr[#pr + 1] = pick.key
                elseif not v and idx then table.remove(pr, idx) end
            end,
        }).Refresh)
    end

    -- ── Interact Buttons: REMOVED (owner feedback 2b) ──────────────────────────
    -- The Interact feature is cut suite-wide; the engine agent removes
    -- interact.lua, the autoInteract store keys, the importer mapping and the
    -- /nexus coord command on their branch. Nothing renders here now.
end

----------------------------------------------------------------------
-- 5. TIMERS & ALERTS
----------------------------------------------------------------------

local function buildTimers(flow)
    local UI = DaseekiUI

    -- ── Raid overrides ─────────────────────────────────────────────────────────
    -- Five independent toggles (A12.2 adds "Bars"; A12.3 raised the four channel
    -- defaults to all-on). The first four silence an alert CHANNEL; "Bars" is not
    -- a channel — it suppresses pull-bar creation only, so a raid can be visually
    -- empty while chat/screen alerts still land, or vice versa.
    --
    -- Every one of the five DEFAULTS ON, so an absent stored key must read
    -- CHECKED here — matching HUD.SuppressBarsInRaid / HUD.RaidChannelSuppressed,
    -- which apply the same absent-means-on rule at the gate. Reading a raw nil as
    -- unchecked would show the owner the opposite of what the HUD is doing.
    local ro = flow:AddSection("Raid Overrides")
    ro:Hint("While inside a raid instance, suppress these alert channels — and, "
        .. "independently, the pull-timer bars.")
    local rr = ro:AddRow({ vAlign = "center" })
    local function roCheck(label, key)
        register("timers", rr:Checkbox({
            label = label,
            -- Explicit ifs: `(type(rd)=="table") and rd[key] or nil` would
            -- collapse a stored FALSE to nil and re-check a box the owner
            -- deliberately cleared. Mirrors HUD._RaidFlag exactly.
            get = function()
                local ts = TS()
                if not ts then return true end
                local rd = ts.raidDisable
                if type(rd) ~= "table" then return true end
                local v = rd[key]
                if v == nil then return true end   -- absent = ON (A12.2 / A12.3)
                return v == true
            end,
            set = function(v)
                local ts = TS(); if not ts then return end
                if type(ts.raidDisable) ~= "table" then ts.raidDisable = {} end
                ts.raidDisable[key] = v and true or false
            end,
        }).Refresh)
    end
    roCheck("Screen", "notify"); roCheck("Chat", "chat"); roCheck("Flash", "flash")
    roCheck("Sound", "sound");   roCheck("Bars", "bars")

    -- (The event×channel Alert Matrix + Sound channel moved to their own "Alerts"
    -- page — see buildAlerts. This page keeps raid overrides, pull-bar geometry
    -- and Felwood pins.)

    -- ── Pull-timer bars ────────────────────────────────────────────────────────
    local pb = flow:AddSection("Pull Timer Bars")
    pb:Hint("On-screen countdown bars for detected pulls. Lock to click through; use the mover to reposition.")
    local pbr = pb:AddRow({ vAlign = "center" })
    register("timers", pbr:Checkbox({
        label = "Lock bars",
        get = function() local ts = TS(); return ts and ts.pullBar.locked end,
        set = function(v) local ts = TS(); if ts then ts.pullBar.locked = v and true or false end end,
    }).Refresh)
    pbr:Button({ text = "Move Pull Timers", width = 150, pin = "right", onClick = hudShowMover })

    local pw = pb:Slider({
        label = "Bar width (px) — (100-400) default 220", width = 260, min = 100, max = 400, step = 5,
        get = function() local ts = TS(); return ts and ts.pullBar.width or 220 end,
        set = function(v) local ts = TS(); if ts then ts.pullBar.width = v end end,
        format = function(v) return tostring(math.floor(v)) end,
    })
    local ph = pb:Slider({
        label = "Bar height (px) — (10-40) default 18", width = 260, min = 10, max = 40, step = 1,
        get = function() local ts = TS(); return ts and ts.pullBar.height or 18 end,
        set = function(v) local ts = TS(); if ts then ts.pullBar.height = v end end,
        format = function(v) return tostring(math.floor(v)) end,
    })
    -- Idle/small-bar geometry + expand trigger — the HUD's actual runtime keys
    -- (hud.lua reads pullBar.smallWidth/smallHeight/expandThreshold). Main/small
    -- positions are mover-managed (mainPos/smallPos), so no controls for those.
    local psw = pb:Slider({
        label = "Small bar width (px) — (80-320) default 158", width = 260, min = 80, max = 320, step = 5,
        get = function() local ts = TS(); return ts and ts.pullBar.smallWidth or 158 end,
        set = function(v) local ts = TS(); if ts then ts.pullBar.smallWidth = v end end,
        format = function(v) return tostring(math.floor(v)) end,
    })
    local psh = pb:Slider({
        label = "Small bar height (px) — (8-32) default 14", width = 260, min = 8, max = 32, step = 1,
        get = function() local ts = TS(); return ts and ts.pullBar.smallHeight or 14 end,
        set = function(v) local ts = TS(); if ts then ts.pullBar.smallHeight = v end end,
        format = function(v) return tostring(math.floor(v)) end,
    })
    local pex = pb:Slider({
        label = "Expand-to-center threshold (s) — (3-30) default 10", width = 260, min = 3, max = 30, step = 1,
        get = function() local ts = TS(); return ts and ts.pullBar.expandThreshold or 10 end,
        set = function(v) local ts = TS(); if ts then ts.pullBar.expandThreshold = v end end,
        format = function(v) return tostring(math.floor(v)) .. "s" end,
    })
    register("timers", function()
        if pw.Refresh then pw.Refresh() end; if ph.Refresh then ph.Refresh() end
        if psw.Refresh then psw.Refresh() end; if psh.Refresh then psh.Refresh() end
        if pex.Refresh then pex.Refresh() end
    end)

    -- (Raw Fill/BG hex editboxes removed — the active theme's tokens are the only
    -- colour authority per §2/§6. The pullBar.colorFill/colorBG store keys stay
    -- harmlessly for any legacy reader; only the controls are gone.)

    -- ── Felwood pins ───────────────────────────────────────────────────────────
    local fw = flow:AddSection("Felwood Pins")
    fw:Hint("Show songflower and tuber spawn pins on the world map and minimap.")
    local fwr = fw:AddRow({ vAlign = "center" })
    register("timers", fwr:Checkbox({
        label = "Show flower pins",
        get = function() local ts = TS(); return ts and ts.felwood.showFlowerPins end,
        set = function(v) local ts = TS(); if ts then ts.felwood.showFlowerPins = v and true or false end end,
    }).Refresh)
    register("timers", fwr:Checkbox({
        label = "Show tuber pins",
        get = function() local ts = TS(); return ts and ts.felwood.showTuberPins end,
        set = function(v) local ts = TS(); if ts then ts.felwood.showTuberPins = v and true or false end end,
    }).Refresh)
    -- Show songflower picked-chat alerts (round-3 item 28). ENGINE DEPENDENCY:
    -- felwood.pickedChatAlerts is added by the engine agent; nil reads as off.
    register("timers", fw:Checkbox({
        label = "Show songflower picked chat alerts",
        get = function() local ts = TS(); return ts and ts.felwood.pickedChatAlerts end,
        set = function(v) local ts = TS(); if ts then ts.felwood.pickedChatAlerts = v and true or false end end,
    }).Refresh)

    -- Pin sizing merged from five sliders to two (IA cleanup): one "World map pin
    -- size" + one "Minimap pin size", plus the timer-font slider which stays.
    -- Each merged slider WRITES THROUGH additively: it sets the legacy base key
    -- (worldPinSize / minimapPinSize) AND both split keys (flower + tuber), so
    -- every historical reader keeps working. Reads prefer the base key, then a
    -- split key, then the default.
    local pinSliders = {}
    local worldSlider = fw:Slider({
        label = "World map pin size (px) — (8-24) default 14", width = 300, min = 8, max = 24, step = 1,
        get = function() local ts = TS(); if not ts then return 14 end
            return ts.felwood.worldPinSize or ts.felwood.worldFlowerSize or ts.felwood.worldTuberSize or 14 end,
        set = function(v) local ts = TS(); if ts then writeWorldPinSize(ts.felwood, v) end end,
        format = function(v) return tostring(math.floor(v)) end,
    })
    pinSliders[#pinSliders + 1] = worldSlider
    local fontSlider = fw:Slider({
        label = "World map timer font (pt) — (6-20) default 10", width = 300, min = 6, max = 20, step = 1,
        get = function() local ts = TS(); return ts and ts.felwood.worldTimerFont or 10 end,
        set = function(v) local ts = TS(); if ts then ts.felwood.worldTimerFont = v end end,
        format = function(v) return tostring(math.floor(v)) end,
    })
    pinSliders[#pinSliders + 1] = fontSlider
    local minimapSlider = fw:Slider({
        label = "Minimap pin size (px) — (8-24) default 12", width = 300, min = 8, max = 24, step = 1,
        get = function() local ts = TS(); if not ts then return 12 end
            return ts.felwood.minimapPinSize or ts.felwood.minimapFlowerSize or ts.felwood.minimapTuberSize or 12 end,
        set = function(v) local ts = TS(); if ts then writeMinimapPinSize(ts.felwood, v) end end,
        format = function(v) return tostring(math.floor(v)) end,
    })
    pinSliders[#pinSliders + 1] = minimapSlider
    register("timers", function() for _, s in ipairs(pinSliders) do if s.Refresh then s.Refresh() end end end)

    -- ── Songflower display ───────────────────────────────────────────────────────
    -- Drives the songflower UP?/minus display state machine (timers.lua NodeState).
    local sf = flow:AddSection("Songflower Display")
    -- F13: the old section hint described the removed "UP? duration" slider.
    -- A picked node counts down, shows "UP?" when it respawns, then runs the
    -- expired window below before going quiet.
    sf:Hint("Picked nodes count down, show \"UP?\" on respawn, then fade out.")
    -- ROUND-17b: this slider used to write felwood.flowerMinusDuration, which the engine
    -- stopped consuming as a respawn length (the respawn is fixed) — the control was inert.
    -- It now drives felwood.flowerExpiredWindow, the live key timers.lua reads (default
    -- 300, clamped 0-900). UP? keeps its own 0="always" sentinel below.
    local sfMinus = sf:Slider({
        label = "Expired window — (0-15:00) default 5:00", width = 300, min = 0, max = 900, step = 30,
        get = function() local ts = TS(); return ts and ts.felwood.flowerExpiredWindow or 300 end,
        set = function(v) local ts = TS(); if ts then ts.felwood.flowerExpiredWindow = v end end,
        format = function(v) v = math.floor(v); return ("%d:%02d"):format(math.floor(v / 60), v % 60) end,
    })
    sf:Hint("How long a respawned flower shows a negative counter before going quiet.")
    -- F13: the "UP? duration" slider is GONE. It wrote felwood.flowerUpDuration,
    -- and since the pin display moved to the three-state model (cooldown ->
    -- "UP?" -> expired window) nothing reads that key: timers.lua drives the
    -- states from NODE_RESPAWN + flowerExpiredWindow, pins.lua asks
    -- Timers.GetNodeState, and import.lua explicitly refuses to import it. The
    -- control moved a number that changed nothing on screen — worse than absent,
    -- because it read as a working setting. The stored key and its 5 -> 0
    -- migration stay in store.lua: removing them would be a SavedVariables
    -- change, and they are harmless once nothing offers to edit them.
    register("timers", function() if sfMinus.Refresh then sfMinus.Refresh() end end)

    -- ── Danger: reset timer data ───────────────────────────────────────────────
    flow:AddSection("Danger Zone")
    flow:AddRow():Button({ text = "Reset Timer Data", width = 170, variant = "danger", onClick = function()
        UI.Confirm({ title = "Reset Timer Data", danger = true,
            text = "Wipe all recorded node timers and pop logs? World-buff/settings data is untouched.",
            acceptText = "Reset",
            onAccept = function()
                local t = ns.Store and ns.Store.GetTimers and ns.Store.GetTimers()
                if not t then return end
                t.flower, t.tuber = {}, {}
                t.logs = { rend = {}, onyH = {}, onyA = {} }
                t.timerVersion = (t.timerVersion or 1) + 1
                -- F13: wiping the SAVED tables is only half a reset. timers.lua
                -- also holds in-memory anchors (pending pulls, last-yell epochs,
                -- dedup stamps, derived cooldown state) that outlive this button,
                -- so the old data walked straight back into the fresh tables and
                -- "Reset Timer Data" appeared not to work until a /reload.
                -- Guarded on existence: the export lands with the timers-side
                -- change, and a missing one must degrade to the old behaviour
                -- rather than error inside a confirm handler.
                if ns.Timers and type(ns.Timers.ResetState) == "function" then
                    ns:SafeCall(ns.Timers.ResetState)
                end
                -- Live bars are derived from the same state; drop them too so the
                -- screen matches the store.
                if ns.HUD and type(ns.HUD.ClearBars) == "function" then
                    ns:SafeCall(ns.HUD.ClearBars)
                end
                ns:Print("timer data reset.")
            end })
    end })
end

----------------------------------------------------------------------
-- 6. ALERTS  (event×channel matrix + sound channel — split off from Timers)
----------------------------------------------------------------------

local function buildAlerts(flow)
    -- The matrix groups by event type: each event is a sub-header, under which sit
    -- the buff rows for that event, each row = buff icon + name + inline On /
    -- Screen / Chat / Flash checkboxes + a per-row Sound dropdown + Test.
    -- ENGINE DEPENDENCIES (defensive fallbacks; see report):
    --   * cell.enabled — the "On" master flag (defaults true when absent).
    --   * cell.sound — per-row sound tone (item 14; replaces the old event-level
    --     ts.soundKeys). Falls back to "" (None) until the engine schema lands.
    --   * ns.Store.ALERT_EVENT_BUFFS / ALERT_EVENT_TYPES — per-event buff sets +
    --     order (item 24; local fallbacks encode the reference sets).
    flow:AddSection("Alerts")
    flow:Hint("Choose how each timer event notifies you, per event type.")

    -- Sound channel (global; spec §8 Sound Channel dropdown).
    local scRow = flow:AddRow({ vAlign = "center" })
    local scLbl = scRow:Label("Sound channel"); scLbl.uiWidth = 100; scLbl._label:SetWidth(100)
    local scDD = scRow:Dropdown({
        width = 140, choices = SOUND_CHANNELS,
        get = function() local ts = TS(); return ts and ts.soundChannel or "Master" end,
        set = function(v) local ts = TS(); if ts then ts.soundChannel = v end end,
    })
    register("alerts", function() if scDD.Refresh then scDD.Refresh() end end)

    -- Event-major schema: alerts[eventType][buffKey].
    local function alertCell(buffKey, evt)
        local ts = TS(); if not ts then return nil end
        ts.alerts[evt] = ts.alerts[evt] or {}
        ts.alerts[evt][buffKey] = ts.alerts[evt][buffKey] or {}
        return ts.alerts[evt][buffKey]
    end

    for _, evt in ipairs(alertEventOrder()) do
        local buffs = alertEventBuffs(evt)
        if #buffs > 0 then
            local es = flow:AddSection(ALERT_EVENT_LABEL[evt] or evt)
            for _, k in ipairs(buffs) do
                local meta = ALERT_BUFF_META[k] or { name = ALERT_BUFF_LABEL[k] or k }
                local row = es:AddRow({ vAlign = "center" })
                -- icon
                local ico = CreateFrame("Frame", nil, row); ico:SetSize(18, 18); ico.uiWidth, ico.uiHeight = 18, 18
                local tex = ico:CreateTexture(nil, "ARTWORK"); tex:SetAllPoints()
                tex:SetTexCoord(0.08, 0.92, 0.08, 0.92); tex:SetTexture(auraIcon(meta.spellID))
                row._items[#row._items + 1] = { w = ico }
                local nlbl = row:Label(meta.name); nlbl.uiWidth = 118; nlbl._label:SetWidth(118)
                -- On (master enable; defaults true when the engine key is absent).
                register("alerts", row:Checkbox({
                    label = "On",
                    get = function() local c = alertCell(k, evt); if not c then return false end
                        if c.enabled == nil then return true end; return c.enabled end,
                    set = function(v) local c = alertCell(k, evt); if c then c.enabled = v and true or false end end,
                }).Refresh)
                local function chan(label, key)
                    register("alerts", row:Checkbox({
                        label = label,
                        get = function() local c = alertCell(k, evt); return c and c[key] end,
                        set = function(v) local c = alertCell(k, evt); if c then c[key] = v and true or false end end,
                    }).Refresh)
                end
                chan("Screen", "notify"); chan("Chat", "chat"); chan("Flash", "flash")
                local dd = row:Dropdown({
                    width = 120, choices = soundChoices(),
                    get = function() local c = alertCell(k, evt); return (c and c.sound) or "" end,
                    set = function(v) local c = alertCell(k, evt); if c then c.sound = v end end,
                })
                dd._fillWidth = false
                register("alerts", function() if dd.Refresh then dd.Refresh() end end)
                row:Button({ text = "Test", width = 52, variant = "quiet", pin = "right", onClick = function()
                    hudTestAlert(k, evt)
                end })
            end
        end
    end
end

----------------------------------------------------------------------
-- 7. BLACKLIST
----------------------------------------------------------------------

local function buildBlacklist(flow)
    local UI = DaseekiUI
    local DS = _G.DaseekiSuite

    -- ── Character Blacklist (inline textareas, round-3 item 33) ────────────────
    local sec = flow:AddSection("Character Blacklist")
    sec:Hint("Blacklisted characters show struck-through on the dashboard (not hidden). They still function normally in-game.")
    buildTextArea(sec, {
        height = 110, register = "blacklist",
        get = function() local db = DB(); return db and mapToLines(db.ui.blacklist) or "" end,
        set = function(txt) local db = DB(); if db then db.ui.blacklist = linesToMap(txt); refreshPage("blacklist") end end,
    })

    local wl = flow:AddSection("Blacklist Whitelist")
    wl:Hint("Removes characters from blacklists on all online mesh accounts. One Name-Realm per line.")
    buildTextArea(wl, {
        height = 96, register = "blacklist",
        get = function() local db = DB(); return db and mapToLines(db.ui.whitelist) or "" end,
        set = function(txt) local db = DB(); if db then db.ui.whitelist = linesToMap(txt); refreshPage("blacklist") end end,
    })

    wl:AddRow():Button({ text = "Sync Blacklist to Mesh", width = 200, onClick = function()
        if not (ns.Mesh and ns.Mesh.IsEnabled and ns.Mesh.IsEnabled()) then
            ns:Print("mesh is not enabled — nothing to sync."); return
        end
        local sent = 0
        for _, p in pairs(ns.Mesh.peers or {}) do
            if p.online and p.name and ns.Mesh.SendBlacklist then ns.Mesh.SendBlacklist(p.name); sent = sent + 1 end
        end
        ns:Print("blacklist sync sent to " .. sent .. " account(s).")
    end })

    -- ── Purge Account Data (danger, self-protected; round-3 item 33) ───────────
    local pz = flow:AddSection("Purge Account Data")
    pz:Hint("Permanently remove all stored data for another account. You cannot purge your own account.")
    local paRow = pz:AddRow({ vAlign = "center" })
    paRow:Label("Account ID")
    -- get() is a constant "" (this is an input, not a mirror of stored state), so any
    -- repaint while focused would blank what the owner just typed. Guarded like the rest.
    local paBox = paRow:EditBox({ width = 60, get = function() return "" end })
    paBox._fillWidth = false
    guardEdit(paBox)
    paRow:Button({ text = "Purge Account", width = 130, variant = "danger", onClick = function()
        local aid = tostring(paBox.editBox:GetText() or ""):gsub("%s", "")
        if aid == "" then return end
        if aid == ns:GetAccountID() or (ns.Store.IsSelfAccount and ns.Store.IsSelfAccount(aid)) then
            ns:Print("cannot purge your own account."); return
        end
        UI.Confirm({ title = "Purge Account #" .. aid, danger = true,
            text = "Remove all data for account #" .. aid .. "? Blocked from re-adding for 14 days.",
            acceptText = "Purge",
            onAccept = function()
                if ns.Store.TombstoneAccount then ns.Store.TombstoneAccount(aid) end
                if ns.Mesh and ns.Mesh.peers then ns.Mesh.peers[aid] = nil end
                paBox.editBox:SetText("")
                ns:Print("account #" .. aid .. " purged.")
            end })
    end })

    -- ── Character Purge (danger, self-protected; round-3 item 33) ──────────────
    local cpz = flow:AddSection("Character Purge")
    cpz:Hint("Recoverable if that character logs in again. Cannot purge your current character.")
    local pcRow = cpz:AddRow({ vAlign = "center" })
    pcRow:Label("Character")
    local pcBox = pcRow:EditBox({ width = 160, get = function() return "" end })
    pcBox._fillWidth = false
    guardEdit(pcBox)
    pcRow:Button({ text = "Purge Character", width = 140, variant = "danger", onClick = function()
        local nr = tostring(pcBox.editBox:GetText() or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if nr == "" then return end
        local selfNR
        if UnitName then
            local realm = (GetRealmName and GetRealmName() or ""):gsub("%s+", "")
            selfNR = UnitName("player") .. "-" .. realm
        end
        if nr == selfNR then ns:Print("cannot purge your current character."); return end
        UI.Confirm({ title = "Purge Character", danger = true,
            text = "Remove all stored data for " .. nr .. "?", acceptText = "Purge",
            onAccept = function()
                local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
                if data and data.accounts then
                    for _, bucket in pairs(data.accounts) do
                        if bucket.characters then bucket.characters[nr] = nil end
                        if bucket.homeless then bucket.homeless[nr] = nil end
                    end
                end
                pcBox.editBox:SetText("")
                ns:Print(nr .. " purged.")
            end })
    end })
end

----------------------------------------------------------------------
-- 8. INSTANCES  (NovaInstanceTracker absorption — the Instances tab's settings)
----------------------------------------------------------------------

local function buildInstances(flow)
    local sec = flow:AddSection("Instances")
    sec:Hint("The Instances panel tracks dungeon/raid entries against the server's rolling "
        .. "caps (5 per hour, 30 per day, per account).")

    -- Warn-on-entry chat notice. Wires the existing DaseekiNexusDB.instancesWarnOnEntry
    -- (store default ON); the engine (instances.lua) reads this flag and prints
    -- "4 of 5 hourly instances used." when the account first reaches the warn threshold.
    local r = sec:AddRow({ vAlign = "center" })
    register("instances", r:Checkbox({
        label = "Warn in chat when nearing the hourly cap",
        get = function() local db = DB(); return db and db.instancesWarnOnEntry ~= false end,
        set = function(v) local db = DB(); if db then db.instancesWarnOnEntry = v and true or false end end,
    }).Refresh)
    sec:Hint("Prints a one-line notice on the entry that reaches "
        .. tostring((ns.Instances and ns.Instances.WARN_HOURLY) or 4) .. " of "
        .. tostring((ns.Instances and ns.Instances.HOURLY_CAP) or 5) .. " hourly instances.")
end

----------------------------------------------------------------------
-- Live-refresh ticker (Accounts / Tombstones update while visible)
----------------------------------------------------------------------

local liveTicker
local function ensureLiveTicker()
    if liveTicker then return end
    if not C_Timer or not C_Timer.NewTicker then return end
    liveTicker = C_Timer.NewTicker(2, function()
        local pane = Options._meshPane
        if pane and pane.IsVisible and pane:IsVisible() then
            -- Live rows ONLY (accounts table, tombstones, capacity readout). The
            -- ticker exists for those; repainting the whole page every 2s also
            -- rewrote the credential fields, which is what ate in-progress typing.
            -- The editboxes keep their HasFocus guard regardless -- belt and braces.
            refreshPage("meshLive")
        end
    end)
end

----------------------------------------------------------------------
-- Help (round-13: moved verbatim from the old in-dashboard Help tab into the hub —
-- the dashboard is now single-page, so Help lives at Settings -> Nexus -> Help).
----------------------------------------------------------------------
local function buildHelp(flow)
    local s = flow:AddSection("Daseeki Nexus")
    s:Hint("Cross-account world-buff dashboard and timers for the Daseeki suite. "
        .. "Every account that shares your mesh Channel and Token sees the same roster.")

    local g = flow:AddSection("Setup Guide")
    g:Hint("1.  Install Daseeki Nexus on every account you want connected.")
    g:Hint("2.  On each account, open Settings \226\134\146 Mesh & Accounts and set a unique Account ID (1\226\128\1512 digits, different on each account).")
    g:Hint("3.  On the same Mesh & Accounts page, set the SAME Channel name (16+ letters/numbers, case sensitive) AND the SAME Token (6 letters/numbers) on every account \226\128\148 generate the credentials there, or paste a setup bundle to copy the same Channel and Token to another account.")
    g:Hint("4.  Enable the mesh, then log out and back in once on each account \226\128\148 characters appear across your accounts within seconds.")
    g:Hint("5.  Migrating from another world-buff addon? Run /nexus import to carry over ShadowNetwork's settings, Channel, Token and data, and /nexus import instances for NovaInstanceTracker's instance runs (see Troubleshooting).")
    g:Hint("Prefer it guided? Settings \226\134\146 Mesh & Accounts has a Setup guide button that walks steps 2\226\128\1514 in a three-step dialog with a live done/needed status on each step.")
    g:Hint("Open this hub any time from the dashboard's Settings button, or with /nexus settings.")

    local c = flow:AddSection("Slash commands")
    c:Hint("Primary /nexus  \194\183  short /dnx  \194\183  aliases /dsn, /daseekinetwork")
    c:Hint("/nexus toggle \226\128\148 show or hide the dashboard")
    c:Hint("/nexus x \226\128\148 open the Cancel Buffs popup (/nexus cancelbuffs does the same)")
    c:Hint("/nexus invite \226\128\148 invite all online characters")
    c:Hint("/nexus resetui \226\128\148 reset the dashboard window position (/nexus reset does the same)")
    c:Hint("/nexus mover \226\128\148 show the mover handle for the pull-timer bars")
    c:Hint("/nexus w <Char[-Server]> <message> \226\128\148 whisper a character; leave the server off to target your own realm")
    c:Hint("/nexus account <id> \226\128\148 show or set this account's mesh ID")
    c:Hint("/nexus settings \226\128\148 open the Daseeki hub to Nexus settings")
    c:Hint("/nexus syncsettings \226\128\148 push your settings to the other accounts on the mesh (the same action as the Sync Settings to Mesh button)")
    c:Hint("/nexus import \226\128\148 import ShadowNetwork settings & data ('dry' to preview)")
    c:Hint("/nexus import instances \226\128\148 import NovaInstanceTracker instance runs ('dry' to preview)")
    c:Hint("/nexus debug selftest \226\128\148 run the built-in self-tests and print pass or fail")
    c:Hint("/nexus debug <area> \226\128\148 diagnostics for one area: timers, mesh, instances, auras, hud, nwb, pulls, snbridge, sncapture, testalert")
    c:Hint("/nexus debug layout \226\128\148 development aid: writes a layout dump into SavedVariables. Reading it takes a tool that runs outside the game, so there is nothing to check in game.")
    c:Hint("/nexus help \226\128\148 print a short command list in chat. That chat list is shorter than this page \226\128\148 this page is the complete one.")

    local db = flow:AddSection("Dashboard")
    db:Hint("The dashboard is one panel screen. On the left is the character card list; on the right is the selected character's detail, with the Instances panel and the Timers dock beneath it.")
    db:Hint("Filter the cards with the 60s / Online / Summoners toggles above the list; click the active toggle again to clear it (with none active, all characters show). Summoners means warlocks below level 60. The Alliance / Horde toggle beside them switches faction.")
    db:Hint("Hover a card for a quick peek (location, missing buffs, last update); click it to open that character on the right.")
    db:Hint("The Instances panel has an Instances | Exp switch: Instances shows recent lockouts and the per-account cap meters; Exp shows each character's level, XP and rested. The character dropdown filters both.")
    db:Hint("The Timers dock (bottom-right) shows world-buff cooldowns, the Felwood songflower grid and the Darkmoon Faire estimate. The two small icons in its bottom-right corner are Broadcast (push your snapshot to the mesh, throttled to once a minute) and Refresh (pull fresh timer data).")
    db:Hint("Blacklisted characters appear struck-through on the dashboard (they are not hidden). Manage the list in Settings \226\134\146 Blacklist.")
    db:Hint("Cancel Buffs and Invite online are no longer dashboard header buttons. Reach them with /nexus x and /nexus invite, or from the minimap button's Shift + Right-click menu.")

    local mm = flow:AddSection("Minimap button")
    mm:Hint("Left-click \226\128\148 invite every online character on the mesh, then convert to raid and hand out assist, following your Auto-convert and Auto-assist settings.")
    mm:Hint("Shift + Left-click \226\128\148 invite everyone online without the raid convert or assist pass. Same as /nexus invite noconvert.")
    mm:Hint("Right-click \226\128\148 open or close the dashboard.")
    mm:Hint("Shift + Right-click \226\128\148 open the button menu: Toggle dashboard, Invite online, Timers dock, Cancel Buffs, Felwood map, Lock minimap button, Settings, Close.")
    mm:Hint("Alt + Left-click \226\128\148 disabled on purpose. A logout macro would make the button a protected frame, so this build refuses the click and prints a note in chat instead.")
    mm:Hint("Other mouse buttons \226\128\148 nothing is bound to them.")
    mm:Hint("Hover \226\128\148 the tooltip shows the live Rend, Ony (A) and Ony (H) states and keeps them counting while the cursor stays on the button.")
    mm:Hint("Drag \226\128\148 slide the button around the minimap ring to reposition it, unless it is locked. Lock or unlock it with \"Lock minimap button\" in Settings \226\134\146 General or in the Shift + Right-click menu; hide it entirely with \"Show minimap button\" in Settings \226\134\146 General.")

    local tr = flow:AddSection("Troubleshooting")
    tr:Hint("Other accounts not showing? The Channel AND Token must match byte-for-byte on every account \226\128\148 both are case sensitive and together act as your mesh password. Correct any mismatch in Settings \226\134\146 Mesh & Accounts, then /reload.")
    tr:Hint("Characters under the wrong account? Two accounts are sharing an Account ID. Give each account its own unique ID in Settings \226\134\146 Mesh & Accounts.")
    tr:Hint("Copying settings to a new account? Set it up with the same Channel + Token, then use Sync Settings to Mesh in Settings \226\134\146 Mesh & Accounts, or /nexus syncsettings (you confirm the target account IDs first).")
    tr:Hint("Coming from ShadowNetwork? Run /nexus import \226\128\148 it carries over your settings, Channel, Token and stored data. It only works while ShadowNetwork is still installed and loaded.")

    local ac = flow:AddSection("Accounts & Tombstones")
    ac:Hint("Deleting an account is local only \226\128\148 it hides that account on THIS client and leaves a 14-day tombstone that blocks it from re-appearing.")
    ac:Hint("Remove a tombstone early and the account re-adds itself on its next heartbeat (while it is still meshing).")
    ac:Hint("Changing your Account ID migrates your data locally; other accounts keep showing your OLD ID until they delete it.")
    ac:Hint("If two accounts use the same ID you'll see an \"Account ID conflict\" warning \226\128\148 change one of them to a unique ID.")
    ac:Hint("You can't delete your OWN account \226\128\148 change your Account ID instead.")

    local ds = flow:AddSection("First-time setup (detailed)")
    ds:Hint("1.  Account ID \226\128\148 In Settings \226\134\146 Mesh & Accounts, give this account a short unique ID (1\226\128\1512 digits). Every connected account needs a DIFFERENT ID; this is how the mesh tells your accounts apart.")
    ds:Hint("2.  Channel \226\128\148 On the same Mesh & Accounts page, set a Channel name of 16+ letters and numbers. It is case sensitive and must be identical on every account \226\128\148 think of it as the room your accounts meet in.")
    ds:Hint("3.  Token \226\128\148 Set a 6-character Token (letters/numbers), also identical everywhere. Generate the credentials on the Mesh & Accounts page, or paste a setup bundle to copy the same Channel and Token to another account. The Channel + Token together are your mesh password; anyone with both can see your roster, so keep them private.")
    ds:Hint("4.  Same faction \226\128\148 The mesh rides a hidden faction chat channel, so each account must log in a character on the SAME faction to connect. Cross-faction characters simply will not mesh.")
    ds:Hint("5.  Enable + relog \226\128\148 Enable the mesh, then log out and back in once on each account. Your characters appear across accounts within seconds.")
    ds:Hint("6.  Verify \226\128\148 Open the dashboard; you should see characters from your other accounts. Use the 60s / Online / Summoners filter toggles and the Alliance / Horde toggle to narrow the list, and click a character to open its detail pane, including its Note field. If not, check Troubleshooting above.")
end

----------------------------------------------------------------------
-- Section builders wrapper (guarded so a build error surfaces, not hides)
----------------------------------------------------------------------

local built = {}
local function once(page, pane, buildFn)
    if built[page] then return end
    built[page] = true
    if page == "mesh" then Options._meshPane = pane; ensureLiveTicker() end
    ns:SafeCall(buildFn)
end

----------------------------------------------------------------------
-- Registration with the Daseeki hub (flow = true)
----------------------------------------------------------------------

function Options.Register()
    if not _G.DaseekiSuite then return end
    if not (_G.DaseekiUI and _G.DaseekiUI.Token) then
        print("|cff4fc3f7Daseeki Nexus|r requires Daseeki Core — please update Daseeki Core.")
        return
    end
    DaseekiSuite:RegisterAddon({
        id    = "nexus",
        title = "Nexus",
        icon  = "Interface\\Icons\\INV_Misc_Net_01",
        order = 40,
        flow  = true,
        sections = {
            { id = "general",    title = "General",
              build = function(flow) once("general", flow.pane, function() buildGeneral(flow) end) end,
              refresh = function() refreshPage("general") end },
            { id = "mesh",       title = "Mesh & Accounts",
              build = function(flow) once("mesh", flow.pane, function() buildMesh(flow) end) end,
              refresh = function() refreshPage("mesh") end },
            { id = "auras",      title = "Auras",
              build = function(flow) once("auras", flow.pane, function() buildAuras(flow) end) end,
              refresh = function() refreshPage("auras") end },
            { id = "automation", title = "Automation",
              build = function(flow) once("automation", flow.pane, function() buildAutomation(flow) end) end,
              refresh = function() refreshPage("automation") end },
            { id = "timers",     title = "Timers",
              build = function(flow) once("timers", flow.pane, function() buildTimers(flow) end) end,
              refresh = function() refreshPage("timers") end },
            { id = "instances",  title = "Instances",
              build = function(flow) once("instances", flow.pane, function() buildInstances(flow) end) end,
              refresh = function() refreshPage("instances") end },
            { id = "alerts",     title = "Alerts",
              build = function(flow) once("alerts", flow.pane, function() buildAlerts(flow) end) end,
              refresh = function() refreshPage("alerts") end },
            { id = "blacklist",  title = "Blacklist",
              build = function(flow) once("blacklist", flow.pane, function() buildBlacklist(flow) end) end,
              refresh = function() refreshPage("blacklist") end },
            -- Round-13: Help moved out of the dashboard into the hub (single-page dashboard).
            { id = "help",       title = "Help",
              build = function(flow) once("help", flow.pane, function() buildHelp(flow) end) end,
              refresh = function() refreshPage("help") end },
        },
    })
end

----------------------------------------------------------------------
-- Self-tests — edit-focus guard (pure; no frames, no SavedVariables)
--
-- The guard is the only logic in this file that can silently eat owner input, so
-- it is pinned headlessly: a table with a stubbed HasFocus() is all guardEdit /
-- isEditing / forceRepaint ever touch.
----------------------------------------------------------------------
ns:RegisterSelfTest("options", function(verbose)
    local pass = true
    local function ck(c, m) if not c then pass = false; if verbose then ns:Print("  FAIL options/" .. m) end end end

    -- Minimal EditBox stand-in (host frame + .editBox, like DaseekiUI's builder).
    local function fakeBox(stored)
        local eb = { text = "", focus = false, _scripts = {} }
        function eb:HasFocus()      return self.focus end
        function eb:SetText(t)      self.text = t end
        function eb:GetText()       return self.text end
        function eb:ClearFocus()    self.focus = false end
        function eb:GetScript(n)    return self._scripts[n] end
        local host = { editBox = eb }
        host.Refresh = function() eb:SetText(stored()) end
        return host, eb
    end

    local value = "SECRET"
    local host, eb = fakeBox(function() return value end)
    guardEdit(host)

    host.Refresh()
    ck(eb.text == "SECRET", "unfocused refresh paints the stored value")

    -- Typing: focus + local edits, then live-ticker refreshes must not touch it.
    eb.focus = true
    eb:SetText("MyTwentyCharChannel!")
    host.Refresh()
    ck(eb.text == "MyTwentyCharChannel!", "focused refresh leaves typed text alone")
    for _ = 1, 6 do host.Refresh() end          -- >4s of 2s ticks
    ck(eb.text == "MyTwentyCharChannel!", "repeated ticks still leave it alone")

    -- Focus lost without committing: no sticky state, next refresh paints normally.
    eb.focus = false
    host.Refresh()
    ck(eb.text == "SECRET", "focus lost -> next refresh repaints stored value")

    -- Guarding twice must not double-wrap or wedge the field.
    guardEdit(host); host.Refresh()
    ck(eb.text == "SECRET" and host._focusGuarded == true, "guardEdit is idempotent")

    -- RefreshForce is the deliberate escape hatch and ignores focus.
    eb.focus = true; eb:SetText("typed")
    host.RefreshForce()
    ck(eb.text == "SECRET", "RefreshForce repaints even while focused")

    -- forceRepaint() commits through the box's own Enter handler, then repaints.
    eb._scripts.OnEnterPressed = function(self) value = self:GetText(); self:ClearFocus() end
    eb.focus = true; eb:SetText("Committed")
    forceRepaint(host)
    ck(value == "Committed" and eb.text == "Committed" and eb.focus == false,
       "forceRepaint commits typing before repainting")

    -- forceRepaint(w, false) is the Reset path: discard, do not save.
    eb.focus = true; eb:SetText("Discarded")
    forceRepaint(host, false)
    ck(value == "Committed" and eb.text == "Committed" and eb.focus == false,
       "forceRepaint(w, false) discards typing")

    -- Non-editbox widgets share the refresher lists; they must never look "edited".
    ck(isEditing(nil) == false and isEditing({}) == false and isEditing({ _label = {} }) == false,
       "isEditing is false for labels / checkboxes / nil")

    -- Raw EditBoxes (the coordinate-row cells) work without a host wrapper.
    local _, raw = fakeBox(function() return "" end)
    raw.focus = true;  ck(isEditing(raw) == true,  "raw editbox recognised while focused")
    raw.focus = false; ck(isEditing(raw) == false, "raw editbox recognised while idle")

    -- The 2s ticker repaints the live subset, which must exist and stay a strict
    -- subset of the Mesh page's refreshers.
    ck(type(refreshers.meshLive) == "table", "meshLive registry exists")
    ck(#refreshers.meshLive <= #refreshers.mesh, "meshLive is a subset of mesh")

    ----------------------------------------------------------------------
    -- Class-rule KEY PARITY (owner bug: Slip'kik's Savvy stayed amber).
    --
    -- The write side (this page's CLASS_RULE_GRIDS[].optKey -> auraOpts[optKey])
    -- and the read side (ui_shell AURA_META[].thresholdKey filtered through
    -- Dashboard.CLASS_RULED_KEYS) are two hand-maintained string tables in two
    -- files. Both are raw table indexes, so a case slip — "dmtsp" for "dmtSP",
    -- and slot 8's AURA_META.key really IS the lowercase "dmtsp" sitting one
    -- field away — writes a map nothing reads. The click "takes", the pill turns
    -- green, and the rule silently never fires. Asserted BOTH ways so neither
    -- side can grow a fourth class-ruled buff alone.
    ----------------------------------------------------------------------
    local D = ns.Dashboard
    local grids = Options.CLASS_RULE_GRIDS
    ck(type(grids) == "table" and #grids > 0, "CLASS_RULE_GRIDS roster exists")
    ck(type(D) == "table" and type(D.CLASS_RULED_KEYS) == "table",
       "ui_shell exports Dashboard.CLASS_RULED_KEYS")

    if type(grids) == "table" and type(D) == "table" and type(D.CLASS_RULED_KEYS) == "table" then
        local writeKeys = {}
        for _, g in ipairs(grids) do
            ck(type(g.optKey) == "string" and g.optKey ~= "", "grid optKey is a non-empty string")
            ck(type(g.classes) == "table" and #g.classes > 0,
               ("grid %s has a class list"):format(tostring(g.optKey)))
            writeKeys[g.optKey] = true
        end
        -- Every key this page WRITES must be one the display READS ...
        for k in pairs(writeKeys) do
            ck(D.CLASS_RULED_KEYS[k] == true,
               ("options write-key %q is class-ruled on the display side"):format(k))
        end
        -- ... and every key the display class-rules must have a grid to set it.
        for k in pairs(D.CLASS_RULED_KEYS) do
            ck(writeKeys[k] == true,
               ("display class-ruled key %q has an Auras-page grid"):format(k))
        end
        -- And each one must be a real threshold-bearing slot, spelled identically.
        if type(D.AURA_META) == "table" then
            local metaKeys = {}
            for _, meta in pairs(D.AURA_META) do
                if type(meta.thresholdKey) == "string" then metaKeys[meta.thresholdKey] = true end
            end
            for k in pairs(writeKeys) do
                ck(metaKeys[k] == true,
                   ("write-key %q matches an AURA_META thresholdKey verbatim"):format(k))
            end
        end
    end

    ----------------------------------------------------------------------
    -- Faction scope defaults to the PLAYER'S OWN faction (the trap that made
    -- the owner's Slip'kik/Shaman tick land in the Alliance table while every
    -- Horde card read the untouched Horde one). The harness stubs
    -- UnitFactionGroup -> "Horde", so the pre-fix behaviour ("Alliance") is a
    -- hard failure here.
    ----------------------------------------------------------------------
    local realUFG = UnitFactionGroup
    local function withFaction(f, fn)
        _G.UnitFactionGroup = function() return f end
        SetScopeFaction(nil)                    -- clear the cache; force re-resolve
        fn()
    end

    withFaction("Horde", function()
        ck(ScopeFaction() == "Horde", "scope opens on the player's own faction (Horde)")
        -- The write target follows the scope: this is the bug, stated directly.
        local fs = FS()
        local hordeFS = ns.Store and ns.Store.GetFactionSettings
                        and ns.Store.GetFactionSettings("Horde")
        ck(fs ~= nil and fs == hordeFS,
           "class-rule writes land in the OWN-faction settings table")
    end)
    withFaction("Alliance", function()
        ck(ScopeFaction() == "Alliance", "an Alliance player opens on Alliance")
    end)
    -- Unresolvable faction (pre-login): fall back, but do NOT cache the fallback,
    -- or one early call would pin the wrong faction for the whole session.
    withFaction(nil, function()
        ck(ScopeFaction() == "Alliance", "unresolvable faction falls back to Alliance")
        _G.UnitFactionGroup = function() return "Horde" end
        ck(ScopeFaction() == "Horde", "the fallback is not cached -- next call self-heals")
    end)
    -- An explicit toggle still wins over the default, and junk resets to default.
    withFaction("Horde", function()
        SetScopeFaction("Alliance")
        ck(ScopeFaction() == "Alliance", "explicit faction toggle overrides the default")
        SetScopeFaction("Neutral")
        ck(ScopeFaction() == "Horde", "a bogus scope value resets to the own-faction default")
    end)

    -- End-to-end, the owner's exact click: tick Shaman = required on the Auras
    -- page while scoped to Horde, then read it back the way a card does.
    withFaction("Horde", function()
        local fs = FS()
        if fs and fs.auraOpts and fs.auraOpts.dmtSP and D and D.AuraRequirement then
            local o = fs.auraOpts.dmtSP
            local pReq, pOpt, pIgn = o.required.SHAMAN, o.optional.SHAMAN, o.ignored.SHAMAN
            o.required.SHAMAN, o.optional.SHAMAN, o.ignored.SHAMAN = true, nil, nil
            local appl, req = D.AuraRequirement(8, { classTag = "SHAMAN" }, "Horde")
            ck(appl == true and req == "required",
               "Slip'kik required-for-Shaman on Horde reads back as required (red)")
            o.required.SHAMAN, o.optional.SHAMAN, o.ignored.SHAMAN = pReq, pOpt, pIgn
        end
    end)

    _G.UnitFactionGroup = realUFG
    SetScopeFaction(nil)                        -- leave the live session unpinned

    if verbose and pass then ns:Print("  PASS options/editbox-focus-guard") end
    return pass
end)

-- Register once Core + Store are both ready.
ns:On("STORE_READY", function()
    ns:SafeCall(Options.Register)
end)
