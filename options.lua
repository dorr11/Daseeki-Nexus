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
-- Section map (spec's 9 sub-tabs → 7 scannable pages, style-guide consolidation).
-- SETTINGS REWORK (owner, six directives) reshaped four of these:
--   General          = General + Data Management. The custom-LOCATIONS editor and
--                      the class-COLORS editor are both retired (item 1): the
--                      records are tombstoned by a one-time store migration and
--                      the palette is fixed, so there is nothing left to edit.
--   Setup            = was "Mesh & Accounts" (item 2). The Mesh section is now
--                      "Setup" and the three identity fields (Account / Channel /
--                      Token) sit on ONE three-column row, label over input.
--                      The Tombstones table is gone from the UI (item 3) — the
--                      tombstone MECHANISM is untouched and still backs mesh
--                      deletes and the location retirement above.
--   Buffs            = was "Auras" (item 4). Duration thresholds are gone; buff
--                      time colour is a fixed backend rule. The class-rule grids
--                      run Battle Shout → Rend → Slip'kik → Fengus (item 5) and
--                      write ONE global table with no faction toggle (item 6).
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

-- (AURA_DEFS — the nine-row editable duration-threshold table — is RETIRED.
-- SETTINGS-REWORK ITEM 4: buff-time colour is a fixed backend rule keyed off each
-- buff's full duration (2h -> yellow under 90m · 1h -> under 55m · the 15-minute
-- NPC Battle Shout -> under 12m), stated once in ui_shell.lua's
-- Dashboard.BUFF_TIME_RULE and not user-editable. The nine normal/minimum pairs
-- they used to edit are parked + cleared by Store.RetireAuraThresholds.)

-- The full ten summon-trigger buffs (round-3 item 23). Rendered as "ABBR - Full
-- Name" rows with spell icons. FFF is the seasonal buff (no stable spellID here —
-- cosmetic question-mark fallback).
--
-- KEY NAMESPACE — DO NOT "TIDY" THESE INTO THE AURA KEYS. The auto-summon
-- trigger keys are the ones auto.lua's Auto.SUMMON_TRIGGER_BUFFS defines, and
-- they are named after the BUFF, not its source. They are deliberately NOT the
-- aura keys used by Store.AURA_THRESHOLD_SEEDS / Store.CLASS_RULE_SEEDS:
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
-- Fengus' Ferocity / DMT AP — the melee attack-power tribute buff, and the
-- mirror image of Slip'kik. Same all-9 roster; defaults live in store.lua
-- (Store.CLASS_RULE_SEEDS.dmtAP: the six weapon classes required, Mage/Priest/
-- Warlock ignored). Owner report: a mage was showing a red "Missing Fengus'
-- Ferocity" because a threshold-bearing slot with no class rule is
-- required-for-everyone.
local FENGUS_CLASSES  = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }

-- THE class-rule grid roster: one row per class-ruled buff the Buffs page draws.
-- `optKey` is the EXACT, CASE-SENSITIVE key this page writes into the ONE GLOBAL
-- rule table (Store.GetAuraRules — settings-rework item 6; it used to be the
-- per-faction GetFactionSettings().auraOpts), and it must be byte-identical to
-- the matching AURA_META[slot].thresholdKey that ui_shell reads back through
-- Dashboard.CLASS_RULED_KEYS / Dashboard.ClassRuleState. A case slip ("dmtsp"
-- for "dmtSP") writes a map nothing ever reads: the owner's click appears to
-- take, and the rule can never fire. buildBuffs loops this table and the
-- "options" suite asserts it against the display side both ways, so a fifth
-- class-ruled buff cannot be added on one side only.
--
-- SETTINGS-REWORK ITEM 5 — the ORDER here is the owner's, and it is pinned by
-- the "options" suite against Store.AURA_RULE_KEYS so the two cannot drift:
--     Battle Shout · Rend · Slip'kik (dmtSP) · Fengus (dmtAP)
local CLASS_RULE_GRIDS = {
    { optKey = "battleShout", classes = BS_CLASSES,
      title = "Battle Shout — Required Classes" },
    { optKey = "rend",        classes = REND_CLASSES,
      title = "Rend — Required Classes" },
    -- Slip'kik's Savvy (DMT SP): physical damage users typically don't want it,
    -- so it ships ignored for War/Rogue/Hunter and optional for casters.
    { optKey = "dmtSP",       classes = SLIPKIK_CLASSES,
      title = "Slip'kik's Savvy (DMT SP) — Required Classes" },
    -- Fengus' Ferocity (DMT AP): the mirror of the row above — magic damage
    -- dealers don't want attack power, so it ships required for the six weapon
    -- classes and ignored for Mage/Priest/Warlock.
    { optKey = "dmtAP",       classes = FENGUS_CLASSES,
      title = "Fengus' Ferocity (DMT AP) — Required Classes" },
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

-- AUTO-REPAIR LABEL — say what it does (1.1.4 honesty fix).
--
-- This checkbox used to read "Auto-repair at Rin'wosho" while auto.lua repaired
-- on ANY merchant window the player opened, anywhere in the world. The
-- behaviour is owner-approved (waiver 2026-08-05, "im fine with auto repairing
-- at any vendor"); the LABEL was the defect — a setting that misdescribes its
-- own blast radius is worse than no setting, because the owner ticks it
-- believing it is scoped to one NPC in Yojamba Isle.
--
-- Exported so the options self-test can assert the text: an assertion on a
-- string buried in a UI builder closure is not reachable, and this label going
-- stale again is precisely the kind of drift the conformance audit found.
Options.REPAIR_LABEL = "Auto-repair at vendors"
Options.REPAIR_HINT  =
    "Auto-repair runs at |cffffd100any|r vendor whose window you open, not just Rin'wosho. "
    .. "It spends your own gold and prints the cost."

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

-- SETTINGS-REWORK ITEM 6 — the ONE global class-rule table. Every grid on the
-- Buffs page reads and writes through here; there is no faction in the path any
-- more, so a tick can no longer land in the faction the owner does not play.
local function RULES() return ns.Store and ns.Store.GetAuraRules and ns.Store.GetAuraRules() or nil end

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
-- (sanitizeHex retired with the class-color editor — settings-rework item 1.
-- It existed only to clean up hex typed into those nine fields.)

-- Class color r,g,b.
--
-- SETTINGS-REWORK ITEM 1: the "Colors" section is gone and the palette is not
-- user-editable, so this delegates to the ONE suite-wide resolver
-- (Dashboard.ClassColor -> Store.DEFAULT_CLASS_COLORS). It used to carry its own
-- copy of the override lookup, which is exactly how a settings page and the
-- dashboard end up painting the same character two different colours. The local
-- fallbacks below only matter if ui_shell has not loaded yet.
local function classColor(class)
    local D = ns.Dashboard
    if D and D.ClassColor then
        local r, g, b = D.ClassColor(class)
        if r then return r, g, b end
    end
    local palette = ns.Store and ns.Store.DEFAULT_CLASS_COLORS
    local hex = type(palette) == "table" and palette[class]
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
local buildClassRuleGrid
local buildAccountsTable

----------------------------------------------------------------------
-- 1. GENERAL  (General + Data Management)
--
-- SETTINGS-REWORK ITEM 1 removed two whole sections from this page:
--   * "Locations" — the numbered coordinate-override table with its Add
--     Location / Here / Del / Reset controls. The records themselves are
--     tombstoned and cleared by Store.RetireLocations; the zone-override MATCHER
--     in tracker.lua stays and simply reads an empty list.
--   * "Colors"    — the nine class-color hex fields. The palette is fixed now
--     (Store.DEFAULT_CLASS_COLORS) and the stored overrides are parked +
--     cleared by Store.RetireClassColors.
----------------------------------------------------------------------

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
    -- 1.0.2: this used to CALL SetEveryoneIsAssistant, which is a protected
    -- function — the client blocked it and no addon can ever do it. The stored
    -- key is unchanged (SavedVariables compatibility); what it now buys you is a
    -- one-line reminder when Nexus finishes assembling YOUR raid.
    register("general", r2:Checkbox({
        label = "Remind me to set All Assist",
        get = function() local db = DB(); return db and db.autoAssistAll end,
        set = function(v) local db = DB(); if db then db.autoAssistAll = v and true or false end end,
    }).Refresh)

    -- Inventory module (inventory.lua). DEFAULT ON — and an ABSENT key also
    -- reads as ON, so this checkbox shows ticked on a SavedVariables file
    -- written before the module existed. Turning it off makes the module fully
    -- inert (no scanning, no publishing, timers and ticker stopped), which is
    -- why `set` routes through Inventory.SetEnabled rather than writing the key
    -- directly. Reads fall back to the raw key so the row still renders if
    -- inventory.lua somehow failed to load.
    local r3 = sec:AddRow({ vAlign = "center" })
    register("general", r3:Checkbox({
        label = "Cross-account inventory & gold",
        tooltip = "Track item counts and gold for every character on every account "
               .. "in your mesh. Off makes the module inert; stored data is kept.",
        get = function()
            local I = ns.Inventory
            if I and I.IsEnabled then return I.IsEnabled() end
            local db = DB()
            return not db or db.inventoryEnabled ~= false
        end,
        set = function(v)
            local I = ns.Inventory
            if I and I.SetEnabled then I.SetEnabled(v and true or false); return end
            local db = DB()
            if db then db.inventoryEnabled = v and true or false end
        end,
    }).Refresh)

    -- Cross-account wealth TOOLTIPS (tooltips.lua). DEFAULT ON, absent key reads ON
    -- (Tooltips.IsEnabled owns that rule). The row is indented under the inventory
    -- checkbox because it is a display surface for that module's data, and it is
    -- INERT while Daseeki Bags is installed — Bags renders these tooltips itself, so
    -- Nexus stands down to keep every hover from carrying the block twice. The note
    -- row below says so in words rather than leaving a ticked box that does nothing.
    local r3b = sec:AddRow({ vAlign = "center" })
    r3b._indent = r3b._indent + 20
    register("general", r3b:Checkbox({
        label = "Cross-account tooltips",
        tooltip = "Show cross-character item counts on item tooltips and a gold "
               .. "breakdown on the money frame, for the default Blizzard bags. "
               .. "Inactive while Daseeki Bags is installed (Bags draws its own).",
        get = function()
            local T = ns.Tooltips
            if T and T.IsEnabled then return T.IsEnabled() end
            local db = DB()
            return not db or db.wealthTooltips ~= false
        end,
        set = function(v)
            local db = DB()
            if db then db.wealthTooltips = v and true or false end
            local T = ns.Tooltips
            if T and T.Invalidate then T.Invalidate() end
        end,
    }).Refresh)

    local tipStatusRow = sec:AddRow()
    tipStatusRow._indent = tipStatusRow._indent + 20
    local tipStatus = tipStatusRow:Label("")
    register("general", function()
        local T = ns.Tooltips
        if not (T and T.Status) then
            tipStatus._label:SetText("")
            return
        end
        local active, why = T.Status()
        if active then
            tipStatus._label:SetText("|cff66dd66Cross-account tooltips are live on item and money tooltips.|r")
        else
            tipStatus._label:SetText("|cffddaa44Inactive — " .. tostring(why) .. ".|r")
        end
    end)

    -- Mesh auto-friend (friends.lua). DEFAULT ON, and an ABSENT key reads as ON
    -- too, so this box shows ticked on a SavedVariables file written before the
    -- module existed. Turning it off stops future passes ONLY: no friend is ever
    -- removed, and the never-re-add ledger is untouched, so re-enabling resumes
    -- where it stopped. Reads fall back to the raw key so the row still renders
    -- if friends.lua somehow failed to load.
    local r4 = sec:AddRow({ vAlign = "center" })
    register("general", r4:Checkbox({
        label = "Automatically friend your other accounts' characters",
        tooltip = "Add every mesh character on your OTHER accounts (same faction, "
               .. "same realm) to this character's friends list, so mail and "
               .. "whispers never need a confirmation. Never removes a friend, and "
               .. "never re-adds one you have removed yourself.",
        get = function()
            local F = ns.MeshFriends
            if F and F.IsEnabled then return F.IsEnabled() end
            local db = DB()
            return not db or db.autoFriendMesh ~= false
        end,
        set = function(v)
            local F = ns.MeshFriends
            if F and F.SetEnabled then F.SetEnabled(v and true or false)
            else
                local db = DB()
                if db then db.autoFriendMesh = v and true or false end
            end
            -- Switching it ON mid-session should not wait for the next login,
            -- but it still may not run against an unconfirmed friends list —
            -- SchedulePass -> RunPass enforces that itself.
            if v and F and F.SchedulePass then F.SchedulePass(1) end
        end,
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
                    -- SETTINGS-REWORK ITEM 1: the manual-location override is
                    -- retired (tombstoned + cleared), so "usable location" is now
                    -- exactly "the tracker captured one".
                    local loc = rec.location
                    if not loc or loc == "" then missing = missing + 1 end
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
    dm:Hint("Local operation — excludes Paladin/Shaman gossip rows and the Auto-Invite Whitelist.")
    local dmRow = dm:AddRow()
    dmRow:Button({ text = "Export Settings", width = 140, onClick = function()
        local db = DB(); if not db then return end
        -- SETTINGS-REWORK: class colors and coordinate overrides are retired, so
        -- they are no longer exported (an export carrying them would be a way to
        -- re-import the very records the migration just tombstoned). The global
        -- class-rule table takes their place — it IS the buff configuration now.
        local blob = { auraRules = db.auraRules,
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
                text = "Overwrite buff class rules, faction settings and timer settings with the imported values?",
                acceptText = "Import", danger = true,
                onAccept = function()
                    -- Deliberately NOT restored: classColors / coordinateOverrides.
                    -- An older export still carries them; accepting those keys
                    -- would resurrect retired records from a file the tombstone
                    -- ledger never sees. They are dropped, silently and on purpose.
                    if blob.auraRules then db.auraRules = blob.auraRules end
                    if blob.factionSettings then db.factionSettings = blob.factionSettings end
                    if blob.timerSettings then db.timerSettings = blob.timerSettings end
                    -- An imported settings blob predates the merge on the SENDING
                    -- side too, so re-run the additive back-fill: a rule key the
                    -- import did not carry must not come back as a nil map.
                    if ns.Store and ns.Store.SeedAuraRules then ns.Store.SeedAuraRules(db) end
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
    dm:Hint("Cross-faction copy covers AUTOMATION only. Buff class rules are global now — one set for both factions — so there is nothing to copy there. Paladin/Shaman gossip rows and the invite whitelist are preserved on the target.")

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

    -- (The "Locations" and "Colors" sections used to sit here — settings-rework
    -- item 1 retired both. Nothing replaces them: locations are tombstoned and
    -- the class palette is fixed.)
end

-- Copy one faction's automation block to the other, excluding the spec's
-- non-copyable fields (Paladin/Shaman gossip rows, whitelist).
--
-- SETTINGS-REWORK ITEM 6: this no longer copies the class-rule maps. It cannot —
-- there is only ONE set of them now, shared by both factions, so "copy Alliance's
-- rend rule to Horde" is a no-op by construction. Copying the (parked, unread)
-- per-faction auraOpts would be worse than a no-op: it would look like it did
-- something while the display kept reading the global table.
-- THE COPY ITSELF, pure over two settings blocks — no frames, no SavedVariables,
-- no confirmation dialog. It lives outside the onAccept closure so the
-- preservation rules below can be asserted headlessly; the closure could not be
-- reached by any test, which is exactly how two of them went missing.
--
-- PRESERVED ON THE DESTINATION (spec §12.3, audit divergence 10 / rows 34-36):
--   * autoGroup.whitelist         — the list itself (was already preserved),
--   * autoGroup.whitelistEnabled  — its master gate. Copying it silently
--     re-enables, or disables, a whitelist the destination had deliberately set
--     the other way.
--   * autoGroup.defaultsApplied   — the STICKY one-time seeding guard. Reset it
--     and the next login re-seeds a list the user had cleared.
--   * autoSummon.defaultsApplied  — the same guard for the seven trigger seeds:
--     clearing it lets a later login resurrect triggers the destination had
--     unticked. (Not named in the audit; same class of bug, same one-line fix.)
--   * autoGossip.dmf.buffType.PALADIN / .SHAMAN — faction-exclusive classes.
-- All of these describe the DESTINATION's own history or its faction-exclusive
-- rows. "Copy this faction's automation settings" does not reach them, and a
-- guard flag is not a setting.
--
-- auraOpts is NOT copied at all (see the header).
function Options.ApplyFactionCopy(src, dst)
    if type(src) ~= "table" or type(dst) ~= "table" then return false end
    local function clone(t)
        if type(t) ~= "table" then return t end
        local o = {}; for k, v in pairs(t) do o[k] = clone(v) end; return o
    end

    if type(dst.autoGroup) == "table" then
        local keepWL       = dst.autoGroup.whitelist
        local keepWLOn     = dst.autoGroup.whitelistEnabled
        local keepWLSeeded = dst.autoGroup.defaultsApplied
        dst.autoGroup = clone(src.autoGroup)
        dst.autoGroup.whitelist        = keepWL
        dst.autoGroup.whitelistEnabled = keepWLOn
        dst.autoGroup.defaultsApplied  = keepWLSeeded
    end

    if type(dst.autoSummon) == "table" then
        local keepSummonSeeded = dst.autoSummon.defaultsApplied
        dst.autoSummon = clone(src.autoSummon)
        dst.autoSummon.defaultsApplied = keepSummonSeeded
        -- A copy IS an expressed choice about the taxi/PvP rule, so the copied
        -- value must not be healed away by MigrateTaxiPvpDefault next login.
        dst.autoSummon.dropOnTaxiPvpChosen = true
    end

    if type(dst.autoGossip) == "table" then
        local bt = dst.autoGossip.dmf and dst.autoGossip.dmf.buffType or {}
        local keepPal, keepSha = bt.PALADIN, bt.SHAMAN
        dst.autoGossip = clone(src.autoGossip)
        if type(dst.autoGossip) == "table" and type(dst.autoGossip.dmf) == "table"
           and type(dst.autoGossip.dmf.buffType) == "table" then
            dst.autoGossip.dmf.buffType.PALADIN = keepPal
            dst.autoGossip.dmf.buffType.SHAMAN  = keepSha
        end
    end

    dst.autoQuest = clone(src.autoQuest)
    return true
end

function Options.CopyFaction(from, to)
    local db = DB(); if not db then return end
    local src, dst = db.factionSettings[from], db.factionSettings[to]
    if not src or not dst then return end
    DaseekiUI.Confirm({
        title = "Copy " .. from .. " → " .. to,
        text = "Overwrite " .. to .. " AUTOMATION settings from " .. from ..
               "? (Buff class rules are global and unaffected; Paladin/Shaman gossip rows and the invite whitelist are preserved.)",
        acceptText = "Copy", danger = true,
        onAccept = function()
            Options.ApplyFactionCopy(src, dst)
            ns:Print(from .. " → " .. to .. " automation copied.")
            refreshPage("general")
        end,
    })
end


----------------------------------------------------------------------
-- 2. SETUP  (was "Mesh & Accounts" — settings-rework item 2)
--
-- The page is "Setup" and its lead section is "Setup". The three fields that
-- actually constitute setting an account up — Account ID, Channel, Token — now
-- sit on ONE row as three columns, each with its label ABOVE its input, instead
-- of three stacked label-left rows with a hint under each. They are one decision
-- ("identify this account and point it at the mesh"), so they read as one block.
--
-- THE TYPING BUG THIS MUST NOT REGRESS: the Channel and Token boxes are MASKED,
-- and the Setup page runs a 2s live ticker. A repaint that SetText()s a box the
-- user is mid-word in wipes the input — and because the mask of a still-unsaved
-- value is the empty string, it read as the field "nulling itself out as you
-- type". Every paint below therefore goes through `isEditing()` first (the same
-- guard `guardEdit` installs on the flow-API widgets), the boxes are registered
-- on the NON-live "mesh" refresher list only, and the one path that must repaint
-- a focused box on purpose — the Show/Hide reveal — commits the keystrokes
-- through the box's own OnEnterPressed before painting (forceRepaint).
----------------------------------------------------------------------

-- Geometry for the three-column identity block.
local ID_LBL_H, ID_GAP, ID_BOX_H = 15, 3, 22
local ID_COL_GAP = 12          -- horizontal air between columns
local ID_EYE_W   = 48          -- Show/Hide button width (Channel + Token only)

local function buildMesh(flow)
    local UI = DaseekiUI
    local DS = _G.DaseekiSuite

    flow:AddSection("Setup")
    flow:Hint("Your accounts meet on a private hidden channel. Give this account its own ID, then set the SAME channel and token on every account and enable the mesh.")

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

    -- Validators, hoisted out of the field builders so the "Setup" column specs
    -- below stay declarative.
    local function validateChannel(v)
        if v == "" then return "" end
        if #v >= 16 and v:match("^%w+$") then return "|cff66dd66valid|r" end
        return "|cffddaa44needs 16+|r"
    end
    local function validateToken(v)
        if v == "" then return "" end
        if #v == 6 and v:match("^%w+$") then return "|cff66dd66valid|r" end
        return "|cffddaa44needs 6|r"
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

    ------------------------------------------------------------------
    -- THE IDENTITY ROW (settings-rework item 2): Account ID · Channel · Token,
    -- three equal columns, label over input, on one block.
    --
    -- Hand-built rather than composed from flow rows because the flow API lays
    -- items out LEFT-TO-RIGHT on a single baseline — it has no "stack a label
    -- above an input" primitive — and three of those stacks have to share one
    -- row's width and re-divide it when the pane resizes. Same construction the
    -- coordinate table used (raw EditBox + UI.Skin + pane:AddBlock with an
    -- arrange callback), so it inherits the panel's theming and width plumbing.
    ------------------------------------------------------------------
    local idCols = {
        {   key   = "account",
            label = "Account ID",
            masked = false,
            get   = function() return ns:GetAccountID() end,
            -- The Account ID is not a free-text field: SetAccountID validates and
            -- MIGRATES local data, so the status text is its answer, not ours.
            set   = function(self, v)
                v = tostring(v or ""):gsub("%s", "")
                local ok, err = ns:SetAccountID(v)
                self.status:SetText(ok and "|cff66dd66saved|r"
                                       or ("|cffdd6666" .. (err or "invalid") .. "|r"))
            end,
            statusOf = function() return "" end,   -- only speaks when you edit it
            maxLetters = 2,
            hint  = "1-2 digits, unique per account",
        },
        {   key   = "channel",
            label = "Channel",
            masked = true,
            raw   = chanRaw,
            get   = function(self)
                local t = chanRaw()
                if self.revealed then return t end
                return (t ~= "" and string.rep("*", #t)) or ""
            end,
            set   = function(self, v)
                v = tostring(v or ""):gsub("%s", "")
                if v:match("^%*+$") then return end   -- an edit to the MASK is not an edit
                local db = DB(); if db then db.mesh.channel = v end
                self.status:SetText(validateChannel(v))
            end,
            statusOf = function() return validateChannel(chanRaw()) end,
            maxLetters = 0,
            hint  = "16+ alphanumeric, case sensitive",
        },
        {   key   = "token",
            label = "Token",
            masked = true,
            raw   = tokRaw,
            get   = function(self)
                local t = tokRaw()
                if self.revealed then return t end
                return (t ~= "" and string.rep("*", #t)) or ""
            end,
            set   = function(self, v)
                v = tostring(v or ""):gsub("%s", "")
                if v:match("^%*+$") then return end
                local db = DB(); if db then db.mesh.token = v end
                self.status:SetText(validateToken(v))
            end,
            statusOf = function() return validateToken(tokRaw()) end,
            maxLetters = 6,
            hint  = "exactly 6 alphanumeric",
        },
    }

    do
        local host = CreateFrame("Frame", nil, flow.pane.child)
        local ROW_H = ID_LBL_H + ID_GAP + ID_BOX_H

        for _, col in ipairs(idCols) do
            col.revealed = false

            col.lbl = host:CreateFontString(nil, "OVERLAY")
            col.lbl:SetFontObject(UI.fonts.small)
            col.lbl:SetJustifyH("LEFT")
            col.lbl:SetText(col.label)

            col.status = host:CreateFontString(nil, "OVERLAY")
            col.status:SetFontObject(UI.fonts.small)
            col.status:SetJustifyH("RIGHT")
            col.status:SetText("")

            local box = CreateFrame("EditBox", nil, host, "BackdropTemplate")
            box:SetHeight(ID_BOX_H)
            box:SetAutoFocus(false)
            box:SetFontObject(UI.fonts.body)
            box:SetTextInsets(6, 6, 0, 0)
            if col.maxLetters and col.maxLetters > 0 then box:SetMaxLetters(col.maxLetters) end
            col.box = box

            -- The focus-safe paint. THIS is the anti-regression guard: a repaint
            -- never SetText()s a box that currently owns keyboard focus, so the
            -- masked Channel/Token fields cannot empty themselves mid-word.
            local function paint()
                if not isEditing(box) then box:SetText(col.get(col) or "") end
            end
            box.Refresh = function()
                paint()
                col.status:SetText(col.statusOf(col) or "")
            end
            guardEdit(box)   -- installs RefreshForce + the focus wrapper

            box:SetScript("OnEnterPressed", function(self) col.set(col, self:GetText()); self:ClearFocus() end)
            box:SetScript("OnEditFocusLost", function(self) col.set(col, self:GetText()); paint() end)
            box:SetScript("OnEscapePressed", function(self) self:ClearFocus(); paint() end)

            if col.masked then
                col.eyeBtn = UI.MakeButton(host, { text = "Show", width = ID_EYE_W,
                                                   height = ID_BOX_H, variant = "quiet" })
                col.eyeBtn:SetScript("OnClick", function(self)
                    col.revealed = not col.revealed
                    if self._label then self._label:SetText(col.revealed and "Hide" or "Show") end
                    -- Reveal must repaint even while focused, so commit the
                    -- keystrokes through the box's own Enter handler FIRST —
                    -- toggling mid-word saves what you typed instead of eating it.
                    forceRepaint(box)
                end)
            end

            UI.Skin(box, function(self)
                self:SetBackdrop(UI.FLAT_BACKDROP)
                self:SetBackdropColor(UI.Color("inset"))
                self:SetBackdropBorderColor(UI.Color("controlBorder"))
            end)
            register("mesh", box.Refresh)   -- "mesh", NOT "meshLive": the 2s ticker
                                            -- must never come near these fields
        end

        UI.Skin(host, function()
            for _, col in ipairs(idCols) do
                col.lbl:SetTextColor(UI.Color("muted"))
                col.status:SetTextColor(UI.Color("muted"))
            end
        end)

        host.arrange = function(width)
            host:SetWidth(width); host:SetHeight(ROW_H)
            local colW = math.max(60, math.floor((width - ID_COL_GAP * 2) / 3))
            for i, col in ipairs(idCols) do
                local x = (i - 1) * (colW + ID_COL_GAP)
                col.lbl:ClearAllPoints()
                col.lbl:SetPoint("TOPLEFT", host, "TOPLEFT", x, 0)
                col.status:ClearAllPoints()
                col.status:SetPoint("TOPRIGHT", host, "TOPLEFT", x + colW, 0)
                col.status:SetWidth(math.max(10, colW - 80))

                local boxW = colW - (col.masked and (ID_EYE_W + 4) or 0)
                col.box:ClearAllPoints()
                col.box:SetPoint("TOPLEFT", host, "TOPLEFT", x, -(ID_LBL_H + ID_GAP))
                col.box:SetWidth(math.max(30, boxW))
                if col.eyeBtn then
                    col.eyeBtn:ClearAllPoints()
                    col.eyeBtn:SetPoint("TOPLEFT", host, "TOPLEFT", x + boxW + 4, -(ID_LBL_H + ID_GAP))
                end
            end
            return ROW_H
        end

        flow.pane:AddBlock(host, host.arrange, 8, 0)
        for _, col in ipairs(idCols) do if col.box.Refresh then col.box.Refresh() end end
        Options._identityCols = idCols   -- self-test / diagnostic handle
    end

    -- ONE hint under the whole block instead of three stacked ones (the fields
    -- are now side by side, so their rules read best side by side too).
    flow:Hint("Account ID: 1-2 digits, DIFFERENT on every account.  ·  Channel: 16+ letters/numbers, case sensitive.  ·  Token: exactly 6 letters/numbers.  Channel and Token must be IDENTICAL on every account.")

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

    ------------------------------------------------------------------
    -- THE PREFERENCE ROW (owner layout pass): Suppress alert · Auto-leave ·
    -- Hard-throttle, all three on ONE row. They previously sat on two rows —
    -- Suppress alone, then Auto-leave + Hard-throttle — which read as a ragged
    -- orphan above a pair.
    --
    -- Hand-arranged rather than a plain flow row for the same reason the identity
    -- block above is: the flow row packs items left-to-right at a fixed 8px gap,
    -- so three toggles bunch against the left edge and leave a dead third of the
    -- row. This block divides the row's width itself and re-divides it on every
    -- layout pass.
    --
    -- RHYTHM: the Account / Channel / Token block above is three equal columns
    -- separated by ID_COL_GAP, so these boxes take the SAME column stops whenever
    -- every label fits its column — the two blocks then line up vertically.
    -- FALLBACK: these labels are uneven (24–33 chars) and MakeCheckbox gives the
    -- label FontString width 0 (auto-size, never truncates), so a label that
    -- outgrows its column would run UNDER the next checkbox rather than clip.
    -- That is reachable — fontScale goes to 1.3 and the font picker can hand us a
    -- wide face — so when any label does not fit, the block switches to a
    -- justified layout: intrinsic widths, leftover width split into equal gutters.
    -- Even spacing without collision beats strict column alignment (owner's
    -- tiebreak), and NEITHER branch can place two boxes on top of each other.
    ------------------------------------------------------------------
    do
        local CHK_ROW_H   = 20   -- MakeCheckbox's own uiHeight
        local CHK_MIN_GAP = 16   -- gutter floor for the justified branch
        local CHK_MIN_COL = 60   -- below this a "column" is too thin to be one

        local host = CreateFrame("Frame", nil, flow.pane.child)
        host:SetHeight(CHK_ROW_H)

        local prefs = {
            {   label = "Suppress mesh-disabled alert",
                get = function() local db = DB(); return db and db.mesh.optOut end,
                set = function(v) local db = DB(); if db then db.mesh.optOut = v and true or false end end },
            {   label = "Auto-leave standard chat channels",
                get = function() local db = DB(); return db and db.mesh.autoLeaveChannel end,
                set = function(v) local db = DB(); if db then db.mesh.autoLeaveChannel = v and true or false end end },
            {   label = "Hard-throttle mesh sends",
                get = function() local db = DB(); return db and db.hardThrottle end,
                set = function(v) local db = DB(); if db then db.hardThrottle = v and true or false end end },
        }

        local boxes = {}
        for i, spec in ipairs(prefs) do
            local cb = UI.MakeCheckbox(host, spec)
            -- MakeCheckbox bakes uiWidth from the label's string width AT CONSTRUCTION.
            -- Remember that measurement so arrange can re-derive the intrinsic width
            -- from the LIVE string width (font scale / picked face can change after
            -- this page is built) without copying the factory's box+gap constants here.
            cb._builtLabelW = (cb._label and cb._label.GetStringWidth and cb._label:GetStringWidth()) or 0
            boxes[i] = cb
            register("mesh", cb.Refresh)
        end

        local function intrinsicW(cb)
            local w  = cb.uiWidth or 0
            local lw = (cb._label and cb._label.GetStringWidth and cb._label:GetStringWidth()) or 0
            if lw > 0 and (cb._builtLabelW or 0) > 0 then w = w + (lw - cb._builtLabelW) end
            return math.max(40, math.floor(w + 0.5))
        end

        host.arrange = function(width)
            host:SetWidth(math.max(width, 1)); host:SetHeight(CHK_ROW_H)

            local n = #boxes
            local iw, total = {}, 0
            for i = 1, n do iw[i] = intrinsicW(boxes[i]); total = total + iw[i] end

            -- Preferred branch: the identity block's equal columns.
            local colW = math.floor((width - ID_COL_GAP * (n - 1)) / n)
            local fits = colW >= CHK_MIN_COL
            for i = 1, n do if iw[i] > colW then fits = false end end

            -- Justified branch: leftover width split evenly between the boxes. The
            -- CHK_MIN_GAP clamp means a pane too narrow for the row runs PAST the
            -- right edge (visible, and the scroll pane is width-capped so it cannot
            -- happen in the hub) instead of stacking boxes on one another.
            local gutter = 0
            if not fits and n > 1 then
                gutter = math.max(CHK_MIN_GAP, math.floor((width - total) / (n - 1)))
            end

            local x = 0
            for i = 1, n do
                local cb = boxes[i]
                cb:ClearAllPoints()
                cb:SetPoint("LEFT", host, "LEFT", x, 0)
                cb:SetWidth(iw[i])   -- click target (and any tooltip anchor) stays on box + label
                x = x + (fits and (colW + ID_COL_GAP) or (iw[i] + gutter))
            end
            return CHK_ROW_H
        end

        flow.pane:AddBlock(host, host.arrange)   -- default topGap (rowGap) + zero indent
        for _, cb in ipairs(boxes) do cb:Refresh() end
        Options._meshPrefBoxes = boxes   -- self-test / diagnostic handle
    end

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

    -- SETTINGS-REWORK ITEM 3: the "Tombstones" section is gone from settings.
    -- UI ONLY. The tombstone MECHANISM is fully intact and load-bearing:
    -- Store.TombstoneAccount / IsTombstoned / SweepTombstones still back every
    -- mesh account delete (the Remove button in the Accounts table above writes
    -- one), the manifest-apply path still refuses a tombstoned account's data,
    -- and settings-rework item 1 relies on the same idea for retired locations.
    -- What is removed is the read-only expiry TABLE — a list the owner never
    -- acted on, ticking a countdown on a 14-day timer.
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
    flow:Hint("Coming from ShadowNetwork? /nexus import merges its channel, token, characters and settings in — it shows a confirmation with a summary first, and any Nexus settings you've already set are kept.")
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
----------------------------------------------------------------------
-- Faction toggle header.
--
-- SETTINGS-REWORK ITEM 6: the Buffs page no longer has one. Class rules are a
-- single global set, so a faction toggle there would be a control that changes
-- nothing — the worst kind. Automation is still genuinely per-faction (gossip
-- picks, summon triggers, invite whitelist) and keeps it.
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
-- 3. BUFFS  (was "Auras" — settings-rework item 4)
--
-- What this page is NOT any more:
--   * It has no Duration Thresholds table (item 4). Buff-time colour is a fixed
--     backend rule — 2h buffs go yellow under 90 minutes, 1h buffs under 55, the
--     15-minute NPC Battle Shout under 12, green above — stated once in
--     ui_shell.lua's Dashboard.BUFF_TIME_RULE. Eighteen editable numbers whose
--     only job was to reproduce those three facts are gone.
--   * It has no faction toggle (item 6). One global class-rule set.
--
-- What it still is: the DMF announce switch, and the four class-rule grids in
-- the owner's order — Battle Shout, Rend, Slip'kik, Fengus (item 5).
----------------------------------------------------------------------

local function buildBuffs(flow)
    local UI = DaseekiUI
    flow:Hint("Buff rules apply to every character on every account, on both factions.")

    -- ── Darkmoon Faire cooldown announcement ─────────────────────────────────
    -- Leads the page now that the threshold table it used to sit under is gone.
    -- Wires the existing DaseekiNexusDB.dmfPushAnnounce, which
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

    -- ── Class-rule grids, in the owner's order (item 5) ───────────────────────
    for _, g in ipairs(CLASS_RULE_GRIDS) do
        buildClassRuleGrid(flow, g.title, g.optKey, g.classes)
    end
end

-- A grid of cycling buttons: each class steps Required → Optional → Ignored.
-- SETTINGS-REWORK ITEM 6: state lives in the ONE global table,
-- Store.GetAuraRules()[optKey].{required,optional,ignored}[class] — it used to
-- be GetFactionSettings(scope).auraOpts[optKey], which is precisely how a tick
-- could land in the faction the owner does not play.
function buildClassRuleGrid(flow, title, optKey, classes)
    local UI = DaseekiUI
    flow:AddSection(title)
    flow:Hint("Required = red when missing · Optional = yellow · Ignored = hidden.")

    local STATES = { "required", "optional", "ignored" }
    -- Lowercase colored pill text (round-3 item 31).
    local STATE_LABEL = { required = "required", optional = "optional", ignored = "ignored" }
    -- Resolve auraRules[optKey] with its three buckets guaranteed to exist.
    -- Store.SeedAuraRules installs every roster key at login (including the
    -- back-filled new-aura maps), so this is belt-and-braces — but a raw
    -- `o.required[class]` on a nil map is a hard Lua error that would take the
    -- whole Buffs page down, and a new roster entry is exactly when that map
    -- can be missing. Creating the empty buckets here is additive and matches
    -- what the seeder would have written for an untouched, all-ignored rule.
    local function ruleMap(create)
        local rules = RULES(); if type(rules) ~= "table" then return nil end
        local o = rules[optKey]
        if type(o) ~= "table" then
            if not create then return nil end
            o = {}; rules[optKey] = o
        end
        if type(o.required) ~= "table" then o.required = {} end
        if type(o.optional) ~= "table" then o.optional = {} end
        if type(o.ignored)  ~= "table" then o.ignored  = {} end
        return o
    end
    local function getState(class)
        local o = ruleMap(false); if not o then return "ignored" end
        if o.required[class] then return "required" end
        if o.optional[class] then return "optional" end
        return "ignored"
    end
    local function setState(class, st)
        local o = ruleMap(true); if not o then return end
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
        -- Stamping `dropOnTaxiPvpChosen` is what makes Store.MigrateTaxiPvpDefault
        -- safe: the heal only touches an install still carrying our old shipped
        -- ON with nobody's decision behind it. Touching the box EITHER WAY is a
        -- decision, so the flag is set on both edges, not just on true.
        set = function(v)
            local fs = FS(); if not fs then return end
            fs.autoSummon.dropOnTaxiPvp       = v and true or false
            fs.autoSummon.dropOnTaxiPvpChosen = true
        end,
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
        label = Options.REPAIR_LABEL,
        get = function() local fs = FS(); return fs and fs.autoQuest.autoRepair end,
        set = function(v) local fs = FS(); if fs then fs.autoQuest.autoRepair = v and true or false end end,
    }).Refresh)
    q:Hint(Options.REPAIR_HINT)

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
    g:Hint("2.  On each account, open Settings \226\134\146 Setup and set a unique Account ID (1\226\128\1512 digits, different on each account).")
    g:Hint("3.  On the same Setup page, set the SAME Channel name (16+ letters/numbers, case sensitive) AND the SAME Token (6 letters/numbers) on every account \226\128\148 generate the credentials there, or paste a setup bundle to copy the same Channel and Token to another account.")
    g:Hint("4.  Enable the mesh, then log out and back in once on each account \226\128\148 characters appear across your accounts within seconds.")
    g:Hint("5.  Migrating from another world-buff addon? Run /nexus import to merge ShadowNetwork's settings, Channel, Token and data — it shows a confirmation with a summary of what it will add or update before applying — and /nexus import instances for NovaInstanceTracker's instance runs (see Troubleshooting).")
    g:Hint("Prefer it guided? Settings \226\134\146 Setup has a Setup guide button that walks steps 2\226\128\1514 in a three-step dialog with a live done/needed status on each step.")
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
    tr:Hint("Other accounts not showing? The Channel AND Token must match byte-for-byte on every account \226\128\148 both are case sensitive and together act as your mesh password. Correct any mismatch in Settings \226\134\146 Setup, then /reload.")
    tr:Hint("Characters under the wrong account? Two accounts are sharing an Account ID. Give each account its own unique ID in Settings \226\134\146 Setup.")
    tr:Hint("Copying settings to a new account? Set it up with the same Channel + Token, then use Sync Settings to Mesh in Settings \226\134\146 Setup, or /nexus syncsettings (you confirm the target account IDs first).")
    tr:Hint("Coming from ShadowNetwork? Run /nexus import \226\128\148 it merges your settings, Channel, Token and stored data, showing a confirmation with a summary first. It only works while ShadowNetwork is still installed and loaded, so keep ShadowNetwork installed until you've seen that import confirmation and checked everything carried over before disabling it.")

    -- The Tombstones TABLE left the Setup page (settings-rework item 3); the
    -- mechanism did not, and it is still what makes a delete stick, so it stays
    -- documented here. There is simply no longer a screen listing the countdowns.
    local ac = flow:AddSection("Accounts")
    ac:Hint("Deleting an account is local only \226\128\148 it hides that account on THIS client and leaves a 14-day tombstone that blocks it from re-appearing. The tombstone expires on its own; there is nothing to manage.")
    ac:Hint("Changing your Account ID migrates your data locally; other accounts keep showing your OLD ID until they delete it.")
    ac:Hint("If two accounts use the same ID you'll see an \"Account ID conflict\" warning \226\128\148 change one of them to a unique ID.")
    ac:Hint("You can't delete your OWN account \226\128\148 change your Account ID instead.")

    local ds = flow:AddSection("First-time setup (detailed)")
    ds:Hint("1.  Account ID \226\128\148 In Settings \226\134\146 Setup, give this account a short unique ID (1\226\128\1512 digits). Every connected account needs a DIFFERENT ID; this is how the mesh tells your accounts apart.")
    ds:Hint("2.  Channel \226\128\148 On the same Setup page, set a Channel name of 16+ letters and numbers. It is case sensitive and must be identical on every account \226\128\148 think of it as the room your accounts meet in.")
    ds:Hint("3.  Token \226\128\148 Set a 6-character Token (letters/numbers), also identical everywhere. Generate the credentials on the Setup page, or paste a setup bundle to copy the same Channel and Token to another account. The Channel + Token together are your mesh password; anyone with both can see your roster, so keep them private.")
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

-- The hub section roster, hoisted out of Register() so it is BUILDABLE
-- HEADLESSLY. The settings rework renamed two pages the owner navigates by name
-- ("Mesh & Accounts" -> "Setup", "Auras" -> "Buffs"), and a rename is exactly
-- the kind of change that half-lands — title updated, build function still
-- pointing at the old page, or vice versa. The "options" suite calls this and
-- asserts every id/title pair, so "the renamed page is reachable" is a test
-- rather than a screenshot.
--
-- The `id`s are DELIBERATELY unchanged. They are the hub's addressing keys (and
-- this file's own refresher-list keys); renaming a page's label is a copy
-- change, renaming its id would be a compatibility change for no gain.
function Options.BuildSections()
    return {
        { id = "general",    title = "General",
          build = function(flow) once("general", flow.pane, function() buildGeneral(flow) end) end,
          refresh = function() refreshPage("general") end },
        -- Item 2: "Mesh & Accounts" -> "Setup".
        { id = "mesh",       title = "Setup",
          build = function(flow) once("mesh", flow.pane, function() buildMesh(flow) end) end,
          refresh = function() refreshPage("mesh") end },
        -- Item 4: "Auras" -> "Buffs".
        { id = "auras",      title = "Buffs",
          build = function(flow) once("auras", flow.pane, function() buildBuffs(flow) end) end,
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
    }
end

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
        sections = Options.BuildSections(),
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

    -- Raw EditBoxes (the Setup page's three identity cells) work without a host
    -- wrapper. This is the anti-regression seam for the Channel-typing bug after
    -- item 2 rebuilt those fields by hand: the new boxes are raw EditBoxes, not
    -- flow-API host frames, so `isEditing` HAS to recognise a bare box or the
    -- focus guard silently stops guarding and the field nulls out mid-word again.
    local _, raw = fakeBox(function() return "" end)
    raw.focus = true;  ck(isEditing(raw) == true,  "raw editbox recognised while focused")
    raw.focus = false; ck(isEditing(raw) == false, "raw editbox recognised while idle")

    -- The 2s ticker repaints the live subset, which must exist and stay a strict
    -- subset of the Mesh page's refreshers.
    ck(type(refreshers.meshLive) == "table", "meshLive registry exists")
    ck(#refreshers.meshLive <= #refreshers.mesh, "meshLive is a subset of mesh")

    ----------------------------------------------------------------------
    -- FACTION COPY: WHAT IT MUST NOT TAKE WITH IT (spec §12.3, audit rows 34-36).
    --
    -- The copy is a bulk overwrite the user asks for, so the interesting rows
    -- are the ones it must LEAVE ALONE: the destination's own whitelist state
    -- and the two sticky seeding guards. Getting those wrong is a data-safety
    -- bug, not a preference bug — a cleared whitelist comes back, or a
    -- deliberately-off whitelist silently switches on.
    ----------------------------------------------------------------------
    local src = {
        autoGroup = {
            whitelist = { ["Src-R"] = true }, whitelistEnabled = false,
            defaultsApplied = true, inviteKeyword = "grp", sendToGuild = true,
        },
        autoSummon = {
            enabled = true, defaultsApplied = true, dropOnTaxiPvp = true,
            triggers = { songflower = true },
        },
        autoGossip = { dmt = true, dmf = { enabled = true,
            buffType = { PALADIN = "damage", SHAMAN = "damage", MAGE = "intellect" } } },
        autoQuest = { autoRepair = true },
    }
    local dst = {
        autoGroup = {
            whitelist = { ["Dst-R"] = true }, whitelistEnabled = true,
            defaultsApplied = false, inviteKeyword = "inv", sendToGuild = false,
        },
        autoSummon = {
            enabled = false, defaultsApplied = false, dropOnTaxiPvp = false,
            triggers = {},
        },
        autoGossip = { dmt = false, dmf = { enabled = false,
            buffType = { PALADIN = "armor", SHAMAN = "spirit", MAGE = "damage" } } },
        autoQuest = { autoRepair = false },
    }
    ck(Options.ApplyFactionCopy(src, dst) == true, "faction copy runs")

    -- IN scope: the automation settings really do copy.
    ck(dst.autoGroup.inviteKeyword == "grp", "copy: keyword copied")
    ck(dst.autoGroup.sendToGuild == true,    "copy: send gate copied")
    ck(dst.autoSummon.enabled == true,       "copy: summon enable copied")
    ck(dst.autoSummon.triggers.songflower == true, "copy: triggers copied")
    ck(dst.autoGossip.dmt == true,           "copy: gossip toggle copied")
    ck(dst.autoQuest.autoRepair == true,     "copy: quest block copied")
    ck(dst.autoGossip.dmf.buffType.MAGE == "intellect", "copy: non-exclusive class row copied")

    -- OUT of scope: the destination's own state survives, all five rows.
    ck(dst.autoGroup.whitelist["Dst-R"] == true and dst.autoGroup.whitelist["Src-R"] == nil,
       "copy preserves the destination whitelist")
    ck(dst.autoGroup.whitelistEnabled == true,
       "copy preserves the destination whitelistEnabled (row 35)")
    ck(dst.autoGroup.defaultsApplied == false,
       "copy preserves the destination autoGroup defaultsApplied (row 36)")
    ck(dst.autoSummon.defaultsApplied == false,
       "copy preserves the destination autoSummon seeding guard")
    ck(dst.autoGossip.dmf.buffType.PALADIN == "armor"
       and dst.autoGossip.dmf.buffType.SHAMAN == "spirit",
       "copy preserves the faction-exclusive Paladin/Shaman rows")

    -- A copy IS a decision about the taxi rule, so the migration must not undo it.
    ck(dst.autoSummon.dropOnTaxiPvp == true, "copy: taxi rule copied")
    ck(dst.autoSummon.dropOnTaxiPvpChosen == true, "copy marks the taxi rule as chosen")

    -- Deep copy, not aliasing: editing the source afterwards must not move the
    -- destination.
    src.autoSummon.triggers.songflower = nil
    ck(dst.autoSummon.triggers.songflower == true, "copy is a deep copy, not a reference")
    ck(Options.ApplyFactionCopy(nil, dst) == false, "faction copy refuses bad input")

    ----------------------------------------------------------------------
    -- AUTO-REPAIR LABEL HONESTY (1.1.4 conformance wave).
    --
    -- auto.lua's OnMerchantShow repairs at ANY vendor window the player opens —
    -- owner-approved, but it means the checkbox must not name one NPC. These
    -- assertions are what stops the old wording coming back: they fail loudly
    -- the moment the label re-acquires an NPC name, and they are the only
    -- reachable seam for a string that otherwise lives inside a UI closure.
    ck(type(Options.REPAIR_LABEL) == "string" and Options.REPAIR_LABEL ~= "",
       "repair label is a non-empty string")
    ck(not Options.REPAIR_LABEL:lower():find("rin'wosho", 1, true),
       "repair label must NOT claim to be scoped to Rin'wosho")
    ck(Options.REPAIR_LABEL:lower():find("vendor", 1, true) ~= nil,
       "repair label says 'vendor' -- what it actually does")
    ck(type(Options.REPAIR_HINT) == "string"
       and Options.REPAIR_HINT:lower():find("any", 1, true) ~= nil,
       "repair hint spells out the any-vendor scope")

    ----------------------------------------------------------------------
    -- SAYGE DROPDOWN <-> ENGINE PAGE-MAP PARITY.
    --
    -- The dropdown offers eight buff types; auto.lua answers Sayge by looking
    -- the chosen string up in the spec's two page maps. If those two lists ever
    -- drift, the owner picks a buff the engine cannot resolve and the flow
    -- silently refuses (or, before the shape guard, guessed). Assert every
    -- offered value resolves on BOTH pages, and that the shipped default is one
    -- of them.
    if ns.Auto and ns.Auto.SAYGE_PAGE then
        for _, t in ipairs(DMF_BUFF_TYPES) do
            ck(ns.Auto.SAYGE_PAGE[4][t] ~= nil, "dropdown value '" .. t .. "' maps on Sayge page 1")
            ck(ns.Auto.SAYGE_PAGE[3][t] ~= nil, "dropdown value '" .. t .. "' maps on Sayge page 2")
        end
        local defaultOffered = false
        for _, t in ipairs(DMF_BUFF_TYPES) do
            if t == ns.Auto.SAYGE_DEFAULT_BUFF then defaultOffered = true end
        end
        ck(defaultOffered, "the engine's default Sayge buff type is offered by the dropdown")
    end

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
               ("display class-ruled key %q has a Buffs-page grid"):format(k))
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
        -- The AUTOMATION write target still follows the scope (gossip picks,
        -- summon triggers and the invite whitelist are genuinely per-faction).
        -- Class rules no longer do — see the global-table assertions below.
        local fs = FS()
        local hordeFS = ns.Store and ns.Store.GetFactionSettings
                        and ns.Store.GetFactionSettings("Horde")
        ck(fs ~= nil and fs == hordeFS,
           "automation writes land in the OWN-faction settings table")
    end)
    withFaction("Alliance", function()
        ck(ScopeFaction() == "Alliance", "an Alliance player opens on Alliance")
    end)

    ----------------------------------------------------------------------
    -- SAME-TABLE ASSERTION (owner bug 1.1.4, zanza pick list).
    --
    -- The owner's SavedVariables carried two faction blocks with two different
    -- generations of zanza shape, which raises the obvious question: is the
    -- Quest section writing into one faction block while auto.lua reads the
    -- other? It is not. This page reaches the block through
    -- Store.GetFactionSettings(ScopeFaction()) and auto.lua through
    -- Store.GetFactionSettings(UnitFactionGroup("player")); both resolve to the
    -- player's own faction, so both hand back the SAME table — asserted here by
    -- identity, on both factions, against the shared harness store.
    --
    -- The ONE way they can diverge is the Faction segmented control at the top
    -- of this page, which is a deliberate, labelled, session-only control for
    -- inspecting the off-faction settings. That divergence is asserted too, so
    -- the day it stops being deliberate the harness says so.
    ----------------------------------------------------------------------
    local AQ = ns.Auto and ns.Auto.AQBlock
    ck(type(AQ) == "function", "auto.lua exposes its autoQuest accessor for this assertion")
    if type(AQ) == "function" then
        for _, f in ipairs({ "Horde", "Alliance" }) do
            withFaction(f, function()
                local fs, engine = FS(), AQ()
                ck(fs ~= nil and engine ~= nil and rawequal(fs.autoQuest, engine),
                   ("%s: the options page and the engine share ONE autoQuest table"):format(f))
                if fs and engine then
                    ck(rawequal(fs.autoQuest.zanza, engine.zanza),
                       ("%s: ...and ONE zanza block, so a tick lands where the engine reads")
                       :format(f))
                    -- Drive it the way the checkbox does and read it back the
                    -- way Auto.ZanzaPickAndRequest does.
                    local saved = fs.autoQuest.zanza.priority
                    fs.autoQuest.zanza.priority = { "swiftness" }
                    local picks = ns.Auto.ZanzaEnabledPicks(engine.zanza.priority)
                    ck(#picks == 1 and picks[1] == "swiftness",
                       ("%s: a tick written by the UI is what the engine picks up"):format(f))
                    fs.autoQuest.zanza.priority = saved
                end
            end)
        end
        -- The deliberate exception: an explicit off-faction toggle.
        withFaction("Horde", function()
            SetScopeFaction("Alliance")
            local fs, engine = FS(), AQ()
            ck(fs and engine and not rawequal(fs.autoQuest, engine),
               "the Faction toggle deliberately points the page at the OTHER faction block")
            SetScopeFaction(nil)
        end)
    end
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

    _G.UnitFactionGroup = realUFG
    SetScopeFaction(nil)                        -- leave the live session unpinned

    ----------------------------------------------------------------------
    -- SETTINGS-REWORK ITEM 6 — the grids write the ONE GLOBAL table.
    --
    -- End-to-end, the owner's exact click: tick Shaman = required for Slip'kik,
    -- then read it back the way a card does — and read it back on BOTH factions,
    -- because the whole point of the merge is that the answer no longer depends
    -- on which faction table the click happened to land in.
    ----------------------------------------------------------------------
    local rules = RULES()
    ck(type(rules) == "table", "Store.GetAuraRules exposes the global rule table")
    if type(rules) == "table" and D and D.AuraRequirement then
        for _, g in ipairs(Options.CLASS_RULE_GRIDS) do
            ck(type(rules[g.optKey]) == "table",
               ("global rule map %q exists (seeded/back-filled)"):format(g.optKey))
        end
        local o = rules.dmtSP
        if type(o) == "table" then
            o.required = o.required or {}; o.optional = o.optional or {}; o.ignored = o.ignored or {}
            local pReq, pOpt, pIgn = o.required.SHAMAN, o.optional.SHAMAN, o.ignored.SHAMAN
            o.required.SHAMAN, o.optional.SHAMAN, o.ignored.SHAMAN = true, nil, nil
            local aH, rH = D.AuraRequirement(8, { classTag = "SHAMAN" }, "Horde")
            local aA, rA = D.AuraRequirement(8, { classTag = "SHAMAN" }, "Alliance")
            ck(aH == true and rH == "required",
               "Slip'kik required-for-Shaman reads back as required (red) on Horde")
            ck(aA == true and rA == "required",
               "...and identically on Alliance — one tick, one answer, both factions")
            o.required.SHAMAN, o.optional.SHAMAN, o.ignored.SHAMAN = pReq, pOpt, pIgn
        end
    end

    ----------------------------------------------------------------------
    -- SETTINGS-REWORK ITEM 5 — the grid ORDER is the owner's, and it is pinned
    -- against store.lua's Store.AURA_RULE_KEYS so the two tables cannot drift.
    -- Order is a UI fact with no runtime consequence, which is exactly the kind
    -- that silently reverts in a later refactor.
    ----------------------------------------------------------------------
    local wantOrder = ns.Store and ns.Store.AURA_RULE_KEYS
    ck(type(wantOrder) == "table" and #wantOrder == 4, "Store.AURA_RULE_KEYS lists 4 rules")
    if type(wantOrder) == "table" then
        ck(wantOrder[1] == "battleShout" and wantOrder[2] == "rend"
            and wantOrder[3] == "dmtSP" and wantOrder[4] == "dmtAP",
           "canonical order is Battle Shout, Rend, Slip'kik, Fengus")
        ck(#Options.CLASS_RULE_GRIDS == #wantOrder,
           "the Buffs page draws exactly one grid per rule")
        for i, key in ipairs(wantOrder) do
            local g = Options.CLASS_RULE_GRIDS[i]
            ck(g and g.optKey == key,
               ("grid %d is %q (got %q)"):format(i, key, tostring(g and g.optKey)))
        end
    end

    ----------------------------------------------------------------------
    -- ITEMS 2 + 4 — the RENAMED PAGES ARE REACHABLE. A rename that updates the
    -- label but not the builder (or the reverse) produces a page the owner can
    -- see and not open, which no amount of reading the diff reliably catches.
    -- Build the real roster and assert id -> title -> a callable builder.
    ----------------------------------------------------------------------
    local sections = Options.BuildSections()
    ck(type(sections) == "table" and #sections > 0, "Options.BuildSections returns a roster")
    local byId = {}
    for _, s in ipairs(sections or {}) do
        byId[s.id] = s
        ck(type(s.title) == "string" and s.title ~= "",
           ("section %q has a title"):format(tostring(s.id)))
        ck(type(s.build) == "function" and type(s.refresh) == "function",
           ("section %q has build + refresh"):format(tostring(s.id)))
    end
    ck(byId.mesh and byId.mesh.title == "Setup",
       "item 2: the mesh page is titled \"Setup\" (was \"Mesh & Accounts\")")
    ck(byId.auras and byId.auras.title == "Buffs",
       "item 4: the aura page is titled \"Buffs\" (was \"Auras\")")
    -- The ids are the hub's addressing keys AND this file's refresher-list keys;
    -- a rename of either would strand every register() call on that page.
    for _, id in ipairs({ "general", "mesh", "auras", "automation", "timers",
                          "instances", "alerts", "blacklist", "help" }) do
        ck(byId[id] ~= nil, ("section id %q survives the rename"):format(id))
        ck(type(refreshers[id]) == "table",
           ("refresher list %q exists for that section"):format(id))
    end
    -- No page may still be called by a retired name.
    for _, s in ipairs(sections or {}) do
        ck(s.title ~= "Auras" and s.title ~= "Mesh & Accounts",
           ("no section still uses the old title %q"):format(tostring(s.title)))
    end

    ----------------------------------------------------------------------
    -- ITEMS 1 + 3 — the retired BUILDERS are gone, not merely unreferenced.
    -- These were file-locals/forward declarations; if a later edit reinstates
    -- one, the section comes back with it. Asserting the absence of the writer
    -- is the cheapest way to keep a deletion deleted.
    ----------------------------------------------------------------------
    ck(rawget(Options, "CopyFaction") ~= nil, "CopyFaction (automation copy) is retained")
    ck(ns.Store and type(ns.Store.RetireLocations) == "function",
       "item 1: Store.RetireLocations exists (locations are retired by migration)")
    ck(ns.Store and type(ns.Store.RetireClassColors) == "function",
       "item 1: Store.RetireClassColors exists (palette is fixed)")
    -- Item 3 is UI-only: the MECHANISM must still be there in full.
    ck(ns.Store and type(ns.Store.TombstoneAccount) == "function"
        and type(ns.Store.IsTombstoned) == "function"
        and type(ns.Store.SweepTombstones) == "function",
       "item 3: the tombstone mechanism is untouched (UI removal only)")

    if verbose and pass then ns:Print("  PASS options/editbox-focus-guard") end
    return pass
end)

-- Register once Core + Store are both ready.
ns:On("STORE_READY", function()
    ns:SafeCall(Options.Register)
end)
