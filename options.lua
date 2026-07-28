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
-- Section map (spec's 9 sub-tabs → 6 scannable pages, style-guide consolidation):
--   General          = General + Locations + Colors
--   Mesh & Accounts  = Mesh + Accounts
--   Auras            = per-faction thresholds + Rend/Battle-Shout class rules
--   Automation       = Auto (Group / Accept Summon / Gossip / Quest / Interact)
--   Timers & Alerts  = Timers (raid overrides, alert matrix, sounds, bars, pins)
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
-- cosmetic question-mark fallback). The engine owns the authoritative trigger set
-- (anticipated ns.Store.SUMMON_TRIGGER_BUFFS); this catalog is the UI's label/icon
-- source and the pre-merge fallback ordering.
local TRIGGER_DEFS = {
    { key = "dmf",        abbr = "DMF",      name = "Sayge's Dark Fortune",  spellID = 23768 },
    { key = "ony",        abbr = "Ony",      name = "Rallying Cry of the Dragonslayer", spellID = 22888 },
    { key = "zg",         abbr = "ZG",       name = "Spirit of Zandalar",    spellID = 24425 },
    { key = "dmtAP",      abbr = "DMT AP",   name = "Fengus' Ferocity",      spellID = 22817 },
    { key = "dmtSP",      abbr = "DMT SP",   name = "Slip'kik's Savvy",      spellID = 22820 },
    { key = "dmtStam",    abbr = "DMT Stam", name = "Mol'dar's Moxie",       spellID = 22818 },
    { key = "songflower", abbr = "SF",       name = "Songflower Serenade",   spellID = 15366 },
    { key = "rend",       abbr = "Rend",     name = "Warchief's Blessing",   spellID = 16609 },
    { key = "battleShout", abbr = "BS",      name = "Battle Shout",          spellID = 6673  },
    { key = "fff",        abbr = "FFF",      name = "Fervor of the Fallen (seasonal)", spellID = nil },
}

-- Classes for the Rend rule cycler (all nine) and the Battle Shout cycler
-- (melee/hunter only, per spec §2).
local REND_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local BS_CLASSES   = { "WARRIOR", "ROGUE", "HUNTER" }
-- Slip'kik's Savvy / DMT SP covers all 9 classes (same as Rend); defaults live
-- in store.lua (physical = ignored, casters = optional), editable per faction.
local SLIPKIK_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
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
-- Small helpers
----------------------------------------------------------------------

local function DB()  return ns.Store and ns.Store.GetSettings and ns.Store.GetSettings() or nil end
local function TS()  local db = DB(); return db and db.timerSettings or nil end

-- Faction scope shared across the Auras + Automation pages. Only one of those
-- pages is visible at a time; each rebuilds from this on show.
local scope = { faction = "Alliance" }
local function FS() return ns.Store and ns.Store.GetFactionSettings and ns.Store.GetFactionSettings(scope.faction) or nil end

-- Per-page refresher registries (called on faction toggle / section show).
local refreshers = { auras = {}, automation = {}, mesh = {}, general = {}, timers = {}, blacklist = {} }
local function register(page, fn) local l = refreshers[page]; l[#l + 1] = fn end
local function refreshPage(page)
    local l = refreshers[page]
    for i = 1, #l do
        local ok, err = pcall(l[i])
        if not ok then geterrorhandler()(err) end
    end
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
            row.name:SetText(rules[idx].label or "")
            row.x:SetText(fmt(cx(rules[idx])))
            row.y:SetText(fmt(cy(rules[idx])))
            row.tol:SetText(fmt(tolOf(rules[idx])))
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
        rules[#rules + 1] = { name = "", zone = "", label = "New Location",
                              minX = 0, maxX = 0.02, minY = 0, maxY = 0.02 }
        rebuild()
    end })
    act:Button({ text = "Reset to Defaults", width = 160, variant = "danger", onClick = function()
        UI.Confirm({ title = "Reset Locations", danger = true,
            text = "Restore the default location rules? Your custom rules are removed.",
            acceptText = "Reset",
            onAccept = function()
                local db = DB(); if not db then return end
                db.coordinateOverrides = {
                    { name = "Rend North Staging", zone = "Orgrimmar", minX = 0.30, maxX = 0.55, minY = 0.55, maxY = 0.80, label = "Rend Staging (N)" },
                    { name = "Rend South Staging", zone = "Durotar",   minX = 0.40, maxX = 0.60, minY = 0.10, maxY = 0.30, label = "Rend Staging (S)" },
                    { name = "DMF Mulgore",        zone = "Mulgore",   minX = 0.30, maxX = 0.50, minY = 0.55, maxY = 0.75, label = "Darkmoon Faire" },
                }
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
        row:Button({ text = "Reset", width = 66, variant = "quiet", pin = "right", onClick = function()
            local db = DB(); if not db then return end
            db.classColors[class] = DEFAULTS[class]
            if box.Refresh then box.Refresh() end
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

    flow:AddSection("Mesh")
    flow:Hint("Your accounts meet on a private hidden channel. Set the SAME channel name and token on every account, then enable.")

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
        local eyeBtn
        eyeBtn = row:Button({ text = "Show", width = 48, variant = "quiet", onClick = function()
            revealed.on = not revealed.on
            eyeBtn._label:SetText(revealed.on and "Hide" or "Show")
            if box.Refresh then box.Refresh() end
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
    acctRow:Label("Account ID")
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
    register("mesh", function()
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
    tomb:Hint("(deleted, will block re-add until expiry)")
    buildTombstonesTable(tomb)
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
    register("mesh", rebuild)
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
    register("mesh", rebuild)
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
        get = function() return scope.faction end,
        set = function(v) scope.faction = v; refreshPage(page) end,
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
        register("auras", function() if nBox.Refresh then nBox.Refresh() end; if mBox.Refresh then mBox.Refresh() end end)
    end

    -- ── Rend / Battle Shout class rules (cycling buttons) ─────────────────────
    buildClassRuleGrid(flow, "Rend — Required Classes", "rend", REND_CLASSES)
    buildClassRuleGrid(flow, "Battle Shout — Required Classes", "battleShout", BS_CLASSES)
    -- Slip'kik's Savvy (DMT SP): physical damage users typically don't want it,
    -- so it ships ignored for War/Rogue/Hunter and optional for casters.
    buildClassRuleGrid(flow, "Slip'kik's Savvy (DMT SP) — Required Classes", "dmtSP", SLIPKIK_CLASSES)
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
    win:Label("(5-3600)", { muted = true })
    register("automation", function() if winBox.Refresh then winBox.Refresh() end end)

    -- Buff triggers sub-group (round-3 item 23): all ten trigger buffs, each as an
    -- icon + "ABBR - Full Name" checkbox row (two per row for compactness).
    -- ENGINE DEPENDENCY: the authoritative set is ns.Store.SUMMON_TRIGGER_BUFFS;
    -- TRIGGER_DEFS is the UI label/icon source and the pre-merge ordering fallback.
    local bt = flow:AddSection("Buff Triggers")
    bt:Hint("Accept a pending summon when one of these buffs is freshly gained.")
    local triggerKeys = ns.Store and ns.Store.SUMMON_TRIGGER_BUFFS
    local function trigMeta(key)
        for _, d in ipairs(TRIGGER_DEFS) do if d.key == key then return d end end
        return { key = key, abbr = key, name = key, spellID = nil }
    end
    local trigList = {}
    if type(triggerKeys) == "table" and #triggerKeys > 0 then
        for _, k in ipairs(triggerKeys) do trigList[#trigList + 1] = trigMeta(k) end
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
            if reqF and reqF ~= scope.faction then row:Hide(); return 0 end
            row:Show(); return origArrange(width)
        end
        blk._baseGap = blk.topGap
        register("automation", function()
            local reqF = CLASS_FACTION[class]
            blk.topGap = (reqF and reqF ~= scope.faction) and 0 or blk._baseGap
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
    local ro = flow:AddSection("Raid Overrides")
    ro:Hint("Suppress these alert channels while inside a raid instance.")
    local rr = ro:AddRow({ vAlign = "center" })
    local function roCheck(label, key)
        register("timers", rr:Checkbox({
            label = label,
            get = function() local ts = TS(); return ts and ts.raidDisable[key] end,
            set = function(v) local ts = TS(); if ts then ts.raidDisable[key] = v and true or false end end,
        }).Refresh)
    end
    roCheck("Screen", "notify"); roCheck("Chat", "chat"); roCheck("Flash", "flash"); roCheck("Sound", "sound")

    -- ── Alert matrix (EVENT-MAJOR, round-3 items 13/14/24) ────────────────────
    -- The reference groups by event type: each event is a sub-header, under which
    -- sit the buff rows for that event, each row = buff icon + name + inline On /
    -- Screen / Chat / Flash checkboxes + a per-row Sound dropdown + Test.
    -- ENGINE DEPENDENCIES (defensive fallbacks; see report):
    --   * cell.enabled  — the "On" master flag (defaults true when absent).
    --   * cell.sound — per-row sound tone (item 14; replaces the old event-level
    --     ts.soundKeys). Falls back to "" (None) until the engine schema lands.
    --   * ns.Store.ALERT_EVENT_BUFFS / ALERT_EVENT_TYPES — per-event buff sets +
    --     order (item 24; local fallbacks encode the reference sets).
    flow:AddSection("Alert Matrix")
    flow:Hint("Timer alert settings — control notifications per event type.")

    -- Sound channel (global; spec §8 Sound Channel dropdown).
    local scRow = flow:AddRow({ vAlign = "center" })
    local scLbl = scRow:Label("Sound channel"); scLbl.uiWidth = 100; scLbl._label:SetWidth(100)
    local scDD = scRow:Dropdown({
        width = 140, choices = SOUND_CHANNELS,
        get = function() local ts = TS(); return ts and ts.soundChannel or "Master" end,
        set = function(v) local ts = TS(); if ts then ts.soundChannel = v end end,
    })
    register("timers", function() if scDD.Refresh then scDD.Refresh() end end)

    -- Hand-merge reconciliation: the engine shipped the migrated schema
    -- EVENT-MAJOR (alerts[eventType][buffKey]) — flip the accessor to match.
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
                register("timers", row:Checkbox({
                    label = "On",
                    get = function() local c = alertCell(k, evt); if not c then return false end
                        if c.enabled == nil then return true end; return c.enabled end,
                    set = function(v) local c = alertCell(k, evt); if c then c.enabled = v and true or false end end,
                }).Refresh)
                local function chan(label, key)
                    register("timers", row:Checkbox({
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
                register("timers", function() if dd.Refresh then dd.Refresh() end end)
                row:Button({ text = "Test", width = 52, variant = "quiet", pin = "right", onClick = function()
                    hudTestAlert(k, evt)
                end })
            end
        end
    end

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

    local colRow = pb:AddRow({ vAlign = "center" })
    colRow:Label("Fill / BG hex")
    local fillBox = colRow:EditBox({
        width = 80,
        get = function() local ts = TS(); return ts and ts.pullBar.colorFill or "" end,
        set = function(v) local ts = TS(); if ts then ts.pullBar.colorFill = sanitizeHex(v):lower() end end,
    })
    fillBox._fillWidth = false; fillBox.editBox:SetMaxLetters(6)
    local bgBox = colRow:EditBox({
        width = 80,
        get = function() local ts = TS(); return ts and ts.pullBar.colorBG or "" end,
        set = function(v) local ts = TS(); if ts then ts.pullBar.colorBG = sanitizeHex(v):lower() end end,
    })
    bgBox._fillWidth = false; bgBox.editBox:SetMaxLetters(6)
    register("timers", function() if fillBox.Refresh then fillBox.Refresh() end; if bgBox.Refresh then bgBox.Refresh() end end)

    -- ── Felwood pins ───────────────────────────────────────────────────────────
    local fw = flow:AddSection("Felwood Pins")
    fw:Hint("Show Songflower and tuber spawn pins on the world map and minimap.")
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

    -- Full 5-field pin sizing (round-3 item 26). ENGINE DEPENDENCY: the split
    -- fields (worldFlowerPinSize / worldTuberPinSize / worldTimerFontSize /
    -- minimapFlowerPinSize / minimapTuberPinSize) are added by the engine agent;
    -- each read falls back to the current single worldPinSize / minimapPinSize.
    local pinSliders = {}
    local function pinSlider(label, key, fallbackKey, defVal, lo, hi)
        local s = fw:Slider({
            label = label, width = 300, min = lo, max = hi, step = 1,
            get = function() local ts = TS(); if not ts then return defVal end
                return ts.felwood[key] or ts.felwood[fallbackKey] or defVal end,
            set = function(v) local ts = TS(); if ts then ts.felwood[key] = v end end,
            format = function(v) return tostring(math.floor(v)) end,
        })
        pinSliders[#pinSliders + 1] = s
        return s
    end
    pinSlider("World map songflower pin (px) — (8-24) default 14", "worldFlowerSize", "worldPinSize", 14, 8, 24)
    pinSlider("World map tuber pin (px) — (8-24) default 14",      "worldTuberSize",  "worldPinSize", 14, 8, 24)
    pinSlider("World map timer font (pt) — (6-20) default 10",     "worldTimerFont", "worldTimerFont", 10, 6, 20)
    pinSlider("Minimap songflower pin (px) — (8-24) default 12",   "minimapFlowerSize", "minimapPinSize", 12, 8, 24)
    pinSlider("Minimap tuber pin (px) — (8-24) default 12",        "minimapTuberSize",  "minimapPinSize", 12, 8, 24)
    register("timers", function() for _, s in ipairs(pinSliders) do if s.Refresh then s.Refresh() end end end)

    -- ── Songflower display ───────────────────────────────────────────────────────
    -- Drives the Timers-tab UP?/minus state machine (timers.lua NodeState).
    local sf = flow:AddSection("Songflower Display")
    sf:Hint("Minus-timer counts the respawn; UP? window shows after respawn (0 = always).")
    -- NOTE: range/default hints per round-3 item 25. Item 27 (ENGINE) will revise
    -- these ranges/defaults (UP? 1-30s default 5; minus 30-600s default 120) and
    -- drop the 0="always" sentinel — reconcile min/max + labels at merge.
    local sfMinus = sf:Slider({
        label = "Minus-timer duration — (5:00-50:00) default 25:00", width = 300, min = 300, max = 3000, step = 30,
        get = function() local ts = TS(); return ts and ts.felwood.flowerMinusDuration or 1500 end,
        set = function(v) local ts = TS(); if ts then ts.felwood.flowerMinusDuration = v end end,
        format = function(v) v = math.floor(v); return ("%d:%02d"):format(math.floor(v / 60), v % 60) end,
    })
    local sfUp = sf:Slider({
        label = "UP? duration — (0-60:00) default always", width = 300, min = 0, max = 3600, step = 30,
        get = function() local ts = TS(); return ts and ts.felwood.flowerUpDuration or 0 end,
        set = function(v) local ts = TS(); if ts then ts.felwood.flowerUpDuration = v end end,
        format = function(v) v = math.floor(v); if v <= 0 then return "always" end
            return ("%d:%02d"):format(math.floor(v / 60), v % 60) end,
    })
    register("timers", function() if sfMinus.Refresh then sfMinus.Refresh() end; if sfUp.Refresh then sfUp.Refresh() end end)

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
                ns:Print("timer data reset.")
            end })
    end })
end

----------------------------------------------------------------------
-- 6. BLACKLIST
----------------------------------------------------------------------

local function buildBlacklist(flow)
    local UI = DaseekiUI
    local DS = _G.DaseekiSuite

    -- ── Character Blacklist (inline textareas, round-3 item 33) ────────────────
    local sec = flow:AddSection("Character Blacklist")
    sec:Hint("Hide characters from 60s and Summoners tabs. They still appear in Online and function normally.")
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
    local paBox = paRow:EditBox({ width = 60, get = function() return "" end })
    paBox._fillWidth = false
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
-- Live-refresh ticker (Accounts / Tombstones update while visible)
----------------------------------------------------------------------

local liveTicker
local function ensureLiveTicker()
    if liveTicker then return end
    if not C_Timer or not C_Timer.NewTicker then return end
    liveTicker = C_Timer.NewTicker(2, function()
        local pane = Options._meshPane
        if pane and pane.IsVisible and pane:IsVisible() then
            refreshPage("mesh")
        end
    end)
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
            { id = "timers",     title = "Timers & Alerts",
              build = function(flow) once("timers", flow.pane, function() buildTimers(flow) end) end,
              refresh = function() refreshPage("timers") end },
            { id = "blacklist",  title = "Blacklist",
              build = function(flow) once("blacklist", flow.pane, function() buildBlacklist(flow) end) end,
              refresh = function() refreshPage("blacklist") end },
        },
    })
end

-- Register once Core + Store are both ready.
ns:On("STORE_READY", function()
    ns:SafeCall(Options.Register)
end)
