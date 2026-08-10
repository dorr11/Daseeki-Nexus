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
-- RECIPE-SET IDENTITY  (feat/dataset-migration)
--
-- The version stamp above hashes EVERYTHING — sources, zones, spec edges,
-- prose notes. But the known-recipe bitmaps depend on exactly one thing: the
-- per-profession teaching-spell ordering. The 2026-08-10 incident was the gap
-- between those two facts: a spec-tree addition moved the stamp without moving
-- one recipe, and every character's record went "not checked" — a full re-scan
-- tour of the alts, twice in one day.
--
-- So the dataset also ships a SET HASH: a content hash over the canonical
-- membership-and-ordering string, "<profOrdinal>:<teachingSpellID>" per recipe
-- row in bitmap order. Two builds with the same set hash have byte-identical
-- bitmap coordinate systems, whatever else changed. ONE GLOBAL HASH, not one
-- per profession, deliberately: the wire pays one short field beside `ds`
-- instead of one per profession record, one gate answers validity, and the
-- per-profession precision a split hash would buy is already delivered by the
-- migrations section below (an untouched profession's map is the identity,
-- represented in a handful of bytes).
----------------------------------------------------------------------

local canonRows, profOrder = {}, {}
section = nil
for _, line in ipairs(kept) do
    local s = line:match("^%[(%a+)%]$")
    if s then
        section = s
    elseif section == "recipe" then
        local p, spell = line:match("^(%d+)|(%d+)|")
        canonRows[#canonRows + 1] = p .. ":" .. spell
        local pi = tonumber(p)
        profOrder[pi] = profOrder[pi] or {}
        profOrder[pi][#profOrder[pi] + 1] = spell
    end
end

-- PURE over an orderings table { [profIdx] = { id, id, ... } }: the canonical
-- string, so a historical snapshot hashes through the very same function the
-- live facts do — one definition of "same set", not two.
local function canonOf(orderings, profTotal)
    local rows = {}
    for pi = 1, profTotal do
        local ids = orderings[pi]
        if ids then
            for i = 1, #ids do rows[#rows + 1] = pi .. ":" .. ids[i] end
        end
    end
    return table.concat(rows, "\n") .. "\n"
end

local PROF_TOTAL = tonumber(meta.professions)
local SETHASH = "s1-" .. hash32(canonOf(profOrder, PROF_TOTAL))

----------------------------------------------------------------------
-- ORDERING SNAPSHOTS  (dev/professions-orderings/)
--
-- One compact file per historical stamp, listing each profession's teaching
-- spells in bitmap order. They are the generator's MEMORY: the shipped
-- migrations section below is derived from them, so a record written under any
-- snapshotted build can be translated instead of discarded. The dir carries an
-- index.txt because plain Lua 5.1 cannot list a directory; the generator
-- maintains it (sorted — class 8, the emission may never inherit file-system
-- enumeration luck).
--
-- DISCIPLINE: the current run's snapshot is written if absent, and an EXISTING
-- snapshot for the same stamp that disagrees byte-for-byte is a hard refusal —
-- two different orderings under one stamp would make the stamp a lie and every
-- migration derived from it a corruption.
----------------------------------------------------------------------

local SNAP_DIR   = DEV_DIR .. "/professions-orderings"
local INDEX_PATH = SNAP_DIR .. "/index.txt"

local function snapshotBody(stamp, sethash, orderings)
    local out = {
        "# Daseeki Nexus - professions ordering snapshot. GENERATED; never hand-edit.",
        "# One line per profession: o|<prof ordinal>|<prof key>|<teaching spell ids, bitmap order>",
        "stamp|" .. stamp,
        "sethash|" .. sethash,
    }
    for pi = 1, PROF_TOTAL do
        out[#out + 1] = "o|" .. pi .. "|" .. (profKey[pi] or "?") .. "|"
            .. table.concat(orderings[pi] or {}, ",")
    end
    return table.concat(out, "\n") .. "\n"
end

local function readAll(path)
    local fh2 = io.open(path, "rb")
    if not fh2 then return nil end
    local body = fh2:read("*a")
    fh2:close()
    return body
end

local function writeAll(path, body)
    local fo2 = io.open(path, "wb")
    if not fo2 then
        die("cannot write " .. path .. " (does dev/professions-orderings/ exist?)")
    end
    fo2:write(body)
    fo2:close()
end

-- Parse a snapshot back into { stamp, sethash, orderings }. Every gate dies:
-- a half-read snapshot silently dropped would ship as "that build never
-- existed", which renders as the exact re-scan tour this layer exists to end.
local function parseSnapshot(path)
    local body = readAll(path)
    if not body then die("index.txt names a snapshot that does not exist: " .. path) end
    local snap = { orderings = {} }
    for line in (body .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("\r$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local k, v = line:match("^(%a+)|(.*)$")
            if k == "stamp" then
                snap.stamp = v
            elseif k == "sethash" then
                snap.sethash = v
            elseif k == "o" then
                local pi, _, ids = line:match("^o|(%d+)|([^|]*)|(.*)$")
                if not pi then die("malformed ordering row in " .. path .. ": " .. line) end
                local list = {}
                for id in ids:gmatch("(%d+)") do list[#list + 1] = id end
                snap.orderings[tonumber(pi)] = list
            end
        end
    end
    if not (snap.stamp and snap.sethash) then
        die("snapshot " .. path .. " is missing its stamp or sethash header")
    end
    local recomputed = "s1-" .. hash32(canonOf(snap.orderings, PROF_TOTAL))
    if recomputed ~= snap.sethash then
        die("snapshot " .. path .. " does not hash to its own sethash ("
            .. recomputed .. " vs " .. snap.sethash .. ") - corrupted or hand-edited")
    end
    return snap
end

-- The current snapshot: write-if-absent, refuse a mismatched overwrite.
local SNAP_BODY = snapshotBody(VERSION, SETHASH, profOrder)
do
    local existing = readAll(SNAP_DIR .. "/" .. VERSION .. ".txt")
    if existing == nil then
        writeAll(SNAP_DIR .. "/" .. VERSION .. ".txt", SNAP_BODY)
    elseif existing ~= SNAP_BODY then
        die("ordering snapshot for stamp " .. VERSION .. " already exists and DISAGREES"
            .. " with this run - two orderings under one stamp is a corrupted history;"
            .. " refusing to overwrite")
    end
end

-- The index: every known stamp, sorted, current one included.
local stamps, stampSeen = {}, {}
do
    local idx = readAll(INDEX_PATH)
    for line in ((idx or "") .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("\r$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" and not stampSeen[line] then
            stampSeen[line] = true
            stamps[#stamps + 1] = line
        end
    end
    if not stampSeen[VERSION] then
        stampSeen[VERSION] = true
        stamps[#stamps + 1] = VERSION
    end
    table.sort(stamps)
    writeAll(INDEX_PATH, table.concat(stamps, "\n") .. "\n")
end

----------------------------------------------------------------------
-- MIGRATIONS — old set-hash -> current, per profession, ordinal to ordinal
--
-- Derived, never authored: for every snapshot whose set hash differs from the
-- current one, each profession's map is old ordinal -> new ordinal by teaching
-- spell id (0 = the recipe left the dataset). A profession whose membership
-- and order survived intact is emitted as "=<n>" — the identity, in five
-- bytes. Snapshots whose set hash EQUALS the current one need no migration at
-- all (that is Layer 1's whole point); they contribute only their stamp
-- association, so a record carrying nothing but the old `ds` can still be
-- named and rescued.
----------------------------------------------------------------------

local spellNewOrd = {}          -- profIdx -> spellID(string) -> new ordinal
for pi = 1, PROF_TOTAL do
    spellNewOrd[pi] = {}
    local ids = profOrder[pi] or {}
    for i = 1, #ids do spellNewOrd[pi][ids[i]] = i end
end

local compatRows = { "[stampset]" }
local snapsBySethash, migrationRows = {}, {}
for i = 1, #stamps do                                  -- sorted: class 8
    local snap = (stamps[i] == VERSION) and { stamp = VERSION, sethash = SETHASH, orderings = profOrder }
        or parseSnapshot(SNAP_DIR .. "/" .. stamps[i] .. ".txt")
    if snap.stamp ~= stamps[i] then
        die("snapshot file " .. stamps[i] .. ".txt declares stamp " .. tostring(snap.stamp))
    end
    compatRows[#compatRows + 1] = snap.stamp .. "|" .. snap.sethash
    if snap.sethash ~= SETHASH and not snapsBySethash[snap.sethash] then
        snapsBySethash[snap.sethash] = true
        for pi = 1, PROF_TOTAL do
            local oldIds = snap.orderings[pi] or {}
            if #oldIds > 0 then
                local identity = (#oldIds == #(profOrder[pi] or {}))
                local mapped = {}
                for o = 1, #oldIds do
                    local nn = spellNewOrd[pi][oldIds[o]] or 0
                    mapped[o] = tostring(nn)
                    if nn ~= o then identity = false end
                end
                migrationRows[#migrationRows + 1] = snap.sethash .. "|" .. pi .. "|"
                    .. (identity and ("=" .. #oldIds) or table.concat(mapped, ","))
            end
        end
    end
end
compatRows[#compatRows + 1] = "[migration]"
for i = 1, #migrationRows do compatRows[#compatRows + 1] = migrationRows[i] end
local COMPAT = table.concat(compatRows, "\n") .. "\n"

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
--   ns.ProfessionsDataMeta    { version, setHash, recipes, items, npcs, ... }
--                             — the counts as literals, so the load-time census
--                             gate never costs a parse, plus the version stamp
--                             and the recipe-set hash.
--
--   ns.ProfessionsDataCompat  the migration blob: [stampset] rows naming every
--                             historical dataset stamp's recipe-set hash, and
--                             [migration] rows translating each historical
--                             recipe set's ordinals into this build's. Parsed
--                             lazily by professions.lua, only when a record
--                             from another build shows up.
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
-- SET HASH (feat/dataset-migration). The version stamp hashes EVERYTHING, but
-- the bitmaps depend only on the recipe membership-and-ordering, so
-- ns.ProfessionsDataMeta.setHash names exactly that. A stamp bump that leaves
-- the set hash unchanged (sources, zones, spec edges, notes) invalidates
-- NOTHING: professions.lua rescues such records through the [stampset] table
-- in ns.ProfessionsDataCompat, and genuine set changes are translated through
-- its [migration] rows instead of being discarded.
--
-- Clean-room: the facts are game facts, extracted through our own Room-1
-- addendum. No third-party code, identifiers or file structure appear here.

local ADDON, ns = ...

]==]

local out = {}
out[#out + 1] = HEADER
out[#out + 1] = "ns.ProfessionsDataMeta = {\n"
out[#out + 1] = string.format("    version     = %q,\n", VERSION)
out[#out + 1] = string.format("    setHash     = %q,\n", SETHASH)
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
out[#out + 1] = "\n"
out[#out + 1] = "-- COMPAT (feat/dataset-migration). Derived from dev/professions-orderings/,\n"
out[#out + 1] = "-- OUTSIDE the version-stamped payload on purpose: the stamp names the facts'\n"
out[#out + 1] = "-- coordinate system, and shipping a better memory of old builds is not a new\n"
out[#out + 1] = "-- coordinate system. [stampset] rows associate every historical stamp with its\n"
out[#out + 1] = "-- recipe-set hash (so a record carrying only `ds` can be named); [migration]\n"
out[#out + 1] = "-- rows are <old set-hash>|<prof ordinal>|<old ordinal -> new ordinal map>,\n"
out[#out + 1] = "-- \"=<n>\" for the identity, 0 for a recipe that left the dataset.\n"
out[#out + 1] = "ns.ProfessionsDataCompat = [==[\n"
out[#out + 1] = COMPAT
out[#out + 1] = "]==]\n"

local body = table.concat(out)
if PAYLOAD:find("]==]", 1, true) then
    die("the payload contains a long-bracket terminator; the quoting level must change")
end
if COMPAT:find("]==]", 1, true) then
    die("the compat blob contains a long-bracket terminator; the quoting level must change")
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
    .. "  %d recipes | %d recipe-items | %d NPCs | %d zones | %d quests | %d specs | %d ranks\n"
    .. "  set-hash %s | %d ordering snapshot(s) | %d migration row(s)\n",
    OUT_PATH, #body, #PAYLOAD, #kept, VERSION,
    tonumber(meta.recipes), tonumber(meta.items), tonumber(meta.npcs),
    tonumber(meta.zones), tonumber(meta.quests), tonumber(meta.specs), tonumber(meta.ranks),
    SETHASH, #stamps, #migrationRows))
