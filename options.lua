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
-- spellID drives the row icon only (cosmetic — GetSpellTexture, guarded).
local AURA_DEFS = {
    { key = "dmf",      label = "Darkmoon Faire",  spellID = 23768 },  -- Sayge's Dark Fortune
    { key = "ony",      label = "Onyxia",          spellID = 22888 },  -- Rallying Cry
    { key = "dmtAP",    label = "DMT — Attack",    spellID = 22817 },  -- Fengus' Ferocity
    { key = "dmtSP",    label = "DMT — Spell",     spellID = 22820 },  -- Slip'kik's Savvy
    { key = "dmtStam",  label = "DMT — Stamina",   spellID = 22801 },  -- Mol'dar's Moxie
    { key = "songflower", label = "Songflower",    spellID = 15366 },  -- Songflower Serenade
    { key = "zg",       label = "Zandalar (ZG)",   spellID = 24425 },  -- Spirit of Zandalar
    { key = "rend",     label = "Rend (Warchief)", spellID = 16609 },  -- Warchief's Blessing
    { key = "battleShout", label = "Battle Shout", spellID = 6673  },  -- Battle Shout
}

-- Classes for the Rend rule cycler (all nine) and the Battle Shout cycler
-- (melee/hunter only, per spec §2).
local REND_CLASSES = { "WARRIOR", "PALADIN", "HUNTER", "ROGUE", "PRIEST", "SHAMAN", "MAGE", "WARLOCK", "DRUID" }
local BS_CLASSES   = { "WARRIOR", "ROGUE", "HUNTER" }
local CLASS_LABEL  = {
    WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue",
    PRIEST = "Priest", SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", DRUID = "Druid",
}
-- Classic faction availability for faction-filtered class rows (Gossip buff-type).
local CLASS_FACTION = { PALADIN = "Alliance", SHAMAN = "Horde" }

-- Alert matrix keys (mirror store.ALERT_BUFF_KEYS / ALERT_EVENT_TYPES exactly).
local ALERT_BUFF_LABEL = {
    rend = "Rend", onyH = "Onyxia (Horde)", onyA = "Onyxia (Alliance)",
    nefH = "Nefarian (Horde)", nefA = "Nefarian (Alliance)",
    zg = "Zandalar", battleShout = "Battle Shout",
}
local ALERT_EVENT_LABEL = {
    questHandin = "Quest Hand-in", pullTimer = "Pull Timer", npcDied = "NPC Died",
    npcRespawned = "NPC Respawned", cdWarning = "CD Warning", cdExpired = "CD Expired",
    buffGain = "Buff Gain",
}

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

-- The four named per-event sound-key slots (store.timerSettings.soundKeys).
local SOUNDKEY_ROWS = {
    { key = "pullTimer",   label = "Pull Timer" },
    { key = "cdWarning",   label = "CD Warning" },
    { key = "npcDied",     label = "NPC Died" },
    { key = "npcRespawned", label = "NPC Respawned" },
}

-- Interact NPCs (spec §6 shipped set — all Alliance-city). Keyed to
-- factionSettings.autoInteract[key]. Faction-filtered at render.
local INTERACT_NPCS = {
    { key = "keldric", name = "Keldric Boucher",    faction = "Alliance", meta = "Reagents · Stormwind (Mage Quarter)" },
    { key = "jaxon",   name = "Auctioneer Jaxon",   faction = "Alliance", meta = "Auctioneer · Stormwind (Trade District)" },
    { key = "gunther", name = "Gunther Weller",     faction = "Alliance", meta = "Reagents · Stormwind (Mage Quarter)" },
    { key = "mangorn", name = "Mangorn Flinthammer", faction = "Alliance", meta = "Reagents · Ironforge (The Forlorn Cavern)" },
}

-- DMF Sayge fortune buff-types (spec §7 Gossip).
local DMF_BUFF_TYPES = {
    "damage", "agility", "intellect", "spirit", "stamina", "strength", "armor", "resistance",
}
local DMF_BUFF_TYPE_LABEL = {
    damage = "Damage", agility = "Agility", intellect = "Intellect", spirit = "Spirit",
    stamina = "Stamina", strength = "Strength", armor = "Armor", resistance = "Resistance",
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
    local r1 = sec:AddRow({ vAlign = "center" })
    register("general", r1:Checkbox({
        label = "Show minimap button",
        get = function() local db = DB(); return db and not db.minimap.hide end,
        set = function(v) local db = DB(); if db then db.minimap.hide = not v end end,
    }).Refresh)
    register("general", r1:Checkbox({
        label = "Lock button",
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

    -- Account ID with validation feedback.
    local acctRow = sec:AddRow({ vAlign = "center" })
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
    sec:Hint("A unique 1–2 digit number that keys this account on the mesh.")

    -- ── Data management ───────────────────────────────────────────────────────
    local dm = flow:AddSection("Data Management")
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

    -- ── Coordinate overrides (two-pane list + editor) ────────────────────────
    flow:AddSection("Coordinate Overrides")
    flow:Hint("Rules that relabel a character's location when they stand inside a zone box.")
    buildCoordPane(flow)

    -- ── Class colors ──────────────────────────────────────────────────────────
    flow:AddSection("Class Colors")
    buildClassColors(flow)
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
            dst.autoInteract = clone(src.autoInteract)
            -- auraOpts.thresholds preserved; Rend/BS rules copy (they are class rules,
            -- not thresholds).
            dst.auraOpts.rend = clone(src.auraOpts.rend)
            dst.auraOpts.battleShout = clone(src.auraOpts.battleShout)
            ns:Print(from .. " → " .. to .. " copied.")
            refreshPage("general")
        end,
    })
end

-- Two-pane coordinate-override editor (list left, fields right).
function buildCoordPane(flow)
    local UI = DaseekiUI
    local split = CreateFrame("Frame", nil, flow.pane.child)
    local leftCol  = UI.CreateColumn(split)
    local rightCol = UI.CreateColumn(split)
    local L, R = leftCol.flow, rightCol.flow

    local list = L:List({
        height = 150,
        items = function()
            local out = {}
            for i, rule in ipairs(coordList()) do
                out[#out + 1] = { text = (rule.label or rule.name or ("Rule " .. i)), value = i, status = "faint" }
            end
            if #out == 0 then out[#out + 1] = { header = true, text = "NO RULES" } end
            return out
        end,
        selected = coord.selected,
        onSelect = function(i) coord.selected = i; refreshPage("general") end,
    })
    coord._list = list

    local addRow = L:AddRow()
    addRow:Button({ text = "Add", width = 71, onClick = function()
        local rules = coordList()
        if #rules >= 15 then ns:Print("coordinate override limit is 15."); return end
        rules[#rules + 1] = { name = "New Rule", zone = "", label = "New Rule",
                              minX = 0, maxX = 0, minY = 0, maxY = 0 }
        coord.selected = #rules
        refreshPage("general")
    end })
    addRow:Button({ text = "Reset", width = 71, variant = "danger", onClick = function()
        UI.Confirm({ title = "Reset Coordinate Overrides", danger = true,
            text = "Restore the default coordinate override rules? Your custom rules are removed.",
            acceptText = "Reset",
            onAccept = function()
                local db = DB(); if not db then return end
                db.coordinateOverrides = {
                    { name = "Rend North Staging", zone = "Orgrimmar", minX = 0.30, maxX = 0.55, minY = 0.55, maxY = 0.80, label = "Rend Staging (N)" },
                    { name = "Rend South Staging", zone = "Durotar",   minX = 0.40, maxX = 0.60, minY = 0.10, maxY = 0.30, label = "Rend Staging (S)" },
                    { name = "DMF Mulgore",        zone = "Mulgore",   minX = 0.30, maxX = 0.50, minY = 0.55, maxY = 0.75, label = "Darkmoon Faire" },
                }
                coord.selected = nil
                refreshPage("general")
            end })
    end })

    -- Right editor (plain flow rows so every field + both buttons reflow and are
    -- never clipped — an EditorCard's fixed-height noBar pane would crop the last row).
    R:AddSection("Rule")
    local function rule() local r = coordList(); return coord.selected and r[coord.selected] or nil end
    local function field(label, key, numeric)
        local row = R:AddRow({ vAlign = "center" })
        row:Label(label)
        local box = row:EditBox({
            width = 120, numeric = numeric,
            get = function() local ru = rule(); if not ru then return "" end
                  local v = ru[key]; if numeric then return v and tostring(v) or "" end; return v or "" end,
            set = function(v) local ru = rule(); if not ru then return end
                  if numeric then ru[key] = tonumber(v) or 0 else ru[key] = v end
                  if key == "label" and coord._list then coord._list:Rebuild() end end,
        })
        box._fillWidth = false
        return box
    end
    coord._fields = {
        field("Label", "label", false),
        field("Name", "name", false),
        field("Zone", "zone", false),
        field("Min X", "minX", true),
        field("Max X", "maxX", true),
        field("Min Y", "minY", true),
        field("Max Y", "maxY", true),
    }
    local actRow = R:AddRow()
    actRow:Button({ text = "Here", width = 90, onClick = function()
        local ru = rule(); if not ru then ns:Print("select a rule first."); return end
        local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
        local pos = mapID and C_Map.GetPlayerMapPosition and C_Map.GetPlayerMapPosition(mapID, "player")
        if not pos then ns:Print("could not read your position here."); return end
        local x, y = pos:GetXY()
        local tol = 0.02
        ru.minX, ru.maxX = x - tol, x + tol
        ru.minY, ru.maxY = y - tol, y + tol
        local info = mapID and C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
        if info and info.name then ru.zone = info.name end
        refreshPage("general")
    end })
    actRow:Button({ text = "Delete", width = 90, variant = "danger", pin = "right", onClick = function()
        if not coord.selected then return end
        table.remove(coordList(), coord.selected)
        coord.selected = nil
        refreshPage("general")
    end })

    register("general", function()
        if coord._list then coord._list:SetSelected(coord.selected) end
        for _, f in ipairs(coord._fields or {}) do if f.Refresh then f.Refresh() end end
    end)

    local SPLIT_LEFT, SPLIT_GAP, SPLIT_MIN = 300, 16, 640
    split.arrange = function(width)
        split:SetWidth(width)
        if width >= SPLIT_MIN then
            local lw = SPLIT_LEFT
            local rw = math.max(1, width - lw - SPLIT_GAP)
            local lh = leftCol:Layout(lw)
            local rh = rightCol:Layout(rw)
            leftCol.frame:ClearAllPoints(); leftCol.frame:SetPoint("TOPLEFT", split, "TOPLEFT", 0, 0)
            rightCol.frame:ClearAllPoints(); rightCol.frame:SetPoint("TOPLEFT", split, "TOPLEFT", lw + SPLIT_GAP, 0)
            local total = math.max(lh, rh); split:SetHeight(math.max(total, 1)); return total
        else
            local lh = leftCol:Layout(width)
            local rh = rightCol:Layout(width)
            leftCol.frame:ClearAllPoints(); leftCol.frame:SetPoint("TOPLEFT", split, "TOPLEFT", 0, 0)
            rightCol.frame:ClearAllPoints(); rightCol.frame:SetPoint("TOPLEFT", split, "TOPLEFT", 0, -(lh + SPLIT_GAP))
            local total = lh + SPLIT_GAP + rh; split:SetHeight(math.max(total, 1)); return total
        end
    end
    flow.pane:AddBlock(split, split.arrange, 10, 0)
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
        local function paint()
            local db = DB(); local hex = db and db.classColors[class] or DEFAULTS[class]
            sw:SetBackdropColor(hexToRGB(hex))
        end
        row._items[#row._items + 1] = { w = sw }
        row:Label(CLASS_LABEL[class] or class)
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
    flow:Hint("The channel is derived automatically from your token — every account that shares the token meets on the same hidden channel.")

    -- Token field (masked, eye reveal, validation).
    local tokRow = flow:AddRow({ vAlign = "center" })
    tokRow:Label("Token")
    local revealed = { on = false }
    local tokStatus
    local function tokenText()
        local db = DB(); local t = (db and db.mesh.token) or ""
        if revealed.on then return t end
        return (t ~= "" and string.rep("*", #t)) or ""
    end
    local tokBox = tokRow:EditBox({
        width = 160,
        get = function() return tokenText() end,
        set = function(v)
            local db = DB(); if not db then return end
            v = tostring(v or ""):gsub("%s", "")
            -- Only commit when the field holds real (revealed) input, not the mask.
            if v:match("^%*+$") then return end
            db.mesh.token = v
            if tokStatus then
                local okLen = (#v == 6 and v:match("^%w+$"))
                tokStatus._label:SetText(okLen and "|cff66dd66valid|r" or (v == "" and "" or "|cffddaa44needs 6 alphanumerics|r"))
            end
        end,
    })
    tokBox._fillWidth = false
    tokRow:Button({ text = "Eye", width = 44, variant = "quiet", onClick = function()
        revealed.on = not revealed.on
        if tokBox.Refresh then tokBox.Refresh() end
    end })
    tokStatus = tokRow:Label("")

    -- Enable toggle — WIRED to StartJoinSequence / OnDisable.
    local enRow = flow:AddRow({ vAlign = "center" })
    register("mesh", enRow:Checkbox({
        label = "Enable mesh",
        get = function() local db = DB(); return db and db.mesh.enabled end,
        set = function(v)
            local db = DB(); if not db then return end
            db.mesh.enabled = v and true or false
            if not ns.Mesh then return end
            if v then
                if ns.Mesh.StartJoinSequence then ns:SafeCall(ns.Mesh.StartJoinSequence) end
                ns:Print("mesh enabled — joining channel.")
            else
                if ns.Mesh.OnDisable then ns:SafeCall(ns.Mesh.OnDisable) end
                ns:Print("mesh disabled — left channel.")
            end
        end,
    }).Refresh)
    register("mesh", enRow:Checkbox({
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

    local capLabel = flow:Label("Mesh capacity: 1 / " .. MESH_CAP)
    register("mesh", function()
        capLabel._label:SetText("Mesh capacity: " .. math.min(MESH_CAP, math.max(1, knownAccountCount())) .. " / " .. MESH_CAP)
    end)

    -- ── Active accounts table ─────────────────────────────────────────────────
    flow:AddSection("Active Accounts")
    buildAccountsTable(flow)

    -- ── Tombstones ────────────────────────────────────────────────────────────
    flow:AddSection("Removed Accounts (14-day block)")
    buildTombstonesTable(flow)
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
            if isSelf then row.status:SetText("|cff66dd66You|r")
            elseif peer and peer.online then row.status:SetText("|cff66dd66Online|r")
            else row.status:SetText("|cff888888Offline|r") end
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
    factionHeader(flow, "auras")

    -- ── Threshold table (Aura · Normal · Minimum, in minutes) ────────────────
    flow:AddSection("Duration Thresholds")
    flow:Hint("Minutes remaining below which a buff turns yellow (Normal) then red (Minimum).")

    -- Column header row.
    local hdr = flow:AddRow()
    local hAura = hdr:Label("Aura"); hAura.uiWidth = 190; hAura:SetWidth(190)
    hdr:Label("Normal (min)", { muted = true })
    hdr:Label("Minimum (min)", { muted = true })

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
            width = 70, numeric = true,
            get = function() local t = thr(); local v = t and t.normal; return v and tostring(math.floor(v / 60)) or "" end,
            set = function(v) local t = thr(); if t then t.normal = (tonumber(v) or 0) * 60 end end,
        })
        nBox._fillWidth = false
        local mBox = row:EditBox({
            width = 70, numeric = true,
            get = function() local t = thr(); local v = t and t.minimum; return v and tostring(math.floor(v / 60)) or "" end,
            set = function(v) local t = thr(); if t then t.minimum = (tonumber(v) or 0) * 60 end end,
        })
        mBox._fillWidth = false
        register("auras", function() if nBox.Refresh then nBox.Refresh() end; if mBox.Refresh then mBox.Refresh() end end)
    end

    -- ── Rend / Battle Shout class rules (cycling buttons) ─────────────────────
    buildClassRuleGrid(flow, "Rend — Required Classes", "rend", REND_CLASSES)
    buildClassRuleGrid(flow, "Battle Shout — Required Classes", "battleShout", BS_CLASSES)
end

-- A grid of cycling buttons: each class steps Required → Optional → Ignored.
-- State lives in FS().auraOpts[optKey].{required,optional,ignored}[class].
function buildClassRuleGrid(flow, title, optKey, classes)
    local UI = DaseekiUI
    flow:AddSection(title)
    flow:Hint("Required = red when missing · Optional = yellow · Ignored = hidden.")

    local STATES = { "required", "optional", "ignored" }
    local STATE_LABEL = { required = "Required", optional = "Optional", ignored = "Ignored" }
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

    local perRow, i = 3, 0
    local row
    for _, class in ipairs(classes) do
        if i % perRow == 0 then row = flow:AddRow() end
        i = i + 1
        local btn = row:Button({
            width = 150,
            text = (CLASS_LABEL[class] or class) .. ": " .. STATE_LABEL[getState(class)],
        })
        local function paint() btn._label:SetText((CLASS_LABEL[class] or class) .. ": " .. STATE_LABEL[getState(class)]) end
        btn:SetScript("OnClick", function() setState(class, nextState(getState(class))); paint() end)
        register("auras", paint)
    end
end

----------------------------------------------------------------------
-- 4. AUTOMATION  (Group / Accept Summon / Gossip / Quest / Interact)
----------------------------------------------------------------------

local function buildAutomation(flow)
    local UI = DaseekiUI
    local DS = _G.DaseekiSuite
    factionHeader(flow, "automation")

    -- ── Group ─────────────────────────────────────────────────────────────────
    local grp = flow:AddSection("Group")
    grp:Label("Auto-accept invites from", { muted = true })
    local function grpCheck(container, label, key)
        register("automation", container:Checkbox({
            label = label,
            get = function() local fs = FS(); return fs and fs.autoGroup[key] end,
            set = function(v) local fs = FS(); if fs then fs.autoGroup[key] = v and true or false end end,
        }).Refresh)
    end
    local ga = grp:AddRow({ vAlign = "center" })
    grpCheck(ga, "Known roster", "acceptFromRoster")
    grpCheck(ga, "Guild", "acceptFromGuild")
    local gb = grp:AddRow({ vAlign = "center" })
    grpCheck(gb, "Friends & BNet", "acceptFromFriends")
    grpCheck(gb, "Anyone", "acceptFromAnyone")

    local kw = grp:AddRow({ vAlign = "center" })
    register("automation", kw:Checkbox({
        label = "Auto-invite on whisper keyword",
        get = function() local fs = FS(); return fs and fs.autoGroup.sendToRoster end,
        set = function(v) local fs = FS(); if fs then fs.autoGroup.sendToRoster = v and true or false end end,
    }).Refresh)
    local kwBox = kw:EditBox({
        width = 90,
        get = function() local fs = FS(); return fs and fs.autoGroup.inviteKeyword or "" end,
        set = function(v) local fs = FS(); if fs then fs.autoGroup.inviteKeyword = tostring(v or ""):gsub("%s", "") end end,
    })
    kwBox._fillWidth = false
    register("automation", function() if kwBox.Refresh then kwBox.Refresh() end end)

    -- Invite whitelist (multi-line via text dialog; bypasses gates both ways).
    local wlRow = grp:AddRow({ vAlign = "center" })
    local wlLabel = wlRow:Label("Whitelist: 0 entries")
    wlRow:Button({ text = "Edit list…", width = 100, pin = "right", onClick = function()
        local fs = FS(); if not fs then return end
        DS.ShowTextDialog("Invite Whitelist (one Name-Realm per line)", mapToLines(fs.autoGroup.whitelist), false, function(txt)
            fs.autoGroup.whitelist = linesToMap(txt)
            refreshPage("automation")
        end)
    end })
    register("automation", function()
        local fs = FS(); wlLabel._label:SetText("Whitelist: " .. countMap(fs and fs.autoGroup.whitelist) .. " entries")
    end)

    -- ── Accept Summon ──────────────────────────────────────────────────────────
    local asx = flow:AddSection("Accept Summon")
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
    win:Label("Fresh-buff window (s)")
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
    register("automation", function() if winBox.Refresh then winBox.Refresh() end end)

    asx:Label("Accept when one of these buffs is freshly gained", { muted = true })
    local trigItems = {}
    for _, def in ipairs(AURA_DEFS) do
        trigItems[#trigItems + 1] = {
            label = def.label,
            get = function() local fs = FS(); return fs and fs.autoSummon.triggers[def.key] end,
            set = function(v) local fs = FS(); if fs then fs.autoSummon.triggers[def.key] = v and true or nil end end,
        }
    end
    local trigGrid = asx:AddChecklist(trigItems)
    register("automation", function() for _, b in ipairs(trigGrid._boxes) do b:Refresh() end end)

    -- ── Gossip ─────────────────────────────────────────────────────────────────
    local gos = flow:AddSection("Gossip")
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
    gos:Hint("Sayge's fortunes are permanent for the day — choose the per-class buff carefully.")

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

    local zr = q:AddRow({ vAlign = "center" })
    register("automation", zr:Checkbox({
        label = "Zanza buffs",
        get = function() local fs = FS(); return fs and fs.autoQuest.zanza.enabled end,
        set = function(v) local fs = FS(); if fs then fs.autoQuest.zanza.enabled = v and true or false end end,
    }).Refresh)
    -- Zanza pick membership (priority list). Order fixed; membership toggled.
    local function pickIndex(list, key) for i, k in ipairs(list or {}) do if k == key then return i end end return nil end
    for _, pick in ipairs(ZANZA_PICKS) do
        register("automation", zr:Checkbox({
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

    -- ── Interact ───────────────────────────────────────────────────────────────
    local ix = flow:AddSection("Interact Buttons")
    ix:Hint("Per-NPC secure click-to-target buttons appear only near each NPC's location.")
    local emptyHint = ix:Label("")
    for _, npc in ipairs(INTERACT_NPCS) do
        local row = ix:AddRow({ vAlign = "center" })
        local cb = row:Checkbox({
            label = npc.name,
            get = function() local fs = FS(); return fs and fs.autoInteract[npc.key] end,
            set = function(v) local fs = FS(); if fs then fs.autoInteract[npc.key] = v and true or nil end end,
        })
        row:Label(npc.meta, { muted = true })
        local blk = ix.pane.blocks[#ix.pane.blocks]
        local origArrange = blk.arrange
        blk.arrange = function(width)
            if npc.faction and npc.faction ~= scope.faction then row:Hide(); return 0 end
            row:Show(); return origArrange(width)
        end
        blk._baseGap = blk.topGap
        register("automation", function()
            blk.topGap = (npc.faction and npc.faction ~= scope.faction) and 0 or blk._baseGap
            if cb.Refresh then cb:Refresh() end
        end)
    end
    register("automation", function()
        local anyShown = false
        for _, npc in ipairs(INTERACT_NPCS) do if not npc.faction or npc.faction == scope.faction then anyShown = true end end
        emptyHint._label:SetText(anyShown and "" or ("No Interact NPCs registered for " .. scope.faction .. "."))
    end)
end

----------------------------------------------------------------------
-- 5. TIMERS & ALERTS
----------------------------------------------------------------------

local alertSel = { buff = "rend" }

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

    -- ── Alert matrix (buff selector + per-event channel rows) ─────────────────
    flow:AddSection("Alert Matrix")
    flow:Hint("Pick a buff, then set which channels each event fires. Test previews one cell.")
    local buffChoices = {}
    for _, k in ipairs(ns.Store.ALERT_BUFF_KEYS) do buffChoices[#buffChoices + 1] = { value = k, text = ALERT_BUFF_LABEL[k] or k } end
    local selRow = flow:AddRow({ vAlign = "center" })
    selRow:Label("Buff")
    local selDD = selRow:Dropdown({
        width = 180, choices = buffChoices,
        get = function() return alertSel.buff end,
        set = function(v) alertSel.buff = v; refreshPage("timers") end,
    })
    register("timers", function() if selDD.Refresh then selDD.Refresh() end end)

    -- Column header.
    local mh = flow:AddRow()
    local mhE = mh:Label("Event"); mhE.uiWidth = 150; mhE:SetWidth(150)
    mh:Label("Scrn", { muted = true }); mh:Label("Chat", { muted = true })
    mh:Label("Flash", { muted = true }); mh:Label("Snd", { muted = true })

    for _, evt in ipairs(ns.Store.ALERT_EVENT_TYPES) do
        local row = flow:AddRow({ vAlign = "center" })
        local lbl = row:Label(ALERT_EVENT_LABEL[evt] or evt); lbl.uiWidth = 138; lbl:SetWidth(138)
        local function cell(chan)
            local function m() local ts = TS(); if not ts then return nil end
                ts.alerts[alertSel.buff] = ts.alerts[alertSel.buff] or {}
                ts.alerts[alertSel.buff][evt] = ts.alerts[alertSel.buff][evt] or {}
                return ts.alerts[alertSel.buff][evt] end
            local cb = row:Checkbox({
                get = function() local c = m(); return c and c[chan] end,
                set = function(v) local c = m(); if c then c[chan] = v and true or false end end,
            })
            register("timers", function() if cb.Refresh then cb:Refresh() end end)
        end
        cell("notify"); cell("chat"); cell("flash"); cell("sound")
        row:Button({ text = "Test", width = 56, variant = "quiet", pin = "right", onClick = function()
            hudTestAlert(alertSel.buff, evt)
        end })
    end

    -- ── Sounds ─────────────────────────────────────────────────────────────────
    local snd = flow:AddSection("Sounds")
    local scRow = snd:AddRow({ vAlign = "center" })
    scRow:Label("Sound channel")
    local scDD = scRow:Dropdown({
        width = 140, choices = SOUND_CHANNELS,
        get = function() local ts = TS(); return ts and ts.soundChannel or "Master" end,
        set = function(v) local ts = TS(); if ts then ts.soundChannel = v end end,
    })
    register("timers", function() if scDD.Refresh then scDD.Refresh() end end)

    for _, sk in ipairs(SOUNDKEY_ROWS) do
        local row = snd:AddRow({ vAlign = "center" })
        local lbl = row:Label(sk.label); lbl.uiWidth = 120; lbl:SetWidth(120)
        local dd = row:Dropdown({
            width = 150, choices = soundChoices(),
            get = function() local ts = TS(); return ts and ts.soundKeys[sk.key] or "" end,
            set = function(v) local ts = TS(); if ts then ts.soundKeys[sk.key] = v end end,
        })
        row:Button({ text = "Test", width = 56, variant = "quiet", onClick = function()
            local ts = TS(); if not ts then return end
            local id, member = soundIdForKey(ts.soundKeys[sk.key] or "")
            id = (SOUNDKIT and member and SOUNDKIT[member]) or id
            if id and PlaySound then PlaySound(id, ts.soundChannel or "Master") end
        end })
        register("timers", function() if dd.Refresh then dd.Refresh() end end)
    end

    -- ── Pull-timer bars ────────────────────────────────────────────────────────
    local pb = flow:AddSection("Pull Timer Bars")
    local pbr = pb:AddRow({ vAlign = "center" })
    register("timers", pbr:Checkbox({
        label = "Lock bars",
        get = function() local ts = TS(); return ts and ts.pullBar.locked end,
        set = function(v) local ts = TS(); if ts then ts.pullBar.locked = v and true or false end end,
    }).Refresh)
    pbr:Button({ text = "Move Pull Timers", width = 150, pin = "right", onClick = hudShowMover })

    local pw = pb:Slider({
        label = "Bar width", width = 260, min = 100, max = 400, step = 5,
        get = function() local ts = TS(); return ts and ts.pullBar.width or 220 end,
        set = function(v) local ts = TS(); if ts then ts.pullBar.width = v end end,
        format = function(v) return tostring(math.floor(v)) end,
    })
    local ph = pb:Slider({
        label = "Bar height", width = 260, min = 10, max = 40, step = 1,
        get = function() local ts = TS(); return ts and ts.pullBar.height or 18 end,
        set = function(v) local ts = TS(); if ts then ts.pullBar.height = v end end,
        format = function(v) return tostring(math.floor(v)) end,
    })
    -- Idle/small-bar geometry + expand trigger — the HUD's actual runtime keys
    -- (hud.lua reads pullBar.smallWidth/smallHeight/expandThreshold). Main/small
    -- positions are mover-managed (mainPos/smallPos), so no controls for those.
    local psw = pb:Slider({
        label = "Small bar width", width = 260, min = 80, max = 320, step = 5,
        get = function() local ts = TS(); return ts and ts.pullBar.smallWidth or 158 end,
        set = function(v) local ts = TS(); if ts then ts.pullBar.smallWidth = v end end,
        format = function(v) return tostring(math.floor(v)) end,
    })
    local psh = pb:Slider({
        label = "Small bar height", width = 260, min = 8, max = 32, step = 1,
        get = function() local ts = TS(); return ts and ts.pullBar.smallHeight or 14 end,
        set = function(v) local ts = TS(); if ts then ts.pullBar.smallHeight = v end end,
        format = function(v) return tostring(math.floor(v)) end,
    })
    local pex = pb:Slider({
        label = "Expand-to-center threshold", width = 260, min = 3, max = 30, step = 1,
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
    local wps = fw:Slider({
        label = "World map pin size", width = 260, min = 8, max = 24, step = 1,
        get = function() local ts = TS(); return ts and ts.felwood.worldPinSize or 14 end,
        set = function(v) local ts = TS(); if ts then ts.felwood.worldPinSize = v end end,
        format = function(v) return tostring(math.floor(v)) end,
    })
    local mps = fw:Slider({
        label = "Minimap pin size", width = 260, min = 8, max = 24, step = 1,
        get = function() local ts = TS(); return ts and ts.felwood.minimapPinSize or 12 end,
        set = function(v) local ts = TS(); if ts then ts.felwood.minimapPinSize = v end end,
        format = function(v) return tostring(math.floor(v)) end,
    })
    register("timers", function() if wps.Refresh then wps.Refresh() end; if mps.Refresh then mps.Refresh() end end)

    -- ── Songflower display ───────────────────────────────────────────────────────
    -- Drives the Timers-tab UP?/minus state machine (timers.lua NodeState).
    local sf = flow:AddSection("Songflower Display")
    sf:Hint("Minus-timer counts the respawn; UP? window shows after respawn (0 = always).")
    local sfMinus = sf:Slider({
        label = "Minus-timer duration", width = 300, min = 300, max = 3000, step = 30,
        get = function() local ts = TS(); return ts and ts.felwood.flowerMinusDuration or 1500 end,
        set = function(v) local ts = TS(); if ts then ts.felwood.flowerMinusDuration = v end end,
        format = function(v) v = math.floor(v); return ("%d:%02d"):format(math.floor(v / 60), v % 60) end,
    })
    local sfUp = sf:Slider({
        label = "UP? duration", width = 300, min = 0, max = 3600, step = 30,
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

    local sec = flow:AddSection("Roster Filtering")
    sec:Hint("Blacklisted characters hide from 60s / Summoners (still visible in Online). Whitelist un-hides across the mesh.")

    -- Blacklist list.
    local blRow = sec:AddRow({ vAlign = "center" })
    local blLabel = blRow:Label("Blacklist: 0 entries")
    blRow:Button({ text = "Edit blacklist…", width = 130, pin = "right", onClick = function()
        local db = DB(); if not db then return end
        db.ui.blacklist = db.ui.blacklist or {}
        DS.ShowTextDialog("Blacklist (one Name-Realm per line)", mapToLines(db.ui.blacklist), false, function(txt)
            db.ui.blacklist = linesToMap(txt); refreshPage("blacklist")
        end)
    end })

    local wlRow = sec:AddRow({ vAlign = "center" })
    local wlLabel = wlRow:Label("Whitelist: 0 entries")
    wlRow:Button({ text = "Edit whitelist…", width = 130, pin = "right", onClick = function()
        local db = DB(); if not db then return end
        db.ui.whitelist = db.ui.whitelist or {}
        DS.ShowTextDialog("Whitelist (one Name-Realm per line)", mapToLines(db.ui.whitelist), false, function(txt)
            db.ui.whitelist = linesToMap(txt); refreshPage("blacklist")
        end)
    end })
    register("blacklist", function()
        local db = DB()
        blLabel._label:SetText("Blacklist: " .. countMap(db and db.ui.blacklist) .. " entries")
        wlLabel._label:SetText("Whitelist: " .. countMap(db and db.ui.whitelist) .. " entries")
    end)

    sec:AddRow():Button({ text = "Sync Blacklist to Mesh", width = 200, onClick = function()
        if not (ns.Mesh and ns.Mesh.IsEnabled and ns.Mesh.IsEnabled()) then
            ns:Print("mesh is not enabled — nothing to sync."); return
        end
        local sent = 0
        for _, p in pairs(ns.Mesh.peers or {}) do
            if p.online and p.name and ns.Mesh.SendBlacklist then ns.Mesh.SendBlacklist(p.name); sent = sent + 1 end
        end
        ns:Print("blacklist sync sent to " .. sent .. " account(s).")
    end })

    -- ── Purge (danger, self-protected) ─────────────────────────────────────────
    local pz = flow:AddSection("Purge (danger)")
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

    local pcRow = pz:AddRow({ vAlign = "center" })
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
