--[[
    dev/extract-professions-facts.lua — DERIVE THE CHECKED-IN FACT SOURCE.

    WHY THIS EXISTS
    ---------------
    The professions module needs the game's recipe universe: which teaching
    spell exists, what skill it wants, which profession owns it, what gates it,
    and where a player gets it. Those are FACTS ABOUT THE GAME — spell ids, item
    ids, NPC ids, zone ids, coordinates, skill numbers, prices, reputation
    standings — not anybody's creative expression, and they are the deliverable
    per the suite's standing clean-room precedent (DBM encounters, Armory
    catalog).

    Our Room-1 reader already wrote them down: PROFESSIONS_DATASET_ADDENDUM.md
    carries the whole census as markdown fact tables in an invented vocabulary.
    This script is the one and only place that reads that document. It walks
    §9 (per-profession recipe + recipe-item tables) and §10 (the NPC, zone,
    quest, object, event, faction, specialisation and profession-rank indices),
    normalises every acquisition relation into one token grammar, applies the
    corrections in §4.10, and writes ONE checked-in artefact:

        dev/professions-facts.txt

    That file — not the addendum — is what the shipping generator consumes, and
    it is what a reviewer audits. The addendum is an INPUT that lives outside
    this repo; the fact source is IN it, so a regeneration is reproducible from
    the repo alone as long as nobody wants new facts.

    HOW TO RUN
        lua5.1 dev/extract-professions-facts.lua [ADDENDUM_PATH] [OUT_PATH]

    ADDENDUM_PATH  defaults to ../PROFESSIONS_DATASET_ADDENDUM.md relative to
                   the repo root (the suite workspace layout).
    OUT_PATH       defaults to <repo>/dev/professions-facts.txt.

    IT FAILS LOUDLY. Every acquisition token must be one this grammar knows;
    every name reference (zone, faction, standing, event, specialisation,
    profession) must resolve to an id. An unknown token or an unresolved name
    aborts with the source line number rather than silently dropping a fact —
    a dataset that quietly loses rows is exactly the failure mode §7 defect 24
    describes, and it is invisible once shipped.

    DETERMINISM. Every emitted section is sorted by a numeric key (profession
    order is the fixed list in PROF_ORDER; recipes and items sort by id). Two
    runs over the same addendum produce byte-identical output — the file is
    diffable, so a data change reads as a data change.

    CORRECTIONS APPLIED HERE (addendum §4.10, "confirmed data errors"), each
    marked in the output with a `!fix` line so the shipped dataset can assert
    them and a reader can see what we changed and why:

      FIX-1  Fishing (Artisan) is shipped in the examined data under the SAME
             spell id as Cooking (Artisan), 18260. That is a collision, not a
             game fact: the fishing artisan rank is its own spell, 18248.
             Provenance: the two ranks are separate trainable spells on a live
             1.15 client — a character with artisan cooking and no fishing book
             holds 18260 and not 18248, which is the observation that makes the
             shared id impossible.

      FIX-2  Two prose acquisition notes share one id and one text. Notes are
             INTERNED BY TEXT here, so the duplicate collapses structurally and
             cannot come back.

      FIX-3  Three blacksmithing plans (18769/18770/18771, the three
             "Enchanted Thorium Platemail" variants) carry no acquisition path
             of any kind. They are not sourceless in the game: they come out of
             the Thorium Brotherhood contract chain, whose contract item (18628)
             the examined data ships but never links. We link them with a `K`
             (contract/prerequisite item) relation plus a prose note. We do NOT
             invent quest ids we cannot verify — the relation we assert is the
             one the addendum states.

    WHAT IS DELIBERATELY NOT EXTRACTED: localized names of anything the client
    can resolve from an id. Recipe names come from GetSpellInfo(spell id) and
    recipe-item names from GetItemInfo(item id) at display time, in the player's
    own language, always current. English names are carried ONLY for entities
    the client cannot resolve from an id offline — NPCs, zones, quests, world
    objects, world events, reputation factions and standings, professions and
    specialisations, plus the prose acquisition notes. That single rule is what
    turns ~2.3 MB of shipped data into a ~100 KB file (addendum §3.5, §11).
]]

----------------------------------------------------------------------
-- Paths
----------------------------------------------------------------------

local function scriptDir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    local dir = src:match("^(.*)[/\\][^/\\]*$")
    return dir or "."
end

local DEV_DIR   = scriptDir()
local REPO_DIR  = DEV_DIR:match("^(.*)[/\\][^/\\]*$") or "."
local WORK_DIR  = REPO_DIR:match("^(.*)[/\\][^/\\]*$") or ".."

local ADDENDUM = arg[1] or (WORK_DIR .. "/PROFESSIONS_DATASET_ADDENDUM.md")
local OUT_PATH = arg[2] or (DEV_DIR .. "/professions-facts.txt")

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function die(msg, lineNo)
    io.stderr:write("extract-professions-facts: FATAL"
        .. (lineNo and (" (addendum line " .. lineNo .. ")") or "") .. ": " .. msg .. "\n")
    os.exit(1)
end

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- A markdown table row -> array of trimmed cells (leading/trailing pipes dropped).
local function cells(line)
    local out = {}
    -- keep empty fields; split on "|"
    local start = 1
    while true do
        local i = line:find("|", start, true)
        if not i then out[#out + 1] = line:sub(start) break end
        out[#out + 1] = line:sub(start, i - 1)
        start = i + 1
    end
    -- drop the empty head/tail produced by the leading/trailing pipe
    if trim(out[1]) == "" then table.remove(out, 1) end
    if #out > 0 and trim(out[#out]) == "" then table.remove(out, #out) end
    for i = 1, #out do out[i] = trim(out[i]) end
    return out
end

local function isDash(s)
    s = trim(s)
    return s == "" or s == "-" or s == "\226\128\148" or s == "\226\128\147"   -- em dash / en dash
end

-- "1g35s" / "2s50c" / "50c" / "0c" / "5g" -> copper. "—" -> nil.
local function copper(s)
    s = trim(s)
    if isDash(s) then return nil end
    local g = tonumber(s:match("(%d+)g")) or 0
    local si = tonumber(s:match("(%d+)s")) or 0
    local c = tonumber(s:match("(%d+)c")) or 0
    if g == 0 and si == 0 and c == 0 and not s:match("0[gsc]") then
        die("unparseable money value: " .. s)
    end
    return g * 10000 + si * 100 + c
end

-- "10–10", "40–41", "??–??", "—" -> lo, hi (nil when unknown)
local function band(s)
    s = trim(s)
    if isDash(s) then return nil, nil end
    local lo, hi = s:match("^(%S+)\226\128\147(%S+)$")          -- en dash
    if not lo then lo, hi = s:match("^(%S+)%-(%S+)$") end
    if not lo then lo, hi = s:match("^(%S+)\226\128\148(%S+)$") end -- em dash
    if not lo then return nil, nil end
    return tonumber(lo), tonumber(hi)
end

local function csvNums(s)
    local out = {}
    if isDash(s) then return out end
    for n in tostring(s):gmatch("%d+") do out[#out + 1] = tonumber(n) end
    return out
end

local function joinNums(t, sep)
    local parts = {}
    for i = 1, #t do parts[i] = tostring(t[i]) end
    return table.concat(parts, sep or "+")
end

----------------------------------------------------------------------
-- Fixed vocabulary
----------------------------------------------------------------------

-- Emission order for professions. Ten carry recipes; three (the gathering pair
-- plus fishing) carry rank tiers only. The order is FROZEN — the shipped
-- dataset's per-profession recipe indexes are the wire encoding's coordinate
-- system, so reordering this list re-numbers every bit of every published
-- bitmap. See the dataset version stamp.
local PROF_ORDER = {
    { key = "alchemy",        name = "Alchemy" },
    { key = "blacksmithing",  name = "Blacksmithing" },
    { key = "cooking",        name = "Cooking" },
    { key = "enchanting",     name = "Enchanting" },
    { key = "engineering",    name = "Engineering" },
    { key = "firstaid",       name = "First Aid" },
    { key = "leatherworking", name = "Leatherworking" },
    { key = "mining",         name = "Mining" },
    { key = "poisons",        name = "Poisons" },
    { key = "tailoring",      name = "Tailoring" },
    { key = "fishing",        name = "Fishing" },
    { key = "herbalism",      name = "Herbalism" },
    { key = "skinning",       name = "Skinning" },
}

local PROF_BY_NAME = {}
local PROF_IDX     = {}
for i, p in ipairs(PROF_ORDER) do
    PROF_BY_NAME[p.name] = i
    PROF_IDX[p.key] = i
end

-- Derived source classes (addendum §4 C.2). Bit values are the shipped mask.
local SRC_BIT = {
    trainer = 1, vendor = 2, drop = 4, quest = 8, object = 16, holiday = 32,
}
local SRC_GRANT = 64          -- our own explicit class (addendum deviation 43)

-- Reputation standings. The examined data models Neutral(4) upward only.
local STANDING = {
    Neutral = 4, Friendly = 5, Honored = 6, Revered = 7, Exalted = 8,
}

-- NPC faction stance, as a single letter in the shipped rows.
local STANCE = { Alliance = "A", Horde = "H", Neutral = "N", Hostile = "X" }

----------------------------------------------------------------------
-- Read the addendum
----------------------------------------------------------------------

local fh = io.open(ADDENDUM, "r")
if not fh then die("cannot open addendum: " .. ADDENDUM) end
local LINES = {}
for line in fh:lines() do LINES[#LINES + 1] = (line:gsub("\r$", "")) end
fh:close()

----------------------------------------------------------------------
-- Collected raw facts
----------------------------------------------------------------------

local recipes   = {}   -- [profIdx] = { {spell, skill, phase, specName, srcList, acqRaw, name, line}, ... }
local items     = {}   -- [profIdx] = { {item, quality, phase, acqRaw, name, line}, ... }
local trainerSets = {} -- [profIdx] = { [setIdx] = { npcIds } }
local npcs      = {}   -- [id] = { name, zoneName, x, y, stance, lmin, lmax, elite }
local npcOrder  = {}
local zones     = {}   -- [id] = { name, continent, lmin, lmax }
local zoneOrder = {}
local zoneByName = {}
local quests    = {}   -- [id] = { name, minLvl, givers }
local questOrder = {}
local objects   = {}   -- [id] = { name, zoneName, phase }
local objectOrder = {}
local events    = {}   -- [id] = name
local eventOrder = {}
local eventByName = {}
local factions  = {}   -- [id] = name
local factionOrder = {}
local factionByName = {}
local specs     = {}   -- ordered { id, name, profIdx, minSkill, quest }
local specByName = {}
local ranks     = {}   -- ordered { profIdx, tier, spell, floor, ceil, clvl, cost, trainers, item, quests }
local continents = { ["The Eastern Kingdoms"] = 1, ["Kalimdor"] = 2 }
local continentOrder = { "The Eastern Kingdoms", "Kalimdor" }

for i = 1, #PROF_ORDER do
    recipes[i], items[i], trainerSets[i] = {}, {}, {}
end

-- Prose acquisition notes, INTERNED BY TEXT (FIX-2).
local notes, noteByText = {}, {}
local function noteIndex(text)
    text = trim(text)
    if text == "" then die("empty SPECIAL note") end
    local idx = noteByText[text]
    if not idx then
        notes[#notes + 1] = text
        idx = #notes
        noteByText[text] = idx
    end
    return idx
end

----------------------------------------------------------------------
-- Section walk
----------------------------------------------------------------------

local section, curProf = nil, nil

local function isTableRow(line)
    if line:sub(1, 1) ~= "|" then return false end
    if line:match("^|%s*%-%-%-") then return false end
    return true
end

for ln = 1, #LINES do
    local line = LINES[ln]

    local h4 = line:match("^#### (.+)$")
    local h3 = line:match("^### (.+)$")
    local h2 = line:match("^## (.+)$")

    if h4 then
        local pname, kind = h4:match("^(.-) \226\128\148 (%a[%a%-]*)")
        if not pname then pname, kind = h4:match("^(.-) %- (%a[%a%-]*)") end
        if pname then
            local idx = PROF_BY_NAME[pname]
            if not idx then die("unknown profession heading: " .. h4, ln) end
            curProf = idx
            if h4:find("recipe%-items") then section = "items"
            elseif h4:find("recipes") then section = "recipes"
            else die("unknown §9 heading: " .. h4, ln) end
        end
    elseif h3 then
        curProf = nil
        if     h3:find("^Source%-NPC index")       then section = "npcs"
        elseif h3:find("^Zone index")              then section = "zones"
        elseif h3:find("^Quest index")             then section = "quests"
        elseif h3:find("^Reputation%-faction index") then section = "factions"
        elseif h3:find("^World%-object index")     then section = "objects"
        elseif h3:find("^Event %(holiday%) index") then section = "events"
        elseif h3:find("^Specialisation index")    then section = "specs"
        elseif h3:find("^Profession%-rank index")  then section = "ranks"
        else section = nil end
    elseif h2 then
        curProf = nil
        section = nil
    elseif line:find("^%*Trainer sets %(") then
        if not curProf then die("trainer-set line outside a profession block", ln) end
        local prof = line:match("^%*Trainer sets %((.-)%)")
        if PROF_BY_NAME[prof] ~= curProf then
            die("trainer-set line names " .. tostring(prof) .. " inside another block", ln)
        end
        for setName, body in line:gmatch("%*%*TS(%d+)%*%* %(%d+%): ([%d,]+)") do
            trainerSets[curProf][tonumber(setName)] = csvNums(body)
        end
    elseif isTableRow(line) and section then
        local c = cells(line)
        if section == "recipes" and tonumber(c[1]) then
            recipes[curProf][#recipes[curProf] + 1] = {
                spell = tonumber(c[1]), name = c[2], skill = tonumber(c[3]),
                phase = tonumber(c[4]), specName = c[5], src = c[6], acq = c[7], line = ln,
            }
        elseif section == "items" and tonumber(c[1]) then
            items[curProf][#items[curProf] + 1] = {
                item = tonumber(c[1]), name = c[2], quality = c[3],
                phase = tonumber(c[4]), acq = c[5], line = ln,
            }
        elseif section == "npcs" and tonumber(c[1]) then
            local id = tonumber(c[1])
            local xy = c[4]
            local x, y
            if not isDash(xy) then
                local xs, ys = xy:match("^%s*(%S+)%s*/%s*(%S+)%s*$")
                if xs and not isDash(xs) then x = tonumber(xs) end
                if ys and not isDash(ys) then y = tonumber(ys) end
            end
            local lmin, lmax = band(c[6])
            npcs[id] = {
                name = c[2], zoneName = c[3], x = x, y = y,
                stance = c[5], lmin = lmin, lmax = lmax,
                elite = (trim(c[7] or "") ~= ""), line = ln,
            }
            npcOrder[#npcOrder + 1] = id
        elseif section == "zones" and tonumber(c[1]) then
            local id = tonumber(c[1])
            local lmin, lmax = band(c[4])
            zones[id] = { name = c[2], continent = c[3], lmin = lmin, lmax = lmax, line = ln }
            zoneOrder[#zoneOrder + 1] = id
            if zoneByName[c[2]] then die("duplicate zone name: " .. c[2], ln) end
            zoneByName[c[2]] = id
            if not continents[c[3]] then
                continentOrder[#continentOrder + 1] = c[3]
                continents[c[3]] = #continentOrder
            end
        elseif section == "quests" and tonumber(c[1]) then
            local id = tonumber(c[1])
            quests[id] = { name = c[2], minLvl = tonumber(c[3]) or 0, givers = csvNums(c[4]), line = ln }
            questOrder[#questOrder + 1] = id
        elseif section == "objects" and tonumber(c[1]) then
            local id = tonumber(c[1])
            objects[id] = { name = c[2], zoneName = c[3], phase = tonumber(c[4]) or 1, line = ln }
            objectOrder[#objectOrder + 1] = id
        elseif section == "specs" and tonumber(c[1]) then
            local pIdx = PROF_BY_NAME[c[3]]
            if not pIdx then die("specialisation names unknown profession: " .. tostring(c[3]), ln) end
            specs[#specs + 1] = {
                id = tonumber(c[1]), name = c[2], prof = pIdx,
                minSkill = tonumber(c[4]) or 0, quest = tonumber(c[5]) or 0,
            }
            specByName[c[2]] = #specs
        elseif section == "ranks" and tonumber(c[1]) then
            local entry = c[2]
            local pname = entry:match("^(.-) %(") or entry
            local pIdx = PROF_BY_NAME[pname]
            if not pIdx then die("rank entry names unknown profession: " .. entry, ln) end
            ranks[#ranks + 1] = {
                spell = tonumber(c[1]), prof = pIdx, tier = tonumber(c[3]) or 1,
                floor = tonumber(c[4]) or 0, ceil = tonumber(c[5]) or 0,
                clvl = tonumber(c[6]) or 1, cost = copper(c[7]) or 0,
                trainers = csvNums(c[8]), item = (csvNums(c[9]))[1] or 0,
                quests = csvNums(c[10]), line = ln, entry = entry,
            }
        end
    elseif section == "factions" and line:find("\194\183") then
        -- "21 Booty Bay · 46 Blacksmithing - Armorsmithing · ..."
        for chunk in (line .. " \194\183"):gmatch("(.-)%s*\194\183%s*") do
            local id, nm = trim(chunk):match("^(%d+)%s+(.+)$")
            if id then
                factions[tonumber(id)] = nm
                factionOrder[#factionOrder + 1] = tonumber(id)
                factionByName[nm] = tonumber(id)
            end
        end
    elseif section == "events" and line:find("\194\183") then
        for chunk in (line .. " \194\183"):gmatch("(.-)%s*\194\183%s*") do
            local id, nm = trim(chunk):match("^(%d+)%s+(.+)$")
            if id then
                events[tonumber(id)] = nm
                eventOrder[#eventOrder + 1] = tonumber(id)
                eventByName[nm] = tonumber(id)
            end
        end
    end
end

----------------------------------------------------------------------
-- Corrections
----------------------------------------------------------------------

local FIXES = {}

-- FIX-1: the fishing artisan rank's spell id.
do
    local FISHING = PROF_IDX.fishing
    local COOKING = PROF_IDX.cooking
    local cookingArtisan
    for _, r in ipairs(ranks) do
        if r.prof == COOKING and r.tier == 4 then cookingArtisan = r.spell end
    end
    local patched = false
    for _, r in ipairs(ranks) do
        if r.prof == FISHING and r.tier == 4 and r.spell == cookingArtisan then
            r.spell = 18248
            patched = true
        end
    end
    if not patched then
        die("FIX-1 did not apply: the fishing artisan rank no longer collides with cooking's"
            .. " (the source data changed; re-verify before removing the fix)")
    end
    FIXES[#FIXES + 1] = { id = "FIX-1", what = "fishing-artisan-spell",
        was = cookingArtisan, now = 18248,
        why = "the examined data reuses the cooking artisan spell id for fishing; the fishing"
           .. " artisan rank is its own spell" }
end

-- FIX-3: the three sourceless blacksmithing plans.
local CONTRACT_ITEM = 18628
local CONTRACT_NOTE = "obtained through the Thorium Brotherhood contract chain"
local FIX3_ITEMS = { [18769] = true, [18770] = true, [18771] = true }
do
    local n = 0
    for pIdx = 1, #PROF_ORDER do
        for _, it in ipairs(items[pIdx]) do
            if FIX3_ITEMS[it.item] then
                if not it.acq:find("NO SOURCE") then
                    die("FIX-3 did not apply to item " .. it.item
                        .. ": it already carries a source (" .. it.acq .. ")", it.line)
                end
                it.fix3 = true
                n = n + 1
            end
        end
    end
    if n ~= 3 then die("FIX-3 expected 3 sourceless plans, found " .. n) end
    FIXES[#FIXES + 1] = { id = "FIX-3", what = "thorium-contract-plans",
        was = "no source", now = "K" .. CONTRACT_ITEM,
        why = "the contract item that grants them ships in the data but is never linked" }
end

FIXES[#FIXES + 1] = { id = "FIX-2", what = "duplicate-prose-note",
    was = "two note keys, one text", now = "interned by text",
    why = "notes are interned on their text here, so the duplicate cannot come back" }

-- FIX-4: the Blacksmithing specialisation tree is NESTED in the era client —
-- the examined data lists the ten specialisations flat. Armorsmith and
-- Weaponsmith sit under Blacksmithing, and the three Master smith specs
-- (Swordsmith / Hammersmith / Axesmith) sit UNDER Weaponsmith: becoming one
-- REQUIRES being a Weaponsmith, so a Master Axesmith IS a Weaponsmith. The
-- Engineering and Leatherworking specialisations are flat single-level and get
-- no parent. The edge is matched by the dataset's own spec NAMES and emitted
-- as a parent ORDINAL in a NEW seventh [spec] field (appending keeps every
-- existing six-field reader answering exactly as before). Consumed by the
-- profession-delegate lanes: a lane with no primary walks its parent chain.
do
    local PARENT_EDGES = {
        ["Master Swordsmith"]  = "Weaponsmith",
        ["Master Hammersmith"] = "Weaponsmith",
        ["Master Axesmith"]    = "Weaponsmith",
    }
    local n = 0
    for childName, parentName in pairs(PARENT_EDGES) do
        local ci, pi = specByName[childName], specByName[parentName]
        if not ci then die("FIX-4 did not apply: spec '" .. childName .. "' is not in the data") end
        if not pi then die("FIX-4 did not apply: parent spec '" .. parentName .. "' is not in the data") end
        if specs[ci].prof ~= specs[pi].prof then
            die("FIX-4 refused: '" .. childName .. "' and '" .. parentName
                .. "' belong to different professions")
        end
        specs[ci].parent = pi
        n = n + 1
    end
    if n ~= 3 then die("FIX-4 expected 3 parent edges, applied " .. n) end
    FIXES[#FIXES + 1] = { id = "FIX-4", what = "spec-parent-edges",
        was = "flat specialisation list", now = "3 Master smith specs parent to Weaponsmith",
        why = "the era Blacksmithing tree is nested (a Master smith IS a Weaponsmith);"
           .. " the delegate lanes walk this edge" }
end

----------------------------------------------------------------------
-- Acquisition token grammar
--
-- Every relation becomes one token; tokens are ";"-joined in id order within a
-- row. Ids inside a token are "+"-joined so the row's field separator, the
-- token separator and the id separator are three different bytes and none of
-- them can be confused for another.
--
--   T<copper>@<trainerSetIdx>   trainer-taught for that price from that set
--   I<itemId>                   taught by that recipe-item
--   Q<id>[+<id>]                taught by / obtained from those quests
--   O<id>                       obtained from that world object
--   R<factionId>/<standingId>   reputation gate
--   L<n>                        minimum character level (stored, per §4.2)
--   C<classKey>                 class restriction
--   G                           granted free when the profession is learned
--   S<noteIdx>                  prose acquisition note
--   V<copper>@<npc>[+<npc>]     sold by those vendors at that price
--   D<npc>[+<npc>]              dropped by those named mobs
--   W<lo>-<hi>                  undirected world drop, mob level band
--   E<eventId>                  world-event gated
--   K<itemId>                   granted via that contract/prerequisite item
--   X                           no acquisition path in the source data
----------------------------------------------------------------------

local function resolveFaction(name, ln)
    local id = factionByName[name]
    if not id then die("unknown reputation faction: " .. tostring(name), ln) end
    return id
end

local function resolveStanding(name, ln)
    local id = STANDING[name]
    if not id then die("unknown reputation standing: " .. tostring(name), ln) end
    return id
end

local function parseAcq(raw, ln, isItem, row)
    local tokens = {}
    local flags  = {}
    raw = trim(raw)
    if raw == "" then die("empty acquisition column", ln) end

    for part in (raw .. ";"):gmatch("(.-);") do
        part = trim(part)
        if part ~= "" then
            local head = part:match("^(%S+)")
            if part:find("^SPECIAL:") then
                tokens[#tokens + 1] = "S" .. noteIndex(part:match("^SPECIAL:%s*(.+)$"))
            elseif head == "TR" then
                local cost, set = part:match("^TR%s+(%S+)%s+@TS(%d+)$")
                if not cost then die("unparseable TR token: " .. part, ln) end
                tokens[#tokens + 1] = "T" .. tostring(copper(cost) or 0) .. "@" .. set
            elseif head == "ITEM" then
                tokens[#tokens + 1] = "I" .. part:match("^ITEM%s+(%d+)$")
            elseif head == "QUEST" then
                local ids = csvNums(part)
                if #ids == 0 then die("QUEST token with no ids: " .. part, ln) end
                tokens[#tokens + 1] = "Q" .. joinNums(ids)
            elseif head == "OBJ" then
                tokens[#tokens + 1] = "O" .. joinNums(csvNums(part))
            elseif head == "REP" then
                local fac, st = part:match("^REP%s+(.-)/(%S+)$")
                if not fac then die("unparseable REP token: " .. part, ln) end
                tokens[#tokens + 1] = "R" .. resolveFaction(trim(fac), ln)
                    .. "/" .. resolveStanding(trim(st), ln)
            elseif head == "CLVL" then
                tokens[#tokens + 1] = "L" .. part:match("(%d+)")
            elseif head == "CLASS" then
                tokens[#tokens + 1] = "C" .. trim(part:match("^CLASS%s+(.+)$")):lower()
            elseif part == "GRANT-ON-LEARN" then
                tokens[#tokens + 1] = "G"
                flags.grant = true
            elseif head == "VEND" then
                local cost, ids = part:match("^VEND%s+(%S+)%s+from%s+([%d,]+)$")
                if not cost then die("unparseable VEND token: " .. part, ln) end
                tokens[#tokens + 1] = "V" .. tostring(copper(cost) or 0) .. "@" .. joinNums(csvNums(ids))
            elseif head == "DROP" then
                tokens[#tokens + 1] = "D" .. joinNums(csvNums(part))
            elseif head == "WORLD-DROP" then
                local lo, hi = band(part:match("lvl%s+(%S+)"))
                if not lo then die("unparseable WORLD-DROP band: " .. part, ln) end
                tokens[#tokens + 1] = "W" .. lo .. "-" .. hi
                flags.worldDrop = true
            elseif head == "EVENT" then
                local nm = trim(part:match("^EVENT%s+(.+)$"))
                local id = eventByName[nm]
                if not id then die("unknown world event: " .. nm, ln) end
                tokens[#tokens + 1] = "E" .. id
                flags.event = true
            elseif part:find("NO SOURCE") then
                if row and row.fix3 then
                    tokens[#tokens + 1] = "K" .. CONTRACT_ITEM
                    tokens[#tokens + 1] = "S" .. noteIndex(CONTRACT_NOTE)
                    flags.fixed = true
                else
                    tokens[#tokens + 1] = "X"
                    flags.noSource = true
                end
            else
                die("unknown acquisition token: " .. part, ln)
            end
        end
    end
    if #tokens == 0 then die("acquisition column produced no tokens: " .. raw, ln) end
    table.sort(tokens)
    return table.concat(tokens, ";"), flags
end

----------------------------------------------------------------------
-- Resolve, validate, and build the emission model
----------------------------------------------------------------------

-- Zone index positions (1-based, in zone-id order) so NPC/object rows can carry
-- a small ordinal instead of repeating the zone id.
table.sort(zoneOrder)
local zoneIdxById = {}
for i, id in ipairs(zoneOrder) do zoneIdxById[id] = i end

local function zoneIdxByName(name, ln)
    local id = zoneByName[name]
    if not id then die("NPC/object names a zone the zone index does not carry: " .. tostring(name), ln) end
    return zoneIdxById[id]
end

table.sort(npcOrder)
table.sort(questOrder)
table.sort(objectOrder)
table.sort(factionOrder)
table.sort(eventOrder)

-- Recipes and recipe-items sort by id inside their profession. THIS ORDER IS
-- THE WIRE COORDINATE SYSTEM for the known-recipe bitmap.
for p = 1, #PROF_ORDER do
    table.sort(recipes[p], function(a, b) return a.spell < b.spell end)
    table.sort(items[p],   function(a, b) return a.item  < b.item  end)
end

-- Referential integrity: every id a relation names must resolve.
local referencedItems, referencedNpcs = {}, {}
local census = { recipes = 0, items = 0, grant = 0, noSource = 0, worldDrop = 0, event = 0 }

local rowsR, rowsI = {}, {}

for p = 1, #PROF_ORDER do
    for _, r in ipairs(recipes[p]) do
        local specIdx = 0
        if not isDash(r.specName) then
            specIdx = specByName[r.specName]
            if not specIdx then die("recipe names unknown specialisation: " .. r.specName, r.line) end
        end
        local mask = 0
        for atom in (r.src .. "+"):gmatch("(.-)%+") do
            atom = trim(atom)
            if atom ~= "" then
                local bit = SRC_BIT[atom]
                if not bit then die("unknown source class: " .. atom, r.line) end
                mask = mask + bit
            end
        end
        local acq, flags = parseAcq(r.acq, r.line, false, r)
        if flags.grant then
            mask = mask + SRC_GRANT
            census.grant = census.grant + 1
        end
        -- Shared-cooldown group. The only shared-cooldown family in this era's
        -- data is alchemy's transmutes: every one of them draws on ONE timer, so
        -- a reader that treated them as thirteen independent cooldowns would
        -- show twelve lies every time one was used. The group is derived HERE,
        -- from the English recipe name, and only the group ordinal ships — the
        -- name does not.
        local cdGroup = 0
        if r.name:find("^Transmute:") then cdGroup = 1 end
        for id in acq:gmatch("I(%d+)") do referencedItems[tonumber(id)] = true end
        for id in acq:gmatch("K(%d+)") do referencedItems[tonumber(id)] = true end
        for id in acq:gmatch("T%d+@(%d+)") do
            if not trainerSets[p][tonumber(id)] then
                die("recipe references trainer set TS" .. id .. " the profession does not define", r.line)
            end
        end
        rowsR[#rowsR + 1] = table.concat({
            p, r.spell, r.skill, r.phase, specIdx, mask, cdGroup, acq,
        }, "|")
        census.recipes = census.recipes + 1
    end

    for _, it in ipairs(items[p]) do
        local acq, flags = parseAcq(it.acq, it.line, true, it)
        if flags.noSource then census.noSource = census.noSource + 1 end
        if flags.worldDrop then census.worldDrop = census.worldDrop + 1 end
        if flags.event then census.event = census.event + 1 end
        for id in acq:gmatch("V%d+@([%d%+]+)") do
            for n in id:gmatch("%d+") do referencedNpcs[tonumber(n)] = true end
        end
        for id in acq:gmatch("D([%d%+]+)") do
            for n in id:gmatch("%d+") do referencedNpcs[tonumber(n)] = true end
        end
        -- Unobtainability CANDIDATE flags (addendum §6.2). These are candidates,
        -- not verdicts: "w" world-drop-only means unfindable, not unobtainable,
        -- and "e" event means obtainable but not today. Only "x" claims the data
        -- knows no route at all, and after FIX-3 nothing carries it.
        local fl = {}
        if flags.noSource  then fl[#fl + 1] = "x" end
        if flags.event     then fl[#fl + 1] = "e" end
        if flags.worldDrop then fl[#fl + 1] = "w" end
        rowsI[#rowsI + 1] = table.concat({
            p, it.item, ({ common = 1, uncommon = 2, rare = 3, epic = 4 })[it.quality] or 1,
            it.phase, (#fl > 0 and table.concat(fl) or "-"), acq,
        }, "|")
        census.items = census.items + 1
    end
end

-- Teaching items a recipe points at must exist in the recipe-item tables.
local haveItem = {}
for p = 1, #PROF_ORDER do
    for _, it in ipairs(items[p]) do haveItem[it.item] = true end
end
for id in pairs(referencedItems) do
    if not haveItem[id] then die("recipe references recipe-item " .. id .. " that no table carries") end
end
for id in pairs(referencedNpcs) do
    if not npcs[id] then die("acquisition references NPC " .. id .. " the NPC index does not carry") end
end
for p = 1, #PROF_ORDER do
    for setIdx, ids in pairs(trainerSets[p]) do
        for _, id in ipairs(ids) do
            if not npcs[id] then
                die("trainer set TS" .. setIdx .. " of " .. PROF_ORDER[p].key
                    .. " names NPC " .. id .. " the NPC index does not carry")
            end
        end
    end
end

----------------------------------------------------------------------
-- Emit
----------------------------------------------------------------------

local out = {}
local function w(s) out[#out + 1] = s end

w("# Daseeki Nexus — professions FACT SOURCE (checked in; generated, do not hand-edit)")
w("# Produced by dev/extract-professions-facts.lua from the clean-room addendum")
w("# PROFESSIONS_DATASET_ADDENDUM.md. Game facts only: ids, requirements, prices,")
w("# relations. English names appear ONLY for entities a client cannot resolve from")
w("# an id offline (NPCs, zones, quests, objects, events, factions, professions,")
w("# specialisations, prose notes). Recipe and recipe-item names are deliberately")
w("# absent — GetSpellInfo / GetItemInfo answer those live, in the player's language.")
w("#")
w("# Regenerate:  lua5.1 dev/extract-professions-facts.lua")
w("# Then ship:   lua5.1 dev/gen-professions-data.lua")
w("")

w("[meta]")
w("source|PROFESSIONS_DATASET_ADDENDUM.md")
w("era|classic-era permanent phase 6 (interface 11509)")
w("professions|" .. #PROF_ORDER)
w("recipes|" .. census.recipes)
w("items|" .. census.items)
w("npcs|" .. #npcOrder)
w("zones|" .. #zoneOrder)
w("quests|" .. #questOrder)
w("objects|" .. #objectOrder)
w("events|" .. #eventOrder)
w("factions|" .. #factionOrder)
w("specs|" .. #specs)
w("ranks|" .. #ranks)
w("notes|" .. #notes)
w("grantOnLearn|" .. census.grant)
w("noSource|" .. census.noSource)
w("worldDropItems|" .. census.worldDrop)
w("eventItems|" .. census.event)
w("")

w("[fix]")
for _, f in ipairs(FIXES) do
    w(f.id .. "|" .. f.what .. "|" .. tostring(f.was) .. "|" .. tostring(f.now) .. "|" .. f.why)
end
w("")

w("[prof]")
for i, p in ipairs(PROF_ORDER) do
    w(i .. "|" .. p.key .. "|" .. p.name .. "|" .. #recipes[i])
end
w("")

w("[note]")
for i, t in ipairs(notes) do w(i .. "|" .. t) end
w("")

w("[continent]")
for i, name in ipairs(continentOrder) do w(i .. "|" .. name) end
w("")

w("[zone]")
for i, id in ipairs(zoneOrder) do
    local z = zones[id]
    w(table.concat({ i, id, continents[z.continent] or 0, z.lmin or 0, z.lmax or 0, z.name }, "|"))
end
w("")

w("[npc]")
for _, id in ipairs(npcOrder) do
    local n = npcs[id]
    local st = STANCE[n.stance]
    if not st then die("unknown NPC stance: " .. tostring(n.stance), n.line) end
    w(table.concat({
        id, zoneIdxByName(n.zoneName, n.line),
        n.x and math.floor(n.x * 100 + 0.5) or -1,
        n.y and math.floor(n.y * 100 + 0.5) or -1,
        st, n.lmin or 0, n.lmax or 0, n.elite and 1 or 0, n.name,
    }, "|"))
end
w("")

w("[quest]")
for _, id in ipairs(questOrder) do
    local q = quests[id]
    w(table.concat({ id, q.minLvl, (#q.givers > 0 and joinNums(q.givers) or "-"), q.name }, "|"))
end
w("")

w("[object]")
for _, id in ipairs(objectOrder) do
    local o = objects[id]
    w(table.concat({ id, zoneIdxByName(o.zoneName, o.line), o.name }, "|"))
end
w("")

w("[event]")
for _, id in ipairs(eventOrder) do w(id .. "|" .. events[id]) end
w("")

w("[faction]")
for _, id in ipairs(factionOrder) do w(id .. "|" .. factions[id]) end
w("")

w("[standing]")
do
    local names = {}
    for k, v in pairs(STANDING) do names[#names + 1] = { id = v, name = k } end
    table.sort(names, function(a, b) return a.id < b.id end)
    for _, s in ipairs(names) do w(s.id .. "|" .. s.name) end
end
w("")

w("[spec]")
-- Field 7 (FIX-4) is the parent spec ORDINAL, 0 for a root spec. It sits AFTER
-- the name — [prof] already carries a field after its name, and appending is
-- what keeps a six-field reader reading exactly what it always read.
for i, s in ipairs(specs) do
    w(table.concat({ i, s.id, s.prof, s.minSkill, s.quest, s.name, s.parent or 0 }, "|"))
end
w("")

w("[rank]")
do
    local sorted = {}
    for _, r in ipairs(ranks) do sorted[#sorted + 1] = r end
    table.sort(sorted, function(a, b)
        if a.prof ~= b.prof then return a.prof < b.prof end
        return a.tier < b.tier
    end)
    for _, r in ipairs(sorted) do
        w(table.concat({
            r.prof, r.tier, r.spell, r.floor, r.ceil, r.clvl, r.cost,
            (#r.trainers > 0 and joinNums(r.trainers) or "-"),
            r.item or 0,
            (#r.quests > 0 and joinNums(r.quests) or "-"),
        }, "|"))
    end
end
w("")

w("[trainerset]")
for p = 1, #PROF_ORDER do
    local idxs = {}
    for k in pairs(trainerSets[p]) do idxs[#idxs + 1] = k end
    table.sort(idxs)
    for _, k in ipairs(idxs) do
        w(table.concat({ p, k, joinNums(trainerSets[p][k]) }, "|"))
    end
end
w("")

w("[recipe]")
for _, r in ipairs(rowsR) do w(r) end
w("")

w("[item]")
for _, r in ipairs(rowsI) do w(r) end
w("")

local fo = io.open(OUT_PATH, "wb")
if not fo then die("cannot write " .. OUT_PATH) end
fo:write(table.concat(out, "\n"))
fo:write("\n")
fo:close()

local size = 0
do
    local f = io.open(OUT_PATH, "rb")
    size = #f:read("*a")
    f:close()
end

io.write(string.format(
    "extract-professions-facts: wrote %s\n  %d bytes | %d recipes | %d recipe-items | %d NPCs"
    .. " | %d zones | %d quests | %d objects | %d events | %d factions | %d specs | %d ranks"
    .. " | %d notes\n  grant-on-learn %d | no-source %d (after fixes) | world-drop items %d"
    .. " | event items %d\n",
    OUT_PATH, size, census.recipes, census.items, #npcOrder, #zoneOrder, #questOrder,
    #objectOrder, #eventOrder, #factionOrder, #specs, #ranks, #notes,
    census.grant, census.noSource, census.worldDrop, census.event))
