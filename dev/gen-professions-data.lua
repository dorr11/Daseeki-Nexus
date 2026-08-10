--[[
    dev/gen-professions-data.lua — BUILD THE SHIPPED PROFESSION DATASET.

    WHY THIS EXISTS
    ---------------
    Same argument as dev/gen-catalog.lua in Daseeki-Armory: Classic Era is a
    FROZEN CLIENT. The recipe universe — which teaching spell exists, what skill
    it needs, which profession owns it, where it comes from — is identical on
    every account, every realm and every login. A constant does not need
    measuring by the person reading it. It needs shipping.

    So the dataset is computed ONCE, here, on a developer's machine, and shipped
    as professions_data.lua. A player who has never opened a profession window
    still gets the complete catalogue behind the tooltip and the panel.

    HOW TO RUN
        lua5.1 dev/gen-professions-data.lua [FACTS_PATH] [OUT_PATH]

    FACTS_PATH  defaults to dev/professions-facts.txt — the checked-in fact
                source produced by dev/extract-professions-facts.lua.
    OUT_PATH    defaults to <repo>/professions_data.lua (overwritten in place).

    WHAT THIS DOES BEYOND COPYING
      1. CENSUS GATE. Re-counts every section and asserts it against the
         [meta] block the extractor wrote. A silently truncated fact source is
         the one failure that would ship as "that recipe just does not exist",
         which is indistinguishable from a real answer (addendum §7 defect 24).
      2. REFERENTIAL GATE. Re-walks every relation and asserts the id resolves,
         so the shipped file cannot carry a dangling reference even if someone
         hand-edited the fact source between the two steps.
      3. VERSION STAMP. Computes a content hash over the shipped payload and
         bakes it in as ns.ProfessionsDataMeta.version. Every published mesh
         payload carries that string, because the known-recipe bitmap's bit
         positions ARE the dataset's per-profession recipe ordering: a peer
         holding a different dataset must refuse to decode rather than decode
         wrongly. Refusing reads as "not scanned"; decoding wrongly reads as
         "your alt knows these fourteen recipes", which is a lie.
      4. SHAPE. The payload ships as ONE LONG STRING, not as tables — the
         Armory catalog precedent, for the same two reasons. First, the module
         has an enable switch and the spec's inertness rule says a disabled
         module must not hold its dataset: a string constant is bytes the client
         already had on disk, while a table literal is thousands of permanent
         hash nodes built at file-parse time whether or not anyone wants them.
         Second, the parse is staged — the capture layer needs the recipe index
         and nothing else, so the source/NPC/zone layer is not built until a
         view asks for it.

    WHAT IS NOT HERE. Recipe names, recipe-item names, reagents, produced-item
    ids. The first two are resolved live from ids (GetSpellInfo / GetItemInfo)
    in the player's own language. The last two DO NOT EXIST IN THE SOURCE DATA
    AT ALL (addendum §2, the reagent hole) and are harvested from the live
    trade-skill window by professions.lua instead.
]]

local function scriptDir()
    local src = debug.getinfo(1, "S").source:gsub("^@", "")
    return src:match("^(.*)[/\\][^/\\]*$") or "."
end

local DEV_DIR  = scriptDir()
local REPO_DIR = DEV_DIR:match("^(.*)[/\\][^/\\]*$") or "."

local FACTS_PATH = arg[1] or (DEV_DIR .. "/professions-facts.txt")
local OUT_PATH   = arg[2] or (REPO_DIR .. "/professions_data.lua")

local function die(msg)
    io.stderr:write("gen-professions-data: FATAL: " .. msg .. "\n")
    os.exit(1)
end

-- Does this acquisition field carry that EXACT token? Substring matching would
-- see the "G" of a grant relation inside a note index or an NPC id list, which
-- is how a census gate turns into a census rumour.
local function hasToken(acq, want)
    for tok in (tostring(acq or "") .. ";"):gmatch("(.-);") do
        if tok == want then return true end
    end
    return false
end

----------------------------------------------------------------------
-- Read the fact source, strip the human layer
--
-- Comments and blank lines are the only difference between the fact source and
-- the shipped payload. Keeping the two otherwise byte-identical means a diff of
-- professions_data.lua reads as a diff of the facts, which is the whole point
-- of checking the facts in.
----------------------------------------------------------------------

local fh = io.open(FACTS_PATH, "rb")
if not fh then die("cannot open fact source: " .. FACTS_PATH) end
local rawIn = fh:read("*a")
fh:close()

local kept, meta = {}, {}
local section, counts = nil, {}
local order = {}

for line in (rawIn .. "\n"):gmatch("(.-)\n") do
    line = line:gsub("\r$", "")
    if line ~= "" and line:sub(1, 1) ~= "#" then
        kept[#kept + 1] = line
        local s = line:match("^%[(%a+)%]$")
        if s then
            section = s
            if counts[s] then die("duplicate section [" .. s .. "] in the fact source") end
            counts[s] = 0
            order[#order + 1] = s
        elseif section then
            counts[section] = counts[section] + 1
            if section == "meta" then
                local k, v = line:match("^([^|]+)|(.*)$")
                if k then meta[k] = v end
            end
        else
            die("row outside any section: " .. line)
        end
    end
end

if #kept == 0 then die("fact source is empty") end

----------------------------------------------------------------------
-- Gate 1 — census
----------------------------------------------------------------------

local function expect(sectionName, metaKey)
    local want = tonumber(meta[metaKey])
    if not want then die("[meta] is missing " .. metaKey) end
    local got = counts[sectionName] or 0
    if got ~= want then
        die(string.format("census: [%s] holds %d rows, [meta] %s says %d",
            sectionName, got, metaKey, want))
    end
end

expect("prof",       "professions")
expect("recipe",     "recipes")
expect("item",       "items")
expect("npc",        "npcs")
expect("zone",       "zones")
expect("quest",      "quests")
expect("object",     "objects")
expect("event",      "events")
expect("faction",    "factions")
expect("spec",       "specs")
expect("rank",       "ranks")
expect("note",       "notes")

----------------------------------------------------------------------
-- Gate 2 — referential integrity + per-profession recipe counts
----------------------------------------------------------------------

local profCount, profKey = {}, {}
local recipeCount, itemIds, npcIds, zoneCount = {}, {}, {}, 0
local questIds, objectIds, eventIds, factionIds, noteIds, specCount = {}, {}, {}, {}, {}, 0
local specRows = {}   -- ordinal -> { prof, parent } for the FIX-4 parent gate
local trainerSets = {}
local seenRecipe, seenItem = {}, {}
local grantCount, noSourceCount = 0, 0

section = nil
for _, line in ipairs(kept) do
    local s = line:match("^%[(%a+)%]$")
    if s then
        section = s
    elseif section == "prof" then
        local idx, key, _, n = line:match("^(%d+)|([^|]+)|([^|]*)|(%d+)$")
        if not idx then die("malformed [prof] row: " .. line) end
        profKey[tonumber(idx)] = key
        profCount[tonumber(idx)] = tonumber(n)
        recipeCount[tonumber(idx)] = 0
    elseif section == "note" then
        noteIds[tonumber(line:match("^(%d+)|"))] = true
    elseif section == "zone" then
        zoneCount = zoneCount + 1
    elseif section == "npc" then
        local id, zi = line:match("^(%d+)|(%d+)|")
        if not id then die("malformed [npc] row: " .. line) end
        npcIds[tonumber(id)] = true
        if tonumber(zi) < 1 or tonumber(zi) > (tonumber(meta.zones) or 0) then
            die("[npc] row " .. id .. " points at zone ordinal " .. zi .. " out of range")
        end
    elseif section == "quest" then
        questIds[tonumber(line:match("^(%d+)|"))] = true
    elseif section == "object" then
        objectIds[tonumber(line:match("^(%d+)|"))] = true
    elseif section == "event" then
        eventIds[tonumber(line:match("^(%d+)|"))] = true
    elseif section == "faction" then
        factionIds[tonumber(line:match("^(%d+)|"))] = true
    elseif section == "spec" then
        specCount = specCount + 1
        -- FIX-4 parent edge: field 7 must be 0 or another [spec] ordinal (never
        -- itself), and a parent must share the child's profession. Ordinals are
        -- contiguous from the extractor, so range + prof are checkable in one
        -- pass once every row is parsed (see the second-pass gate below).
        local sIdx, sProf, sParent =
            line:match("^(%d+)|%d+|(%d+)|%d+|%d+|[^|]*|(%d+)$")
        if not sIdx then die("malformed [spec] row (seven fields expected): " .. line) end
        specRows[tonumber(sIdx)] = { prof = tonumber(sProf), parent = tonumber(sParent) }
    elseif section == "trainerset" then
        local p, k = line:match("^(%d+)|(%d+)|")
        if not p then die("malformed [trainerset] row: " .. line) end
        trainerSets[tonumber(p) .. ":" .. tonumber(k)] = line:match("^%d+|%d+|(.*)$")
    elseif section == "item" then
        local p, id = line:match("^(%d+)|(%d+)|")
        if not p then die("malformed [item] row: " .. line) end
        itemIds[tonumber(id)] = true
        seenItem[tonumber(id)] = true
        if hasToken(line:match("|([^|]*)$"), "X") then
            noSourceCount = noSourceCount + 1
        end
    elseif section == "recipe" then
        local p, spell, skill, phase, spec, mask, cd, acq =
            line:match("^(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(%d+)|(.*)$")
        if not p then die("malformed [recipe] row: " .. line) end
        p = tonumber(p)
        recipeCount[p] = (recipeCount[p] or 0) + 1
        if seenRecipe[tonumber(spell)] then
            die("duplicate teaching spell id " .. spell .. " (the primary key must be unique)")
        end
        seenRecipe[tonumber(spell)] = true
        if hasToken(acq, "G") then grantCount = grantCount + 1 end
    end
end

-- Second pass: relation targets, now that every id table is populated.
section = nil
for _, line in ipairs(kept) do
    local s = line:match("^%[(%a+)%]$")
    if s then
        section = s
    elseif section == "recipe" or section == "item" then
        local acq = line:match("|([^|]*)$")
        for id in acq:gmatch("I(%d+)") do
            if not itemIds[tonumber(id)] then die("dangling teaching-item reference " .. id) end
        end
        for id in acq:gmatch("K(%d+)") do
            if not itemIds[tonumber(id)] then die("dangling contract-item reference " .. id) end
        end
        for grp in acq:gmatch("Q([%d%+]+)") do
            for id in grp:gmatch("%d+") do
                if not questIds[tonumber(id)] then die("dangling quest reference " .. id) end
            end
        end
        for grp in acq:gmatch("O([%d%+]+)") do
            for id in grp:gmatch("%d+") do
                if not objectIds[tonumber(id)] then die("dangling world-object reference " .. id) end
            end
        end
        for id in acq:gmatch("E(%d+)") do
            if not eventIds[tonumber(id)] then die("dangling world-event reference " .. id) end
        end
        for id in acq:gmatch("R(%d+)/") do
            if not factionIds[tonumber(id)] then die("dangling faction reference " .. id) end
        end
        for id in acq:gmatch("S(%d+)") do
            if not noteIds[tonumber(id)] then die("dangling prose-note reference " .. id) end
        end
        for grp in acq:gmatch("V%d+@([%d%+]+)") do
            for id in grp:gmatch("%d+") do
                if not npcIds[tonumber(id)] then die("dangling vendor NPC reference " .. id) end
            end
        end
        for grp in acq:gmatch("D([%d%+]+)") do
            for id in grp:gmatch("%d+") do
                if not npcIds[tonumber(id)] then die("dangling drop NPC reference " .. id) end
            end
        end
        local p = line:match("^(%d+)|")
        for setIdx in acq:gmatch("T%d+@(%d+)") do
            if not trainerSets[tonumber(p) .. ":" .. tonumber(setIdx)] then
                die("recipe in profession " .. p .. " references trainer set " .. setIdx
                    .. " that profession does not define")
            end
        end
    end
end

for idx, want in pairs(profCount) do
    if recipeCount[idx] ~= want then
        die(string.format("profession %s carries %d recipe rows but its [prof] row claims %d",
            profKey[idx] or idx, recipeCount[idx] or 0, want))
    end
end

-- FIX-4 parent-edge gate: every [spec] parent resolves to a real spec row in
-- the SAME profession and never to itself. A dangling parent would ship as a
-- lane chain that silently dead-ends, which is exactly the class of quiet lie
-- the referential gate exists to refuse.
for idx, row in pairs(specRows) do
    local p = row.parent or 0
    if p ~= 0 then
        local target = specRows[p]
        if not target then
            die("spec ordinal " .. idx .. " parents to " .. p .. ", which is not a [spec] row")
        end
        if p == idx then
            die("spec ordinal " .. idx .. " parents to itself")
        end
        if target.prof ~= row.prof then
            die("spec ordinal " .. idx .. " parents across professions (" ..
                tostring(row.prof) .. " -> " .. tostring(target.prof) .. ")")
        end
    end
end

if grantCount ~= tonumber(meta.grantOnLearn) then
    die(string.format("grant-on-learn census: counted %d, [meta] says %s", grantCount, meta.grantOnLearn))
end
if noSourceCount ~= tonumber(meta.noSource) then
    die(string.format("no-source census: counted %d, [meta] says %s", noSourceCount, meta.noSource))
end

----------------------------------------------------------------------
-- Version stamp — FNV-1a 32 over the shipped payload
----------------------------------------------------------------------

local PAYLOAD = table.concat(kept, "\n") .. "\n"

-- Lua 5.1 has no integer bitwise operators, so FNV-1a/32 is done with
-- arithmetic on two 16-bit halves. Deterministic and portable; it never runs on
-- a player's machine, because the result is baked in as a string literal.
local function xor8(a, b)
    local r, bit = 0, 1
    for _ = 1, 8 do
        local ab, bb = a % 2, b % 2
        if ab ~= bb then r = r + bit end
        a, b, bit = math.floor(a / 2), math.floor(b / 2), bit * 2
    end
    return r
end

local function hash32(s)
    local hi, lo = 0x811C, 0x9DC5        -- FNV-1a offset basis 0x811C9DC5
    local PL, PH = 0x0193, 0x0100        -- FNV prime            0x01000193
    for i = 1, #s do
        local low8 = lo % 256
        lo = lo - low8 + xor8(low8, s:byte(i))
        local l = lo * PL
        local h = hi * PL + lo * PH + math.floor(l / 65536)
        lo = l % 65536
        hi = h % 65536
    end
    return string.format("%04x%04x", hi, lo)
end

local VERSION = "p1-" .. hash32(PAYLOAD)

----------------------------------------------------------------------
-- Emit
----------------------------------------------------------------------

local HEADER = [==[
-- Daseeki Nexus — professions_data.lua
--
-- GENERATED FILE. Built by dev/gen-professions-data.lua out of the checked-in
-- fact source dev/professions-facts.txt; regenerate rather than hand-edit.
--
-- WHAT IT IS. The Classic Era recipe universe as FACTS: teaching spell ids,
-- skill requirements, profession ownership, specialisation gates, derived
-- source classes, acquisition relations, and the NPC / zone / quest / object /
-- event / faction indices those relations point at. Era is a frozen client, so
-- this is a constant — the same on every account, realm and login — and a
-- constant is delivered, never measured by the player.
--
-- WHAT IT IS NOT. There are no recipe names and no item names in here. The
-- client resolves those from the ids, in the player's own language, always
-- current; shipping ten translations of three thousand records is what makes
-- the equivalent third-party dataset 2.3 MB. English names appear ONLY where
-- the client cannot answer from an id offline: NPCs, zones, quests, world
-- objects, world events, reputation factions and standings, profession and
-- specialisation names, and the prose acquisition notes.
--
-- There are also no REAGENTS and no produced-item ids, because they are not
-- facts anyone wrote down for us to carry — the source dataset has neither.
-- professions.lua harvests both from the live trade-skill window while it is
-- open and caches them per teaching-spell id.
--
-- THE CONTRACT the rest of the addon depends on:
--
--   ns.ProfessionsDataRaw     one long string, section-delimited, one record
--                             per line, fields "|"-separated. Sections, in
--                             order: meta, fix, prof, note, continent, zone,
--                             npc, quest, object, event, faction, standing,
--                             spec, rank, trainerset, recipe, item.
--
--   ns.ProfessionsDataMeta    { version, recipes, items, npcs, ... } — the
--                             counts as literals, so the load-time census gate
--                             never costs a parse, plus the version stamp.
--
--   Parse it through ns.Professions.Dataset — the parser lives there, staged,
--   so the capture layer's needs (the recipe index) are built without building
--   the source graph a view has not asked for yet.
--
-- WHY A STRING AND NOT A TABLE. The module has an enable switch, and the
-- behavioral spec's inertness rule says a disabled module holds no dataset. A
-- string constant is bytes the client read off disk either way; a table literal
-- is thousands of permanent hash nodes built at file-parse time whether or not
-- anybody wants them. Era's .toc has no per-file load-on-demand — only a
-- separate load-on-demand ADDON FOLDER achieves "not read at all", and Nexus
-- ships as one folder — so this is the honest floor: with the module off, the
-- client holds this string and NOTHING is built from it.
--
-- VERSION STAMP. ns.ProfessionsDataMeta.version is a content hash, and every
-- published mesh payload carries it, because the known-recipe bitmap's bit
-- positions ARE this file's per-profession recipe ordering. A peer holding a
-- different dataset must refuse to decode rather than decode wrongly: refusing
-- renders as "not scanned", decoding wrongly renders as a list of recipes that
-- character does not know.
--
-- Clean-room: the facts are game facts, extracted through our own Room-1
-- addendum. No third-party code, identifiers or file structure appear here.

local ADDON, ns = ...

]==]

local out = {}
out[#out + 1] = HEADER
out[#out + 1] = "ns.ProfessionsDataMeta = {\n"
out[#out + 1] = string.format("    version     = %q,\n", VERSION)
local metaOrder = {
    "professions", "recipes", "items", "npcs", "zones", "quests", "objects",
    "events", "factions", "specs", "ranks", "notes", "grantOnLearn",
    "noSource", "worldDropItems", "eventItems",
}
for _, k in ipairs(metaOrder) do
    out[#out + 1] = string.format("    %-11s = %s,\n", k, tostring(tonumber(meta[k]) or 0))
end
out[#out + 1] = string.format("    era         = %q,\n", meta.era or "")
out[#out + 1] = "}\n\n"
out[#out + 1] = "ns.ProfessionsDataRaw = [==[\n"
out[#out + 1] = PAYLOAD
out[#out + 1] = "]==]\n"

local body = table.concat(out)
if PAYLOAD:find("]==]", 1, true) then
    die("the payload contains a long-bracket terminator; the quoting level must change")
end

local fo = io.open(OUT_PATH, "wb")
if not fo then die("cannot write " .. OUT_PATH) end
fo:write(body)
fo:close()

-- Prove the emitted file compiles, here, rather than finding out in-game.
local chunk, err = loadfile(OUT_PATH)
if not chunk then die("the generated file does not compile: " .. tostring(err)) end

io.write(string.format(
    "gen-professions-data: wrote %s\n  file %d bytes | payload %d bytes | %d rows | version %s\n"
    .. "  %d recipes | %d recipe-items | %d NPCs | %d zones | %d quests | %d specs | %d ranks\n",
    OUT_PATH, #body, #PAYLOAD, #kept, VERSION,
    tonumber(meta.recipes), tonumber(meta.items), tonumber(meta.npcs),
    tonumber(meta.zones), tonumber(meta.quests), tonumber(meta.specs), tonumber(meta.ranks)))
