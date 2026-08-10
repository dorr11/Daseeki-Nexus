-- Daseeki Nexus — professions.lua  (PROFESSIONS MODULE, wave P1)
--
-- Cross-account profession tracking: what every character on every account in
-- the mesh can make, how far along they are, and which profession cooldowns are
-- ready. Default ON, user-toggleable, and INERT when off in the strong sense
-- the behavioral spec demands — no frame, no Blizzard event, no saved-variable
-- key, and nothing built out of the shipped dataset.
--
-- This wave ships three of the four layers and none of the views:
--
--   DATASET   professions_data.lua — the frozen Era recipe universe as facts
--             (teaching spell ids, skill requirements, specialisation gates,
--             acquisition relations, the NPC/zone/quest indices). Parsed HERE,
--             lazily and in two stages, so a session that only ever captures
--             never builds the source graph a panel has not asked for.
--
--   CAPTURE   what THIS character knows, read from the client's own two
--             profession windows, plus levels, ranks, specialisations,
--             profession cooldowns, and the reagent list of every known recipe.
--
--   MESH      the `professions` namespace on Daseeki.Sync: a compact payload,
--             delta-detected, published at the backfill priority tier, with one
--             exception — a cooldown that was just consumed goes out at once.
--
-- The views (the Professions tab, the tooltip lines, the in-frame filters) are
-- P2/P3 and consume the store shape documented under STORE below.
--
----------------------------------------------------------------------
-- WHY THE KNOWN SET IS A BITMAP AND NOT A LIST OF IDS
--
-- The owner's constraint at design time was explicit: "be efficient with what
-- we send over the mesh to reduce lag and avoid any messaging limitations set
-- by WoW." A maxed blacksmith knows ~239 recipes; a list of 32-bit spell ids
-- for one character's two primaries plus three secondaries is ~500 numbers,
-- which LibSerialize writes as ~2 KB before compression and which the SYNC
-- prefix's ~1 message/second bucket then drips out for the better part of a
-- minute. The same fact set as per-profession bitmaps over the dataset's own
-- recipe ordering is ~570 bits — 96 characters. That is the whole reason the
-- dataset ships with a FROZEN per-profession recipe order: those bit positions
-- are a coordinate system, and the payload carries the dataset version so a
-- peer running a different build REFUSES to decode rather than decoding into
-- the wrong recipes. Refusing renders as "not scanned". Decoding wrongly
-- renders as a confident list of things that character cannot make.
--
----------------------------------------------------------------------
-- CLASS 6 — THE POLARITY, WHICH IS THE WHOLE POINT OF THIS MODULE
--
-- CLIENT_ASYNC_LESSONS class 6 is "dark reads of populatable lists": a list API
-- answers EMPTY before the server has populated it, and a diff against the
-- unpopulated answer reads as "everything was removed". The addendum found the
-- shipped third-party equivalent of this feature carrying exactly that defect
-- in its tooltip, in its most damaging form: it stores the MISSING set and
-- treats "absent from missing" as KNOWN, so a character whose record predates a
-- recipe is reported as ALREADY KNOWING IT. That hides precisely the alt the
-- player was looking for.
--
-- So the rule here, top to bottom:
--
--   * We store the LEARNED set and never the missing set. Missing is derived.
--   * A profession with no `k` bitmap and no `a` stamp has NEVER BEEN SCANNED.
--     That is a THIRD STATE, distinct from "knows nothing", and every reader
--     must render it as unknown. `Professions.KnownState()` is the one function
--     that answers the question, and it returns "unknown" / "known" / "not
--     known" — never a boolean.
--   * A window scan that could not resolve every row writes NOTHING. A partial
--     enumeration understates the known set, and an understated known set is a
--     confident lie about an alt.
--   * A cold or teardown moment writes nothing at all, in either direction.
--
----------------------------------------------------------------------
-- THE TWO WINDOWS (Era's split crafting API)
--
-- Era has two enumeration surfaces and they are not interchangeable:
--
--   TRADE_SKILL_*  every profession except enchanting. Rows are indexed;
--                  GetTradeSkillInfo gives a name and a row kind, and
--                  GetTradeSkillRecipeLink gives a link carrying the TEACHING
--                  SPELL ID — which is our primary key, so we match on ids and
--                  never on the localized display name (main spec §7 defect 8).
--
--   CRAFT_*        enchanting — and ALSO the hunter beast-training window,
--                  which is not a profession at all. CraftIsEnchanting() is the
--                  discriminator and this module refuses the craft window
--                  without it, so a hunter opening pet training can never be
--                  mistaken for an enchanter with an empty book.
--
-- Both are catalog-verified present at interface 11509: GetNumTradeSkills,
-- GetTradeSkillInfo, GetTradeSkillRecipeLink, GetTradeSkillNumReagents,
-- GetTradeSkillReagentInfo, GetTradeSkillReagentItemLink, GetTradeSkillItemLink,
-- GetTradeSkillNumMade, GetTradeSkillCooldown, GetTradeSkillLine, GetNumCrafts,
-- GetCraftInfo, GetCraftRecipeLink, GetCraftNumReagents, GetCraftReagentInfo,
-- GetCraftReagentItemLink, GetCraftCooldown, GetCraftDisplaySkillLine,
-- CraftIsEnchanting, GetNumSkillLines, GetSkillLineInfo, IsSpellKnown.
-- Events: TRADE_SKILL_SHOW/UPDATE/CLOSE (Event.TradeSkillUI.*), CRAFT_SHOW/
-- UPDATE/CLOSE (Event.CraftInfo.*), SKILL_LINES_CHANGED (Event.SkillInfo.*),
-- SPELLS_CHANGED (Event.SpellBook.*).
--
----------------------------------------------------------------------
-- REAGENTS — the second data source, because there is no first
--
-- The addendum's §2 finding is blunt: the examined dataset has NO reagents and
-- NO produced-item ids, for any of the 1,251 recipes. Materials linkage cannot
-- be sourced from it at all. The client, however, hands both over for free
-- while a profession window is open, so this module harvests them there and
-- caches them ACCOUNT-WIDE keyed by teaching-spell id — the same key everything
-- else joins on. One alt opening blacksmithing fills in blacksmithing's
-- reagents for every reader on the account.
--
-- The harvest does NOT ride the mesh in this wave. A reagent list is a GAME
-- FACT, identical on every account, so gossiping it would spend the wire on
-- something every peer can learn locally for free the first time any of their
-- own characters opens that window. The store keeps it beside the owners graph
-- so a later wave can decide otherwise without a migration.
--
----------------------------------------------------------------------
-- COOLDOWNS, AND THE ONE SHARED TIMER
--
-- Profession cooldowns are read the honest way: while a window is open and its
-- enumeration was PROVEN complete, every known row's cooldown is asked for
-- directly. Nothing is hard-coded — no list of which recipes have cooldowns, no
-- durations — so Mooncloth, Cured Rugged Hide, the Salt Shaker and the
-- transmutes are all covered by the same six lines, and a hotfix that changes a
-- duration changes nothing here.
--
-- The one thing that IS modelled is that alchemy's transmutes share a single
-- timer. Thirteen recipes, one cooldown: a reader treating them as thirteen
-- independent timers would show twelve wrong answers the moment one was used.
-- The dataset carries a cooldown-group ordinal per recipe (derived at
-- generation time) and the capture folds every member of a group onto one key.
--
-- Proof gates, both directions (CLIENT_ASYNC_LESSONS class 4):
--   * a cooldown is only written from a proven-complete scan of the window that
--     owns that profession;
--   * a proven "not on cooldown" DELETES the stored stamp — a gate that could
--     never clear would be a different lie;
--   * nothing at all is written cold, in teardown, or from a window whose
--     profession did not resolve.
--
----------------------------------------------------------------------
-- STORE — the shape P2 and P3 read (this is the contract; it is additive)
--
--   DaseekiNexusData.professions = {
--     schema     = 1,
--     owners     = { [ownerKey] = { rev, updatedAt, data = <payload> } },
--     reagents   = { [teachingSpellID] = { o = <producedItemID|nil>,
--                                          n = <units produced|nil>,
--                                          r = { [reagentItemID] = count } } },
--     reagentsAt = <epoch of the last harvest>,
--     reagentsDS = <dataset version the harvest was taken against>,
--   }
--
--   ownerKey is "Name-Realm" — per CHARACTER, exactly like the inventory
--   module's `bags` namespace, because professions are a character fact.
--
--   <payload>, the wire shape, frozen for this schema:
--     {
--       v  = 1,                       payload schema
--       ds = "<dataset version>",     the bitmap's coordinate system
--       ts = <epoch>,                 when this payload was built
--       p  = { [profKey] = {
--                l = <current skill>,      nil = unknown, NEVER 0-as-unknown
--                m = <skill cap>,          nil = unknown
--                t = <rank tier 1..4>,     nil = unknown
--                s = { <spec spell ids> }, absent = none learned (proven)
--                k = "<bitmap>",           ABSENT = NEVER SCANNED
--                n = <known count>,        absent with k absent
--                u = <known-but-not-in-our-dataset count>,   drift signal
--                a = <epoch of the last complete window scan>,
--              }, ... },
--       c  = { [cdKey] = <epoch the cooldown is ready> },
--     }
--
--   cdKey is the teaching spell id as a string, or "g<n>" for a shared-cooldown
--   group ("g1" is alchemy's transmutes).
--
--   A profKey present with `k` absent means: this character HAS the profession
--   (we proved it from the rank spells) and has NOT opened its window since we
--   started looking. Render the level, render the cooldowns, render the recipe
--   list as UNKNOWN. Do not render it as empty.
--
-- Clean-room: no third-party source was read. The facts come through our own
-- Room-1 addendum; the wire and store shapes are ours.

local ADDON, ns = ...

local Professions = {}
ns.Professions = Professions

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------

-- The mesh namespace key. Frozen: changing it forks the mesh.
local NS_KEY = "professions"
Professions.NS_KEY = NS_KEY

-- Payload schema. Bump only when a reader that ignores unknown fields would be
-- WRONG rather than merely incomplete.
local PAYLOAD_VERSION = 1
Professions.PAYLOAD_VERSION = PAYLOAD_VERSION

-- The scheduler tier this namespace's pushes ride. "nspayload" is the backfill
-- tier (priority 6) — below live state (3) and below the inventory module's own
-- pushes (4). That is the owner's constraint expressed as a number: profession
-- data is a dashboard fact, and a dashboard fact must never be the reason a
-- pull timer or a buff state waited. A cooldown consumption still publishes
-- IMMEDIATELY; immediacy is about skipping the debounce, not about jumping the
-- queue.
local PUSH_OP = "nspayload"
Professions.PUSH_OP = PUSH_OP

local PUBLISH_DEBOUNCE     = 5     -- seconds; a burst of window updates coalesces
local ENTERING_WORLD_GRACE = 5     -- seconds after entering the world before we trust a read

Professions.PUBLISH_DEBOUNCE = PUBLISH_DEBOUNCE
Professions.ENTERING_WORLD_GRACE = ENTERING_WORLD_GRACE

-- Blizzard events the module subscribes to, on ITS OWN frame, only while
-- enabled. Listed here so the inertness self-test can assert the set rather
-- than trusting a comment.
Professions.EVENTS = {
    "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_CLOSE",
    "CRAFT_SHOW", "CRAFT_UPDATE", "CRAFT_CLOSE",
    "SKILL_LINES_CHANGED", "SPELLS_CHANGED",
    "PLAYER_ENTERING_WORLD", "PLAYER_LEAVING_WORLD", "PLAYER_LOGOUT",
}

-- Session state. All of it is nil/false until Activate() runs.
Professions._frame         = nil
Professions._activated     = false
Professions._lastSig       = nil
Professions._pending       = nil
Professions._dirtyTimer    = nil
Professions._leavingWorld  = false
Professions._loggingOut    = false
Professions._enteredWorldAt = nil
Professions._live          = nil    -- the capture we are accumulating this session
Professions._scanAt        = nil    -- GetTime of the last window scan (throttle)
Professions._staticAt      = nil    -- GetTime of the last presence/level probe (throttle)
Professions._harvested     = nil    -- profKey -> reagents already harvested this session

----------------------------------------------------------------------
-- Enablement
--
-- DEFAULT ON, and ABSENT ALSO MEANS ON — the house rule, so a SavedVariables
-- file written before this module existed behaves exactly like a fresh one.
----------------------------------------------------------------------

function Professions.IsEnabled()
    local S = ns.Store
    local db = S and S.GetSettings and S.GetSettings()
    if not db then return true end
    if db.professionsEnabled == nil then return true end
    return db.professionsEnabled and true or false
end

----------------------------------------------------------------------
-- Teardown latch and the capture gate
----------------------------------------------------------------------

function Professions.IsTeardown()
    return (Professions._loggingOut or Professions._leavingWorld) and true or false
end

function Professions.SinceEnteringWorld()
    local at = Professions._enteredWorldAt
    if not at then return math.huge end
    local now = (GetTime and GetTime()) or 0
    local d = now - at
    if d < 0 then return 0 end
    return d
end

-- The single gate every capture consults. False => the client's answers are (or
-- may be) cold, so we produce nothing rather than an honest-looking empty scan.
function Professions.CaptureAllowed()
    if Professions.IsTeardown() then return false end
    if Professions.SinceEnteringWorld() < ENTERING_WORLD_GRACE then return false end
    return true
end

----------------------------------------------------------------------
-- Identity — byte-identical to the inventory module's owner key, because both
-- name the same character and the dashboard joins them.
----------------------------------------------------------------------

function Professions.SelfKey()
    local name, realm
    if UnitFullName then
        local ok, n, r = pcall(UnitFullName, "player")
        if ok then name, realm = n, r end
    end
    if not name or name == "" then
        name = (UnitName and UnitName("player")) or ""
    end
    if not realm or realm == "" then
        realm = (GetNormalizedRealmName and GetNormalizedRealmName())
             or (GetRealmName and (GetRealmName():gsub("%s+", ""))) or ""
    end
    if name == "" then return "" end
    return name .. "-" .. realm
end

----------------------------------------------------------------------
-- THE DATASET, PARSED IN TWO STAGES
--
-- Stage CORE is everything the capture layer and the wire encoding need: the
-- profession list, the recipe index (spell id -> profession + ordinal + skill +
-- specialisation + cooldown group), the rank spells and the specialisations.
-- ~1,300 rows.
--
-- Stage SOURCES is the "where do I get it" graph: acquisition relations, the
-- NPC / zone / quest / object / event / faction indices, the trainer sets and
-- the recipe-item table. ~1,900 more rows, and NOTHING in the capture or
-- publish path touches any of it, so it is not built until a view asks.
--
-- Both stages are dropped by Unload(), which the enable toggle calls. That is
-- what "a disabled module holds no dataset" means for a single-folder addon:
-- the string constant is bytes the client read off disk anyway, and zero tables
-- are built from it.
----------------------------------------------------------------------

local Dataset = {}
Professions.Dataset = Dataset

Dataset.core    = false
Dataset.sources = false

local function rawText()
    return ns.ProfessionsDataRaw
end

function Dataset.Meta()
    return ns.ProfessionsDataMeta
end

function Dataset.Version()
    local m = ns.ProfessionsDataMeta
    return (m and m.version) or "?"
end

function Dataset.Unload()
    Dataset.core, Dataset.sources = false, false
    Dataset.profs, Dataset.profIdx = nil, nil
    Dataset.recipe, Dataset.profRecipes = nil, nil
    Dataset.ranks, Dataset.rankSpell = nil, nil
    Dataset.specs, Dataset.specById = nil, nil
    Dataset.note, Dataset.zone, Dataset.npc = nil, nil, nil
    Dataset.quest, Dataset.object, Dataset.event = nil, nil, nil
    Dataset.faction, Dataset.standing, Dataset.trainerSet = nil, nil, nil
    Dataset.item, Dataset.acq, Dataset.itemAcq = nil, nil, nil
    Dataset.itemOfRecipe = nil
end

-- PURE. Walk the payload once, handing each row to `fn(section, line)`. Rows
-- are already sorted by the generator, so the walk is deterministic (class 8)
-- without any sorting here.
function Dataset.Walk(raw, fn)
    if type(raw) ~= "string" or raw == "" then return false end
    local section
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        if line ~= "" then
            local s = line:match("^%[(%a+)%]$")
            if s then
                section = s
            elseif section then
                fn(section, line)
            end
        end
    end
    return true
end

local function splitFields(line)
    local out = {}
    local start = 1
    while true do
        local i = line:find("|", start, true)
        if not i then out[#out + 1] = line:sub(start) break end
        out[#out + 1] = line:sub(start, i - 1)
        start = i + 1
    end
    return out
end
Professions.SplitFields = splitFields

function Dataset.LoadCore()
    if Dataset.core then return true end
    local raw = rawText()
    if type(raw) ~= "string" or raw == "" then return false end

    local profs, profIdx = {}, {}
    local recipe, profRecipes = {}, {}
    local ranks, rankSpell = {}, {}
    local specs, specById = {}, {}

    local ok = Dataset.Walk(raw, function(section, line)
        if section == "prof" then
            local f = splitFields(line)
            local idx = tonumber(f[1])
            profs[idx] = { key = f[2], name = f[3], n = tonumber(f[4]) or 0 }
            profIdx[f[2]] = idx
            profRecipes[idx] = {}
        elseif section == "recipe" then
            local f = splitFields(line)
            local p, spell = tonumber(f[1]), tonumber(f[2])
            local list = profRecipes[p]
            list[#list + 1] = spell
            recipe[spell] = {
                p = p, i = #list, s = tonumber(f[3]), ph = tonumber(f[4]),
                spec = tonumber(f[5]), m = tonumber(f[6]), cd = tonumber(f[7]),
            }
        elseif section == "rank" then
            local f = splitFields(line)
            local p, tier, spell = tonumber(f[1]), tonumber(f[2]), tonumber(f[3])
            ranks[p] = ranks[p] or {}
            ranks[p][tier] = {
                spell = spell, floor = tonumber(f[4]), ceil = tonumber(f[5]),
                clvl = tonumber(f[6]),
            }
            rankSpell[spell] = { p = p, tier = tier }
        elseif section == "spec" then
            local f = splitFields(line)
            local idx, id = tonumber(f[1]), tonumber(f[2])
            specs[idx] = { id = id, p = tonumber(f[3]), minSkill = tonumber(f[4]),
                           quest = tonumber(f[5]), name = f[6] }
            specById[id] = idx
        end
    end)
    if not ok then return false end

    Dataset.profs, Dataset.profIdx = profs, profIdx
    Dataset.recipe, Dataset.profRecipes = recipe, profRecipes
    Dataset.ranks, Dataset.rankSpell = ranks, rankSpell
    Dataset.specs, Dataset.specById = specs, specById
    Dataset.core = true
    return true
end

function Dataset.LoadSources()
    if Dataset.sources then return true end
    if not Dataset.LoadCore() then return false end
    local raw = rawText()

    local note, zone, npc, quest, object, event = {}, {}, {}, {}, {}, {}
    local faction, standing, trainerSet = {}, {}, {}
    local item, acq, itemAcq, itemOfRecipe = {}, {}, {}, {}

    Dataset.Walk(raw, function(section, line)
        local f = splitFields(line)
        if section == "note" then
            note[tonumber(f[1])] = f[2]
        elseif section == "zone" then
            zone[tonumber(f[1])] = { id = tonumber(f[2]), cont = tonumber(f[3]),
                                     lmin = tonumber(f[4]), lmax = tonumber(f[5]), name = f[6] }
        elseif section == "npc" then
            npc[tonumber(f[1])] = {
                zone = tonumber(f[2]),
                x = (tonumber(f[3]) >= 0) and (tonumber(f[3]) / 100) or nil,
                y = (tonumber(f[4]) >= 0) and (tonumber(f[4]) / 100) or nil,
                stance = f[5], lmin = tonumber(f[6]), lmax = tonumber(f[7]),
                elite = f[8] == "1", name = f[9],
            }
        elseif section == "quest" then
            quest[tonumber(f[1])] = { lvl = tonumber(f[2]), givers = f[3], name = f[4] }
        elseif section == "object" then
            object[tonumber(f[1])] = { zone = tonumber(f[2]), name = f[3] }
        elseif section == "event" then
            event[tonumber(f[1])] = f[2]
        elseif section == "faction" then
            faction[tonumber(f[1])] = f[2]
        elseif section == "standing" then
            standing[tonumber(f[1])] = f[2]
        elseif section == "trainerset" then
            trainerSet[tonumber(f[1]) .. ":" .. tonumber(f[2])] = f[3]
        elseif section == "item" then
            local id = tonumber(f[2])
            item[id] = { p = tonumber(f[1]), q = tonumber(f[3]), ph = tonumber(f[4]),
                         flags = f[5] }
            itemAcq[id] = f[6]
        elseif section == "recipe" then
            local spell = tonumber(f[2])
            acq[spell] = f[8]
            for tid in tostring(f[8]):gmatch("I(%d+)") do
                itemOfRecipe[tonumber(tid)] = spell
            end
        end
    end)

    Dataset.note, Dataset.zone, Dataset.npc = note, zone, npc
    Dataset.quest, Dataset.object, Dataset.event = quest, object, event
    Dataset.faction, Dataset.standing, Dataset.trainerSet = faction, standing, trainerSet
    Dataset.item, Dataset.acq, Dataset.itemAcq = item, acq, itemAcq
    Dataset.itemOfRecipe = itemOfRecipe
    Dataset.sources = true
    return true
end

function Dataset.IsLoaded() return Dataset.core and true or false end

-- Convenience readers used by the capture layer.
function Dataset.RecipeCount(profKey)
    if not Dataset.LoadCore() then return 0 end
    local idx = Dataset.profIdx[profKey]
    if not idx then return 0 end
    return #(Dataset.profRecipes[idx] or {})
end

function Dataset.ProfKey(idx)
    if not Dataset.LoadCore() then return nil end
    local p = Dataset.profs[idx]
    return p and p.key or nil
end

----------------------------------------------------------------------
-- THE BITMAP CODEC  (PURE — no client API, no dataset lookup)
--
-- Six bits per character over a 64-symbol alphabet that is safe in every
-- transport the suite uses: the addon channel, LibSerialize, the file mirror,
-- and a chat log a user might paste into a bug report. Bit 1 is the dataset's
-- first recipe for that profession, LSB first inside each group, so the string
-- is stable and diffable — two characters with the same recipes produce
-- byte-identical bitmaps regardless of the order the client enumerated them
-- (class 8: the encoding cannot inherit iteration luck).
----------------------------------------------------------------------

local B64 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz+-"
local B64R = {}
for i = 1, #B64 do B64R[B64:sub(i, i)] = i - 1 end

-- indexSet: { [ordinal] = true }. n: how many ordinals this profession has.
-- Returns a string of ceil(n/6) characters, or "" when n is 0.
function Professions.EncodeBits(indexSet, n)
    n = tonumber(n) or 0
    if n <= 0 then return "" end
    local chars = {}
    local groups = math.ceil(n / 6)
    for g = 1, groups do
        local v, bit = 0, 1
        for b = 1, 6 do
            local idx = (g - 1) * 6 + b
            if idx <= n and indexSet and indexSet[idx] then v = v + bit end
            bit = bit * 2
        end
        chars[g] = B64:sub(v + 1, v + 1)
    end
    return table.concat(chars)
end

-- Returns set, count — or nil when the string is not decodable against n
-- (wrong length, a symbol outside the alphabet, a bit set past n). nil is
-- "cannot answer", which every reader must render as unknown.
function Professions.DecodeBits(str, n)
    n = tonumber(n) or 0
    if type(str) ~= "string" then return nil end
    if n <= 0 then
        if str == "" then return {}, 0 end
        return nil
    end
    if #str ~= math.ceil(n / 6) then return nil end
    local set, count = {}, 0
    for g = 1, #str do
        local v = B64R[str:sub(g, g)]
        if v == nil then return nil end
        local bit = 1
        for b = 1, 6 do
            local idx = (g - 1) * 6 + b
            if v % (bit * 2) >= bit then
                if idx > n then return nil end     -- a bit past the end is corruption
                set[idx] = true
                count = count + 1
            end
            bit = bit * 2
        end
    end
    return set, count
end

-- Spell ids -> the bitmap for one profession, plus how many of them our
-- dataset does not carry (a drift signal, never silently swallowed).
function Professions.EncodeKnown(profKey, spellIds)
    if not Dataset.LoadCore() then return nil, 0, 0 end
    local idx = Dataset.profIdx[profKey]
    if not idx then return nil, 0, 0 end
    local n = #(Dataset.profRecipes[idx] or {})
    local set, known, unknown = {}, 0, 0
    for i = 1, #spellIds do
        local r = Dataset.recipe[spellIds[i]]
        if r and r.p == idx then
            if not set[r.i] then known = known + 1 end
            set[r.i] = true
        else
            unknown = unknown + 1
        end
    end
    return Professions.EncodeBits(set, n), known, unknown
end

-- The bitmap back to spell ids, in dataset order. nil when the payload's
-- dataset version does not match ours: a bitmap is only meaningful against the
-- ordering it was written under.
function Professions.DecodeKnown(profKey, bits, payloadDS)
    if payloadDS ~= nil and payloadDS ~= Dataset.Version() then return nil end
    if not Dataset.LoadCore() then return nil end
    local idx = Dataset.profIdx[profKey]
    if not idx then return nil end
    local list = Dataset.profRecipes[idx] or {}
    local set = Professions.DecodeBits(bits, #list)
    if not set then return nil end
    local out = {}
    for i = 1, #list do
        if set[i] then out[#out + 1] = list[i] end
    end
    return out
end

----------------------------------------------------------------------
-- THE THREE-STATE ANSWER
--
-- The one function every reader (tooltip, panel, search) must go through.
-- Returns "unknown" | "known" | "missing", plus the character's skill in that
-- profession when we have it. There is no boolean form on purpose.
----------------------------------------------------------------------

function Professions.KnownState(payload, profKey, spellID)
    if type(payload) ~= "table" then return "unknown" end
    local p = payload.p and payload.p[profKey]
    if not p then return "unknown" end            -- no such profession recorded
    if p.k == nil or p.a == nil then return "unknown", p.l end   -- never scanned
    local ids = Professions.DecodeKnown(profKey, p.k, payload.ds)
    if not ids then return "unknown", p.l end     -- undecodable => unknown, never false
    for i = 1, #ids do
        if ids[i] == spellID then return "known", p.l end
    end
    return "missing", p.l
end

----------------------------------------------------------------------
-- PROFESSION PRESENCE, RANK AND SPECIALISATION  (id-keyed, locale-proof)
--
-- The addendum's §4.7 finding: rank detection in the examined implementation is
-- an equality test on the reported skill ceiling with a silent fall-through to
-- "apprentice", so any unexpected ceiling marks the character as missing every
-- tier. We do not infer the rank from a number at all — each rank tier IS a
-- spell, and IsSpellKnown answers for it directly. The rank is the highest tier
-- whose spell the character knows. There is nothing to fall through.
--
-- The same query answers "does this character have this profession" without
-- reading one localized string, which is what §7 defect 17's deviation asks for.
----------------------------------------------------------------------

-- A positive witness that the client's spell/skill data is populated. Class 6:
-- "no professions" and "the list has not been filled in yet" are the same
-- answer from an unwitnessed read, and only one of them may erase anything.
function Professions.SpellDataWitnessed()
    if not GetNumSkillLines then return false end
    local ok, n = pcall(GetNumSkillLines)
    return ok and type(n) == "number" and n > 0
end

-- Returns { [profKey] = { t = <tier>, s = { specIDs } } } or nil when the
-- client could not be witnessed. An EMPTY table is a real answer ("this
-- character has no professions") and is only ever produced under a witness.
function Professions.ProbeProfessions()
    if not Professions.CaptureAllowed() then return nil end
    if not IsSpellKnown then return nil end
    if not Professions.SpellDataWitnessed() then return nil end
    if not Dataset.LoadCore() then return nil end

    local out = {}
    for idx, prof in pairs(Dataset.profs) do
        local tiers = Dataset.ranks[idx]
        if tiers then
            local best
            for tier = 1, 4 do
                local t = tiers[tier]
                if t then
                    local ok, known = pcall(IsSpellKnown, t.spell)
                    if ok and known then best = tier end
                end
            end
            if best then out[prof.key] = { t = best, s = {} } end
        end
    end

    -- Specialisations: one spell query each, and only for a profession the
    -- character actually has (a specialisation without its profession is not a
    -- fact, it is a leak).
    for i = 1, #Dataset.specs do
        local sp = Dataset.specs[i]
        local key = Dataset.ProfKey(sp.p)
        local rec = key and out[key]
        if rec then
            local ok, known = pcall(IsSpellKnown, sp.id)
            if ok and known then rec.s[#rec.s + 1] = sp.id end
        end
    end
    for _, rec in pairs(out) do table.sort(rec.s) end
    return out
end

----------------------------------------------------------------------
-- SKILL LEVELS FROM THE SKILL PANEL
--
-- The window gives an authoritative level for the profession it is showing;
-- everything else (the gathering professions especially, which have no window
-- at all) can only come from the skill panel, and the skill panel speaks in
-- localized names.
--
-- So the name map is built from the CLIENT'S OWN spell names for the rank
-- spells — GetSpellInfo(2259) is "Alchemy" in whatever language the player
-- runs — with the dataset's English names as a second source. A name that
-- matches neither yields NOTHING: the level stays unknown. It never yields
-- zero, because zero is a claim and unknown is not.
----------------------------------------------------------------------

function Professions.SkillNameMap()
    if not Dataset.LoadCore() then return {} end
    local map = {}
    for idx, prof in pairs(Dataset.profs) do
        map[(prof.name or ""):lower()] = prof.key          -- shipped English fallback
        local tiers = Dataset.ranks[idx]
        if tiers and GetSpellInfo then
            for tier = 1, 4 do
                local t = tiers[tier]
                if t then
                    local ok, name = pcall(GetSpellInfo, t.spell)
                    if ok and type(name) == "string" and name ~= "" then
                        map[name:lower()] = prof.key       -- the client's own word for it
                    end
                end
            end
        end
    end
    return map
end

-- Returns { [profKey] = { l = rank, m = maxRank } } or nil when the panel could
-- not be read. Skill lines the map does not recognise are skipped in silence —
-- they are riding, defense, weapon skills and languages, none of which are ours.
function Professions.CaptureSkillLines()
    if not Professions.CaptureAllowed() then return nil end
    if not (GetNumSkillLines and GetSkillLineInfo) then return nil end
    local okN, n = pcall(GetNumSkillLines)
    if not okN or type(n) ~= "number" or n <= 0 then return nil end

    local map = Professions.SkillNameMap()
    local out = {}
    for i = 1, n do
        local ok, name, isHeader, _, rank, _, _, maxRank = pcall(GetSkillLineInfo, i)
        if ok and not isHeader and type(name) == "string" then
            local key = map[name:lower()]
            if key and type(rank) == "number" and type(maxRank) == "number" and maxRank > 0 then
                out[key] = { l = rank, m = maxRank }
            end
        end
    end
    return out
end

----------------------------------------------------------------------
-- THE TWO WINDOW ADAPTERS
--
-- Each returns a scan table, or nil plus a reason. nil is always "we could not
-- answer" and never "the answer is empty".
--
--   scan = { profKey, l, m, rows = { { i = <row index>, spell = <id> }, ... },
--            ids = { <spell ids> }, complete = true }
--
-- `complete` is not decoration. Blizzard's row APIs return nil for a row whose
-- item data has not arrived (main spec §7 defect 10), and a scan missing rows
-- understates the known set. So a scan is only usable when EVERY non-header row
-- resolved to a spell id; anything less returns nil and waits for the window's
-- own update event to re-fire.
----------------------------------------------------------------------

local function spellFromRecipeLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("enchant:(%d+)"))
end
Professions.SpellFromRecipeLink = spellFromRecipeLink

-- Which profession do these enumerated spell ids belong to? Majority is not
-- good enough: we require that the ids resolve to exactly one profession in the
-- dataset (ids we do not carry are counted separately and do not vote).
function Professions.ResolveProfession(ids)
    if not Dataset.LoadCore() then return nil, 0 end
    local votes, unknown = {}, 0
    for i = 1, #ids do
        local r = Dataset.recipe[ids[i]]
        if r then votes[r.p] = (votes[r.p] or 0) + 1 else unknown = unknown + 1 end
    end
    local best, bestN, ties = nil, 0, 0
    for p, n in pairs(votes) do
        if n > bestN then best, bestN, ties = p, n, 0
        elseif n == bestN then ties = ties + 1 end
    end
    if not best then return nil, unknown end
    return Dataset.ProfKey(best), unknown
end

function Professions.ScanTradeSkillWindow()
    if not Professions.CaptureAllowed() then return nil, "cold" end
    if not (GetNumTradeSkills and GetTradeSkillInfo and GetTradeSkillRecipeLink) then
        return nil, "no-api"
    end
    local okN, n = pcall(GetNumTradeSkills)
    if not okN or type(n) ~= "number" or n <= 0 then return nil, "empty" end

    local rows, ids, missed = {}, {}, 0
    for i = 1, n do
        local ok, name, kind = pcall(GetTradeSkillInfo, i)
        if not ok then return nil, "row-error" end
        if kind ~= "header" and name ~= nil then
            local okL, link = pcall(GetTradeSkillRecipeLink, i)
            local spell = okL and spellFromRecipeLink(link) or nil
            if spell then
                rows[#rows + 1] = { i = i, spell = spell }
                ids[#ids + 1] = spell
            else
                missed = missed + 1
            end
        end
    end
    if #ids == 0 then return nil, "unresolved" end
    if missed > 0 then return nil, "incomplete" end

    local profKey, unknown = Professions.ResolveProfession(ids)
    if not profKey then return nil, "unidentified" end

    local scan = { profKey = profKey, rows = rows, ids = ids, unknown = unknown,
                   complete = true, surface = "tradeskill" }
    if GetTradeSkillLine then
        local ok, _, rank, maxRank = pcall(GetTradeSkillLine)
        if ok and type(rank) == "number" and type(maxRank) == "number" and maxRank > 0 then
            scan.l, scan.m = rank, maxRank
        end
    end
    return scan
end

function Professions.ScanCraftWindow()
    if not Professions.CaptureAllowed() then return nil, "cold" end
    -- The craft surface is shared with hunter beast training, which is not a
    -- profession. This is the discriminator, and it is a refusal, not a filter.
    if not CraftIsEnchanting then return nil, "no-api" end
    local okE, isEnch = pcall(CraftIsEnchanting)
    if not okE or not isEnch then return nil, "not-a-profession" end
    if not (GetNumCrafts and GetCraftInfo and GetCraftRecipeLink) then return nil, "no-api" end

    local okN, n = pcall(GetNumCrafts)
    if not okN or type(n) ~= "number" or n <= 0 then return nil, "empty" end

    local rows, ids, missed = {}, {}, 0
    for i = 1, n do
        local ok, name, _, kind = pcall(GetCraftInfo, i)
        if not ok then return nil, "row-error" end
        if kind ~= "header" and name ~= nil then
            local okL, link = pcall(GetCraftRecipeLink, i)
            local spell = okL and spellFromRecipeLink(link) or nil
            if spell then
                rows[#rows + 1] = { i = i, spell = spell }
                ids[#ids + 1] = spell
            else
                missed = missed + 1
            end
        end
    end
    if #ids == 0 then return nil, "unresolved" end
    if missed > 0 then return nil, "incomplete" end

    local profKey, unknown = Professions.ResolveProfession(ids)
    if not profKey then return nil, "unidentified" end

    local scan = { profKey = profKey, rows = rows, ids = ids, unknown = unknown,
                   complete = true, surface = "craft" }
    if GetCraftDisplaySkillLine then
        local ok, _, rank, maxRank = pcall(GetCraftDisplaySkillLine)
        if ok and type(rank) == "number" and type(maxRank) == "number" and maxRank > 0 then
            scan.l, scan.m = rank, maxRank
        end
    end
    return scan
end

----------------------------------------------------------------------
-- COOLDOWNS
--
-- Folded from a proven-complete scan. The group rule collapses alchemy's
-- transmutes onto one key; everything else keys on its own teaching spell id.
-- Returns { [cdKey] = readyAtEpoch } for the RUNNING cooldowns and a second
-- table of every key this scan PROVED is not running, which is what licenses a
-- delete.
----------------------------------------------------------------------

function Professions.FoldCooldowns(scan, now, reader)
    if not (scan and scan.complete) then return nil, nil end
    if not Dataset.LoadCore() then return nil, nil end
    -- Explicit branch rather than an `and/or` chain: with `or` fallthrough, a
    -- craft window on a client missing GetCraftCooldown would quietly read the
    -- TRADE-SKILL cooldown API against craft row indexes, which is a different
    -- recipe's answer wearing this one's name.
    if not reader then
        if scan.surface == "craft" then reader = GetCraftCooldown
        else reader = GetTradeSkillCooldown end
    end
    if not reader then return nil, nil end
    now = tonumber(now) or 0

    local running, proven = {}, {}
    for r = 1, #scan.rows do
        local row = scan.rows[r]
        local rec = Dataset.recipe[row.spell]
        if rec then
            local key = (rec.cd and rec.cd > 0) and ("g" .. rec.cd) or tostring(row.spell)
            proven[key] = true
            local ok, secs = pcall(reader, row.i)
            if ok and type(secs) == "number" and secs > 0 then
                local readyAt = math.floor(now + secs)
                if not running[key] or readyAt > running[key] then running[key] = readyAt end
            end
        end
    end
    return running, proven
end

----------------------------------------------------------------------
-- REAGENT HARVEST
--
-- The materials-linkage data source, because the recipe catalogue has none.
-- Per recipe: every reagent's item id and required count, the produced item id,
-- and how many the craft yields.
--
-- Class 4 all the way through: an item link that has not arrived yet reads as
-- nil, and a PARTIAL reagent list understates a craft's cost, which is worse
-- than no list at all. So a recipe whose reagents did not all resolve is left
-- alone — the stored entry (if any) survives untouched and the next window
-- update tries again.
----------------------------------------------------------------------

local function itemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end
Professions.ItemIDFromLink = itemIDFromLink

-- PURE-ish: every client call is injectable through `api` so the harness can
-- drive cold, warm and half-warm worlds without a client.
function Professions.HarvestReagents(scan, api)
    if not (scan and scan.complete) then return nil end
    api = api or {}
    local craft = (scan.surface == "craft")
    -- One surface's getters, chosen by an explicit branch. An `and/or` chain
    -- would fall through to the OTHER surface's API when one is missing, and
    -- reading trade-skill row 4's reagents for craft row 4 is a wrong answer
    -- that looks exactly like a right one.
    local numReagents, reagentInfo, reagentLink, itemLink, numMade
    if craft then
        numReagents = GetCraftNumReagents
        reagentInfo = GetCraftReagentInfo
        reagentLink = GetCraftReagentItemLink
        itemLink    = GetCraftItemLink
        numMade     = nil                      -- an enchant makes no item to count
    else
        numReagents = GetTradeSkillNumReagents
        reagentInfo = GetTradeSkillReagentInfo
        reagentLink = GetTradeSkillReagentItemLink
        itemLink    = GetTradeSkillItemLink
        numMade     = GetTradeSkillNumMade
    end
    numReagents = api.numReagents or numReagents
    reagentInfo = api.reagentInfo or reagentInfo
    reagentLink = api.reagentLink or reagentLink
    itemLink    = api.itemLink    or itemLink
    numMade     = api.numMade     or numMade
    if not (numReagents and reagentInfo and reagentLink) then return nil end

    local out = {}
    for r = 1, #scan.rows do
        local row = scan.rows[r]
        local okN, n = pcall(numReagents, row.i)
        if okN and type(n) == "number" and n > 0 then
            local list, complete = {}, true
            for j = 1, n do
                local okI, _, _, count = pcall(reagentInfo, row.i, j)
                local okL, link = pcall(reagentLink, row.i, j)
                local id = okL and itemIDFromLink(link) or nil
                if okI and id and type(count) == "number" and count > 0 then
                    list[id] = (list[id] or 0) + count
                else
                    complete = false
                end
            end
            if complete then
                local entry = { r = list }
                if itemLink then
                    local okP, link = pcall(itemLink, row.i)
                    if okP then entry.o = itemIDFromLink(link) end
                end
                if numMade then
                    local okM, lo = pcall(numMade, row.i)
                    if okM and type(lo) == "number" and lo > 0 then entry.n = lo end
                end
                out[row.spell] = entry
            end
        end
    end
    return out
end

----------------------------------------------------------------------
-- THE LIVE RECORD
--
-- One session-scoped table that every capture half writes into and the payload
-- builder reads. It is deliberately NOT the stored payload: a half that could
-- not answer leaves its field alone, so the record is always the best answer we
-- have rather than the most recent attempt.
----------------------------------------------------------------------

local function live()
    if not Professions._live then
        Professions._live = { p = {}, c = {} }
    end
    return Professions._live
end
Professions.Live = live

-- Seed the live record from what we have already published for this character,
-- so a session that never opens a window still republishes the truth instead of
-- forgetting it. This is the "absence is not zero" rule applied across logins.
function Professions.SeedFromStore()
    local S = ns.Store
    if not (S and S.ProfessionsGet) then return false end
    local e = S.ProfessionsGet(Professions.SelfKey())
    local d = e and e.data
    if type(d) ~= "table" then return false end
    local L = live()
    if type(d.p) == "table" then
        for key, rec in pairs(d.p) do
            local cur = L.p[key] or {}
            for k, v in pairs(rec) do
                if cur[k] == nil then cur[k] = v end
            end
            L.p[key] = cur
        end
    end
    if type(d.c) == "table" then
        for key, at in pairs(d.c) do
            if L.c[key] == nil then L.c[key] = at end
        end
    end
    return true
end

-- Merge a professions probe (presence, rank, specialisations) into the record.
function Professions.ApplyProbe(probe)
    if type(probe) ~= "table" then return false end
    local L = live()
    for key, rec in pairs(probe) do
        local cur = L.p[key] or {}
        cur.t = rec.t
        cur.s = (#rec.s > 0) and rec.s or nil
        L.p[key] = cur
    end
    -- A profession the witness says this character no longer has is dropped —
    -- professions CAN be unlearned, and a stale row would claim a skill the
    -- character does not have. Secondary professions cannot be unlearned, but
    -- the witness answers for them too, so no exception is needed.
    for key in pairs(L.p) do
        if not probe[key] then L.p[key] = nil end
    end
    return true
end

function Professions.ApplySkillLines(levels)
    if type(levels) ~= "table" then return false end
    local L = live()
    for key, v in pairs(levels) do
        local cur = L.p[key]
        if cur then                       -- only for a profession we proved exists
            cur.l, cur.m = v.l, v.m
        end
    end
    return true
end

-- The window scan: the authoritative half. This is the only writer of `k`.
function Professions.ApplyScan(scan, now)
    if not (scan and scan.complete and scan.profKey) then return false end
    local L = live()
    local cur = L.p[scan.profKey] or {}
    local bits, known, unknown = Professions.EncodeKnown(scan.profKey, scan.ids)
    if bits == nil then return false end
    cur.k, cur.n, cur.u = bits, known, unknown
    cur.a = tonumber(now) or 0
    if scan.l then cur.l = scan.l end
    if scan.m then cur.m = scan.m end
    L.p[scan.profKey] = cur
    return true
end

-- Cooldowns from a proven scan. Returns true when a cooldown STARTED or moved
-- later — the caller publishes that immediately rather than on the debounce,
-- because "can I transmute today" is the question the whole cooldown feature
-- exists to answer and a five-second lie is still a lie.
function Professions.ApplyCooldowns(running, proven)
    if type(running) ~= "table" or type(proven) ~= "table" then return false, false end
    local L = live()
    local consumed = false
    for key in pairs(proven) do
        local was = L.c[key]
        local now = running[key]
        if now then
            if not was or now > was then consumed = true end
            L.c[key] = now
        else
            -- PROVEN not running: the delete is licensed precisely because the
            -- scan that answered was complete and owned this profession.
            L.c[key] = nil
        end
    end
    return true, consumed
end

----------------------------------------------------------------------
-- PAYLOAD
----------------------------------------------------------------------

function Professions.BuildPayload()
    if not Professions.IsEnabled() then return nil end
    local L = Professions._live
    if not L then return nil end
    local anything = false
    for _ in pairs(L.p) do anything = true break end
    if not anything then
        for _ in pairs(L.c) do anything = true break end
    end
    if not anything then return nil end

    local p = {}
    for key, rec in pairs(L.p) do
        local out = { l = rec.l, m = rec.m, t = rec.t, k = rec.k, n = rec.n,
                      u = (rec.u and rec.u > 0) and rec.u or nil, a = rec.a }
        if rec.s and #rec.s > 0 then
            local s = {}
            for i = 1, #rec.s do s[i] = rec.s[i] end
            table.sort(s)
            out.s = s
        end
        p[key] = out
    end

    local c = nil
    for key, at in pairs(L.c) do
        c = c or {}
        c[key] = at
    end

    return {
        v = PAYLOAD_VERSION,
        ds = Dataset.Version(),
        ts = (ns.Store and ns.Store.Now and ns.Store.Now()) or (time and time()) or 0,
        p = p,
        c = c,
    }
end

-- PURE. The delta detector. `ts` is deliberately absent — it moves on every
-- capture, and including it is identical to having no detector at all. `a` (the
-- per-profession scan stamp) is absent for the same reason: re-opening a window
-- and finding nothing new must not re-rev the namespace, because a churning rev
-- hash makes every peer pull the WHOLE namespace on every heartbeat.
function Professions.PayloadSignature(payload)
    if type(payload) ~= "table" then return "" end
    local keys = {}
    for key in pairs(payload.p or {}) do keys[#keys + 1] = key end
    table.sort(keys)
    local out = { "v=" .. tostring(payload.v or 0), "ds=" .. tostring(payload.ds or "") }
    for i = 1, #keys do
        local r = payload.p[keys[i]]
        local specs = ""
        if type(r.s) == "table" then
            local s = {}
            for j = 1, #r.s do s[j] = tostring(r.s[j]) end
            table.sort(s)
            specs = table.concat(s, ",")
        end
        out[#out + 1] = table.concat({
            keys[i], tostring(r.l or ""), tostring(r.m or ""), tostring(r.t or ""),
            specs, tostring(r.k or ""), tostring(r.n or ""), tostring(r.u or ""),
        }, ":")
    end
    local ckeys = {}
    for key in pairs(payload.c or {}) do ckeys[#ckeys + 1] = key end
    table.sort(ckeys)
    for i = 1, #ckeys do
        out[#out + 1] = "cd:" .. ckeys[i] .. "=" .. tostring(payload.c[ckeys[i]])
    end
    return table.concat(out, "|")
end

function Professions.LastPublishedSignature(ownerKey)
    if Professions._lastSig ~= nil then return Professions._lastSig end
    local S = ns.Store
    local e = S and S.SyncNSGet and S.SyncNSGet(NS_KEY, ownerKey)
    if e and type(e.data) == "table" then
        return Professions.PayloadSignature(e.data)
    end
    return nil
end

function Professions.NextLocalRev(ownerKey)
    local S = ns.Store
    local mine = 0
    if S and S.ProfessionsGet then
        local e = S.ProfessionsGet(ownerKey)
        if e and tonumber(e.rev) then mine = tonumber(e.rev) end
    end
    if S and S.SyncNSGet then
        local e = S.SyncNSGet(NS_KEY, ownerKey)
        if e and tonumber(e.rev) and tonumber(e.rev) > mine then mine = tonumber(e.rev) end
    end
    return mine + 1
end

----------------------------------------------------------------------
-- PUBLISH
----------------------------------------------------------------------

local function suiteSync()
    local G = _G or getfenv(0)
    local D = G.Daseeki
    local S = D and D.Sync
    if S and S.RegisterNamespace and S.MarkDirty and S.Get then return S end
    return nil
end
Professions._suiteSync = suiteSync

local function provideSelf()
    local p = Professions._pending
    if p ~= nil then
        Professions._pending = nil
        return p
    end
    return Professions.BuildPayload()
end
Professions._provideFn = provideSelf

local function onRemoteOwner(ownerKey, data)
    local S = ns.Store
    if not (S and S.ProfessionsPut) then return end
    if type(ownerKey) ~= "string" or ownerKey == "" or type(data) ~= "table" then return end
    local e = S.SyncNSGet and S.SyncNSGet(NS_KEY, ownerKey)
    local rev = (e and tonumber(e.rev)) or 0
    local at  = (e and tonumber(e.updatedAt)) or (time and time()) or 0
    S.ProfessionsPut(ownerKey, rev, data, at)
end
Professions._onRemoteFn = onRemoteOwner

function Professions.RegisterNamespace()
    local S = suiteSync()
    if not S then return false end
    S.RegisterNamespace(NS_KEY, {
        ownerKey = function() return Professions.SelfKey() end,
        provide  = provideSelf,
        rev      = function() return Professions.NextLocalRev(Professions.SelfKey()) end,
        onRemote = onRemoteOwner,
        pushOp   = PUSH_OP,
    })
    return true
end

function Professions.ProjectOwner(ownerKey)
    local S = ns.Store
    if not (S and S.SyncNSGet and S.ProfessionsPut) then return false end
    local e = S.SyncNSGet(NS_KEY, ownerKey)
    if not (e and type(e.data) == "table") then return false end
    S.ProfessionsPut(ownerKey, tonumber(e.rev) or 0, e.data, tonumber(e.updatedAt) or 0)
    return true
end

-- Three outcomes, and the caller must tell the last two apart:
--   true          the payload CHANGED: rev bumped, stored, handed to the mesh.
--   "unchanged"   byte-for-byte what we already published. A settled state.
--   false         we could not answer (disabled, cold, teardown, no Sync).
function Professions.Publish(force)
    if not Professions.IsEnabled() then return false end
    if not Professions.CaptureAllowed() then return false end
    local S = suiteSync()
    if not S then return false end

    local ownerKey = Professions.SelfKey()
    if ownerKey == "" then return false end
    local payload = Professions.BuildPayload()
    if payload == nil then return false end

    local sig = Professions.PayloadSignature(payload)
    if not force and sig == Professions.LastPublishedSignature(ownerKey) then
        Professions._lastSig = sig
        return "unchanged"
    end

    Professions._pending = payload
    local ok = S.MarkDirty(NS_KEY)
    Professions._pending = nil
    if ok ~= true then return false end

    Professions._lastSig = sig
    Professions.ProjectOwner(ownerKey)
    return true
end

local function cancelDirty()
    if Professions._dirtyTimer then
        pcall(function() Professions._dirtyTimer:Cancel() end)
        Professions._dirtyTimer = nil
    end
end

-- `urgent` publishes NOW and cancels any pending debounce. The one urgent
-- caller is a cooldown that just started.
function Professions.MarkDirty(urgent)
    if not Professions.IsEnabled() then return false end
    if urgent then
        cancelDirty()
        return Professions.Publish() ~= false
    end
    if not (C_Timer and C_Timer.NewTimer) then
        return Professions.Publish() ~= false
    end
    cancelDirty()
    Professions._dirtyTimer = C_Timer.NewTimer(PUBLISH_DEBOUNCE, function()
        Professions._dirtyTimer = nil
        -- Only a hard `false` re-arms: "unchanged" is an answered question, and
        -- re-arming on it would spin the debounce forever on a quiet character.
        if Professions.Publish() == false then
            if not Professions.IsTeardown() and Professions.IsEnabled() then
                Professions.MarkDirty()
            end
        end
    end)
    return true
end

----------------------------------------------------------------------
-- CAPTURE ENTRY POINTS
----------------------------------------------------------------------

-- The cheap half: presence, rank, specialisations, skill levels. Runs on login
-- and on the skill/spell change events. Never touches a window.
--
-- SPELLS_CHANGED arrives in bursts (login, a talent respec, any spell learned),
-- so the probe is throttled: 59 spell queries plus a skill-panel walk is small
-- but it is not free, and re-asking it eight times in one frame answers nothing
-- new. `force` is for the caller that knows something changed.
function Professions.CaptureStatic(force)
    if not Professions.IsEnabled() then return false end
    if not Professions.CaptureAllowed() then return false end
    local now = (GetTime and GetTime()) or 0
    if not force and Professions._staticAt and (now - Professions._staticAt) < 3 then
        return false
    end
    Professions._staticAt = now
    local probe = Professions.ProbeProfessions()
    if not probe then return false end
    Professions.ApplyProbe(probe)
    local levels = Professions.CaptureSkillLines()
    if levels then Professions.ApplySkillLines(levels) end
    return true
end

-- The authoritative half: an open window. `surface` is "tradeskill" or "craft".
--
-- THROTTLE. The window's update event fires on every craft, and a full scan of
-- a 300-row profession is ~300 link reads plus ~300 cooldown reads. Crafting a
-- stack of potions would otherwise re-ask the same questions dozens of times a
-- second. `force` (the window's SHOW) always scans; an update inside the window
-- coalesces. One second is short enough that a cooldown that just started is
-- still published within the same breath.
function Professions.CaptureWindow(surface, force)
    if not Professions.IsEnabled() then return false, "disabled" end
    if not Professions.CaptureAllowed() then return false, "cold" end
    local now = (GetTime and GetTime()) or 0
    if not force and Professions._scanAt and (now - Professions._scanAt) < 1 then
        return false, "throttled"
    end
    Professions._scanAt = now
    local scan, why
    if surface == "craft" then scan, why = Professions.ScanCraftWindow()
    else scan, why = Professions.ScanTradeSkillWindow() end
    if not scan then return false, why end

    local stamp = (ns.Store and ns.Store.Now and ns.Store.Now()) or (time and time()) or 0
    Professions.ApplyScan(scan, stamp)

    local running, proven = Professions.FoldCooldowns(scan, stamp)
    local consumed = false
    if running and proven then
        local _, c = Professions.ApplyCooldowns(running, proven)
        consumed = c
    end

    -- Reagents are a GAME FACT and do not change while the window is open —
    -- or between two logins, for that matter. Harvesting once per profession
    -- per session keeps a crafting spree from re-reading every reagent link of
    -- every recipe on every craft.
    Professions._harvested = Professions._harvested or {}
    if not Professions._harvested[scan.profKey] then
        local reagents = Professions.HarvestReagents(scan)
        if reagents then
            Professions.StoreReagents(reagents)
            Professions._harvested[scan.profKey] = true
        end
    end

    Professions.MarkDirty(consumed)
    return true, scan.profKey, consumed
end

function Professions.StoreReagents(harvest)
    local S = ns.Store
    if not (S and S.ProfessionsReagents) then return false end
    local area = S.ProfessionsReagents(true)
    if not area then return false end
    local n = 0
    for spell, entry in pairs(harvest) do
        area[spell] = entry
        n = n + 1
    end
    if n > 0 and S.ProfessionsArea then
        local a = S.ProfessionsArea()
        if a then
            a.reagentsAt = (S.Now and S.Now()) or (time and time()) or 0
            a.reagentsDS = Dataset.Version()
        end
    end
    return n
end

----------------------------------------------------------------------
-- LIFECYCLE
--
-- Nothing here runs at file scope. Activate() is the first moment this module
-- creates a frame, registers a Blizzard event, or writes a saved-variable key —
-- and it refuses to run at all while the module is disabled. That is the
-- behavioral spec's inertness rule taken literally: "disabled" means not
-- loaded, not "loaded and hidden".
----------------------------------------------------------------------

local function onEvent(_, event, ...)
    if not Professions.IsEnabled() then return end
    if event == "PLAYER_ENTERING_WORLD" then
        Professions._leavingWorld = false
        Professions._enteredWorldAt = (GetTime and GetTime()) or 0
        if C_Timer and C_Timer.After then
            C_Timer.After(ENTERING_WORLD_GRACE + 1, function()
                if Professions.IsEnabled() then
                    Professions.CaptureStatic()
                    Professions.MarkDirty()
                end
            end)
        end
    elseif event == "PLAYER_LEAVING_WORLD" then
        Professions._leavingWorld = true
        cancelDirty()
    elseif event == "PLAYER_LOGOUT" then
        Professions._loggingOut = true
        cancelDirty()
    elseif event == "TRADE_SKILL_SHOW" then
        Professions.CaptureWindow("tradeskill", true)
    elseif event == "TRADE_SKILL_UPDATE" then
        Professions.CaptureWindow("tradeskill")
    elseif event == "CRAFT_SHOW" then
        Professions.CaptureWindow("craft", true)
    elseif event == "CRAFT_UPDATE" then
        Professions.CaptureWindow("craft")
    elseif event == "TRADE_SKILL_CLOSE" or event == "CRAFT_CLOSE" then
        -- Nothing to tear down: the scan already wrote what it proved. The
        -- close is only interesting as a publish opportunity.
        Professions.MarkDirty()
    elseif event == "SKILL_LINES_CHANGED" or event == "SPELLS_CHANGED" then
        if Professions.CaptureStatic() then Professions.MarkDirty() end
    end
end
Professions._onEvent = onEvent

function Professions.Activate()
    if Professions._activated then return true end
    if not Professions.IsEnabled() then return false end
    Professions._activated = true

    if not Professions._frame and CreateFrame then
        local f = CreateFrame("Frame")
        f:SetScript("OnEvent", onEvent)
        for i = 1, #Professions.EVENTS do
            pcall(function() f:RegisterEvent(Professions.EVENTS[i]) end)
        end
        Professions._frame = f
    end

    Dataset.LoadCore()
    Professions.SeedFromStore()
    Professions.RegisterNamespace()

    local S = suiteSync()
    if S and S.DeliverRemote then pcall(S.DeliverRemote, NS_KEY) end

    Professions.CaptureStatic()
    if C_Timer and C_Timer.After then
        C_Timer.After(ENTERING_WORLD_GRACE + 2, function()
            if Professions.IsEnabled() then Professions.MarkDirty() end
        end)
    end
    return true
end

-- The settings toggle. Off drops EVERYTHING this module built: the frame and
-- its event registrations, the debounce timer, the parsed dataset and the live
-- capture. Stored data on disk is left alone (the spec's "retained but stale"
-- rule) — a player who turns it back on keeps their alts.
function Professions.SetEnabled(on)
    local S = ns.Store
    local db = S and S.GetSettings and S.GetSettings()
    if db then db.professionsEnabled = on and true or false end
    if on then
        if not Professions._activated then
            Professions.Activate()
        else
            Professions.CaptureStatic()
            Professions.MarkDirty()
        end
    else
        cancelDirty()
        if Professions._frame then
            pcall(function() Professions._frame:UnregisterAllEvents() end)
            pcall(function() Professions._frame:SetScript("OnEvent", nil) end)
            pcall(function() Professions._frame:Hide() end)
            Professions._frame = nil
        end
        Professions._activated = false
        Professions._live = nil
        Professions._lastSig = nil
        Professions._scanAt, Professions._staticAt = nil, nil
        Professions._harvested = nil
        Dataset.Unload()
    end
    return Professions.IsEnabled()
end

-- Login arrives on the LOCAL callback bus, not on a Blizzard event: subscribing
-- to PLAYER_LOGIN would mean a disabled module still holds an event
-- registration, which the inertness rule forbids. core.lua fires "LOGIN" after
-- the store is up.
ns:On("LOGIN", function()
    if not Professions.IsEnabled() then return end
    Professions._enteredWorldAt = Professions._enteredWorldAt or ((GetTime and GetTime()) or 0)
    Professions.Activate()
end)

----------------------------------------------------------------------
-- DIAGNOSTICS
----------------------------------------------------------------------

ns:RegisterDebugCommand("professions", function()
    local P = Professions
    ns:Print("professions: module " .. (P.IsEnabled() and "enabled" or "DISABLED")
        .. ", " .. (P._activated and "active" or "inactive")
        .. ", frame " .. (P._frame and "up" or "none"))
    local meta = Dataset.Meta()
    ns:Print(string.format("  dataset %s: %s (%s), core %s, sources %s",
        Dataset.Version(),
        meta and (tostring(meta.recipes) .. " recipes / " .. tostring(meta.items)
            .. " recipe-items / " .. tostring(meta.npcs) .. " NPCs") or "NOT SHIPPED",
        meta and meta.era or "?",
        Dataset.core and "parsed" or "not parsed",
        Dataset.sources and "parsed" or "not parsed"))

    local ownerKey = P.SelfKey()
    ns:Print("  owner key: " .. (ownerKey ~= "" and ownerKey or "(unresolved)")
        .. " | capture " .. (P.CaptureAllowed() and "allowed" or "gated")
        .. " (teardown " .. tostring(P.IsTeardown()) .. ")")

    local L = P._live
    if not L then
        ns:Print("  live capture: NONE this session")
    else
        local keys = {}
        for k in pairs(L.p) do keys[#keys + 1] = k end
        table.sort(keys)
        for i = 1, #keys do
            local r = L.p[keys[i]]
            ns:Print(string.format("    %-15s lvl %s/%s rank %s | recipes %s | drift %s | scanned %s",
                keys[i], tostring(r.l or "?"), tostring(r.m or "?"), tostring(r.t or "?"),
                r.k and tostring(r.n) or "NEVER SCANNED",
                tostring(r.u or 0),
                r.a and tostring(r.a) or "never"))
        end
        local ck = {}
        for k in pairs(L.c) do ck[#ck + 1] = k end
        table.sort(ck)
        for i = 1, #ck do
            ns:Print("    cooldown " .. ck[i] .. " ready at " .. tostring(L.c[ck[i]]))
        end
    end

    local sig = P._lastSig
    ns:Print("  last published signature: " .. (sig and (#sig .. " bytes") or "never published"))

    local S = ns.Store
    local owners = S and S.ProfessionsOwners and S.ProfessionsOwners() or {}
    local names = {}
    for k in pairs(owners) do names[#names + 1] = k end
    table.sort(names)
    ns:Print("  store: " .. #names .. " owner record(s)")
    for i = 1, #names do
        local e = owners[names[i]]
        local d = e and e.data or {}
        local profs = {}
        for k in pairs(d.p or {}) do profs[#profs + 1] = k end
        table.sort(profs)
        local parts = {}
        for j = 1, #profs do
            local r = d.p[profs[j]]
            parts[#parts + 1] = profs[j] .. " " .. tostring(r.l or "?")
                .. (r.k and ("/" .. tostring(r.n)) or "/unscanned")
        end
        ns:Print(string.format("    %-22s rev %s ds %s :: %s", names[i],
            tostring(e and e.rev), tostring(d.ds), table.concat(parts, ", ")))
    end
    local area = S and S.ProfessionsArea and S.ProfessionsArea()
    if area then
        local n = 0
        for _ in pairs(area.reagents or {}) do n = n + 1 end
        ns:Print("  reagent harvest: " .. n .. " recipe(s), taken " ..
            tostring(area.reagentsAt or "never") .. " against ds " .. tostring(area.reagentsDS or "?"))
    end
end)

----------------------------------------------------------------------
-- SELF-TESTS
----------------------------------------------------------------------

local function testDatasetIntegrity(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local meta = Dataset.Meta()
    ck(type(meta) == "table", "professions_data.lua did not ship ns.ProfessionsDataMeta")
    if type(meta) ~= "table" then return end
    ck(type(ns.ProfessionsDataRaw) == "string" and #ns.ProfessionsDataRaw > 1000,
       "ns.ProfessionsDataRaw is missing or implausibly small")

    ck(Dataset.LoadCore() == true, "the core dataset stage did not parse")

    -- The addendum's census, asserted row by row. A silently truncated dataset
    -- ships as "that recipe does not exist", which no user can tell from a real
    -- answer, so the counts are a hard gate rather than a comment.
    local WANT = {
        alchemy = 111, blacksmithing = 239, cooking = 81, enchanting = 151,
        engineering = 164, firstaid = 13, leatherworking = 233, mining = 12,
        poisons = 21, tailoring = 226, fishing = 0, herbalism = 0, skinning = 0,
    }
    local total = 0
    for key, want in pairs(WANT) do
        local got = Dataset.RecipeCount(key)
        ck(got == want, string.format("%s carries %d recipes, the census says %d", key, got, want))
        total = total + got
    end
    ck(total == 1251, "the catalogue holds " .. total .. " recipes, the census says 1251")
    ck(meta.recipes == 1251 and meta.items == 770 and meta.npcs == 734
       and meta.zones == 79 and meta.quests == 109 and meta.specs == 10
       and meta.ranks == 49, "the shipped meta counts do not match the census")

    -- Specialisations: 5 blacksmithing, 3 leatherworking, 2 engineering.
    local perProf = {}
    for i = 1, #Dataset.specs do
        local key = Dataset.ProfKey(Dataset.specs[i].p)
        perProf[key] = (perProf[key] or 0) + 1
    end
    ck(perProf.blacksmithing == 5 and perProf.leatherworking == 3 and perProf.engineering == 2,
       "the specialisation split is not 5/3/2 blacksmithing/leatherworking/engineering")

    -- FIX-1: fishing's artisan rank must NOT share cooking's spell id.
    local cookArtisan = Dataset.ranks[Dataset.profIdx.cooking][4].spell
    local fishArtisan = Dataset.ranks[Dataset.profIdx.fishing][4].spell
    ck(fishArtisan ~= cookArtisan,
       "FIX-1 regressed: fishing and cooking artisan ranks share spell id " .. tostring(fishArtisan))
    ck(fishArtisan == 18248, "FIX-1: the fishing artisan rank should be 18248, got " .. tostring(fishArtisan))

    -- Every rank spell is unique — the whole profession probe rests on it.
    local seen = {}
    for idx in pairs(Dataset.profs) do
        local tiers = Dataset.ranks[idx]
        if tiers then
            for tier = 1, 4 do
                local t = tiers[tier]
                if t then
                    ck(not seen[t.spell], "rank spell " .. tostring(t.spell)
                       .. " is claimed by two professions — the presence probe would mis-answer")
                    seen[t.spell] = true
                end
            end
        end
    end

    -- FIX-3 and referential cleanliness live in the sources stage.
    ck(Dataset.LoadSources() == true, "the sources dataset stage did not parse")
    local noSource, contract = 0, 0
    for id, a in pairs(Dataset.itemAcq) do
        for tok in (a .. ";"):gmatch("(.-);") do
            if tok == "X" then noSource = noSource + 1 end
            if tok == "K18628" then contract = contract + 1 end
        end
    end
    ck(noSource == 0, "FIX-3 regressed: " .. noSource .. " recipe-item(s) still carry no source at all")
    ck(contract == 3, "FIX-3: expected 3 plans wired to the Thorium Brotherhood contract, got " .. contract)

    -- Referential cleanliness: every teaching-item reference resolves.
    local dangling = 0
    for spell, a in pairs(Dataset.acq) do
        for tid in a:gmatch("I(%d+)") do
            if not Dataset.item[tonumber(tid)] then dangling = dangling + 1 end
        end
    end
    ck(dangling == 0, dangling .. " teaching-item reference(s) do not resolve")

    -- Grant-on-learn is an explicit class here (addendum deviation 43), not a
    -- "must be trainer-taught" default that is wrong all 29 times.
    local grants = 0
    for _, a in pairs(Dataset.acq) do
        for tok in (a .. ";"):gmatch("(.-);") do
            if tok == "G" then grants = grants + 1 end
        end
    end
    ck(grants == 29, "expected 29 grant-on-learn recipes, found " .. grants)

    -- The shared transmute cooldown group.
    local transmutes = 0
    for _, r in pairs(Dataset.recipe) do
        if r.cd == 1 then transmutes = transmutes + 1 end
    end
    ck(transmutes >= 12, "the transmute cooldown group holds " .. transmutes
       .. " recipes; alchemy's transmute line is larger than that")
end

local function testEncodingRoundTrip(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    Dataset.LoadCore()

    -- Bit-level: every single-bit position round-trips, and only that bit.
    for _, n in ipairs({ 1, 6, 7, 12, 13, 111, 239 }) do
        for _, idx in ipairs({ 1, math.ceil(n / 2), n }) do
            local s = Professions.EncodeBits({ [idx] = true }, n)
            ck(#s == math.ceil(n / 6),
               string.format("bitmap for n=%d is %d chars, expected %d", n, #s, math.ceil(n / 6)))
            local back, count = Professions.DecodeBits(s, n)
            ck(back and back[idx] and count == 1,
               string.format("bit %d of %d did not round-trip", idx, n))
        end
    end

    -- Whole-profession: every recipe of the largest profession known.
    local bsList = Dataset.profRecipes[Dataset.profIdx.blacksmithing]
    local bits, known, unknown = Professions.EncodeKnown("blacksmithing", bsList)
    ck(known == #bsList and unknown == 0,
       "encoding every blacksmithing recipe reported " .. known .. "/" .. unknown)
    local ids = Professions.DecodeKnown("blacksmithing", bits, Dataset.Version())
    ck(ids and #ids == #bsList, "the full blacksmithing set did not round-trip")
    if ids then
        local same = true
        for i = 1, #ids do if ids[i] ~= bsList[i] then same = false end end
        ck(same, "the decoded blacksmithing set is not the encoded one, in order")
    end

    -- A realistic set: half of tailoring, in a SHUFFLED enumeration order. The
    -- bitmap must be identical to the sorted order's (class 8 — the wire cannot
    -- inherit the client's row order).
    local tlList = Dataset.profRecipes[Dataset.profIdx.tailoring]
    local half, shuffled = {}, {}
    for i = 1, #tlList, 2 do half[#half + 1] = tlList[i] end
    for i = #half, 1, -1 do shuffled[#shuffled + 1] = half[i] end
    local a = Professions.EncodeKnown("tailoring", half)
    local b = Professions.EncodeKnown("tailoring", shuffled)
    ck(a == b, "two enumeration orders of the same recipes produced different bitmaps")

    -- Drift: an id our dataset does not carry is COUNTED, never encoded.
    local withDrift = { tlList[1], 999999, tlList[2] }
    local _, k2, u2 = Professions.EncodeKnown("tailoring", withDrift)
    ck(k2 == 2 and u2 == 1, "an unknown recipe id was not counted as drift (" .. k2 .. "/" .. u2 .. ")")

    -- Refusals. Every one of these must return nil, because nil renders as
    -- "unknown" and a wrong answer renders as a lie about somebody's alt.
    ck(Professions.DecodeKnown("tailoring", bits, "some-other-dataset") == nil,
       "a bitmap from a DIFFERENT dataset version decoded instead of refusing")
    ck(Professions.DecodeBits("!!!", 12) == nil, "a symbol outside the alphabet decoded")
    ck(Professions.DecodeBits("0", 111) == nil, "a truncated bitmap decoded")
    ck(Professions.DecodeBits(nil, 111) == nil, "a nil bitmap decoded")

    -- SIZE, measured against the mesh budget. A full two-primary,
    -- three-secondary character is the worst realistic case.
    local worst = {
        blacksmithing = true, tailoring = true, cooking = true,
        firstaid = true, fishing = true,
    }
    local bytes = 0
    for key in pairs(worst) do
        local list = Dataset.profRecipes[Dataset.profIdx[key]] or {}
        local s = Professions.EncodeKnown(key, list)
        bytes = bytes + #(s or "")
    end
    ck(bytes <= 160, "the worst-case known-set bitmaps are " .. bytes
       .. " characters; the budget is 160")
    Professions._measuredBitmapBytes = bytes

    -- And the whole payload, through the mesh's own packer when it is reachable.
    local payload = {
        v = 1, ds = Dataset.Version(), ts = 1700000000, p = {}, c = { g1 = 1700086400 },
    }
    for key in pairs(worst) do
        local list = Dataset.profRecipes[Dataset.profIdx[key]] or {}
        local bitsK, n = Professions.EncodeKnown(key, list)
        payload.p[key] = { l = 300, m = 300, t = 4, k = bitsK, n = n, a = 1700000000 }
    end
    -- A HALF-KNOWN character too. An all-ones bitmap is deflate's best case, so
    -- measuring only the maxed character would flatter the number; a levelling
    -- character's alternating bits are close to the entropy ceiling and are the
    -- honest worst case for the wire.
    local mixed = {
        v = 1, ds = Dataset.Version(), ts = 1700000000, p = {}, c = { g1 = 1700086400 },
    }
    for key in pairs(worst) do
        local list = Dataset.profRecipes[Dataset.profIdx[key]] or {}
        local halfList = {}
        for i = 1, #list, 2 do halfList[#halfList + 1] = list[i] end
        local bitsK, n = Professions.EncodeKnown(key, halfList)
        mixed.p[key] = { l = 187, m = 300, t = 3, k = bitsK, n = n, a = 1700000000 }
    end

    if ns.Mesh and ns.Mesh.Pack then
        local packed = ns.Mesh.Pack(payload)
        if packed then
            Professions._measuredPayloadBytes = #packed
            ck(#packed <= 900, "the maxed-character packed payload is " .. #packed
               .. " bytes; the budget is 900 (about four mesh chunks)")
        end
        local packedMixed = ns.Mesh.Pack(mixed)
        if packedMixed then
            Professions._measuredMixedBytes = #packedMixed
            ck(#packedMixed <= 900, "the half-known packed payload is " .. #packedMixed
               .. " bytes; the budget is 900 (about four mesh chunks)")
        end
    end
end

local function testCaptureHonesty(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local saved = {
        numTS = _G.GetNumTradeSkills, tsInfo = _G.GetTradeSkillInfo,
        tsLink = _G.GetTradeSkillRecipeLink, tsLine = _G.GetTradeSkillLine,
        tsCD = _G.GetTradeSkillCooldown,
        numCraft = _G.GetNumCrafts, craftInfo = _G.GetCraftInfo,
        craftLink = _G.GetCraftRecipeLink, craftEnch = _G.CraftIsEnchanting,
        craftLine = _G.GetCraftDisplaySkillLine,
        known = _G.IsSpellKnown, numSkill = _G.GetNumSkillLines,
        skillInfo = _G.GetSkillLineInfo, spellInfo = _G.GetSpellInfo,
        getTime = _G.GetTime,
    }
    local savedLatch = {
        Professions._leavingWorld, Professions._loggingOut,
        Professions._enteredWorldAt, Professions._live, Professions._lastSig,
    }

    local ok, err = pcall(function()
        Dataset.LoadCore()
        _G.GetTime = function() return 10000 end
        Professions._leavingWorld, Professions._loggingOut = false, false
        Professions._enteredWorldAt = 0            -- long since warm
        Professions._live = nil

        local bsList = Dataset.profRecipes[Dataset.profIdx.blacksmithing]
        local W = { rows = {}, coldRow = nil, cds = {} }
        for i = 1, 20 do W.rows[i] = bsList[i] end

        _G.GetNumTradeSkills = function() return #W.rows end
        _G.GetTradeSkillInfo = function(i)
            if not W.rows[i] then return nil end
            return "row" .. i, "optimal", 1, false
        end
        _G.GetTradeSkillRecipeLink = function(i)
            if W.coldRow == i then return nil end        -- item data has not arrived
            return "|cffffd000|Henchant:" .. tostring(W.rows[i]) .. "|h[x]|h|r"
        end
        _G.GetTradeSkillLine = function() return "Blacksmithing", 275, 300 end
        _G.GetTradeSkillCooldown = function(i) return W.cds[i] end

        -- (1) A COMPLETE scan resolves the profession by ID and writes a bitmap.
        local scan = Professions.ScanTradeSkillWindow()
        ck(scan ~= nil and scan.profKey == "blacksmithing",
           "a complete window scan did not resolve blacksmithing by id")
        ck(scan and scan.l == 275 and scan.m == 300, "the window's level did not capture")

        -- (1b) The window-update throttle coalesces a crafting spree but can
        --      never swallow the window OPENING, which is the scan that has to
        --      land.
        Professions._scanAt = nil
        local okFirst = Professions.CaptureWindow("tradeskill", true)
        ck(okFirst == true, "the window-open scan did not land")
        local okThrottled, whyT = Professions.CaptureWindow("tradeskill")
        ck(okThrottled == false and whyT == "throttled",
           "an update one frame later re-scanned instead of coalescing")
        ck(Professions.CaptureWindow("tradeskill", true) == true,
           "the throttle swallowed a forced re-open")
        Professions._scanAt = nil

        -- (2) ONE cold row makes the whole scan unusable. Understating a known
        --     set is a confident lie about an alt, so nothing is written.
        W.coldRow = 7
        local partial, why = Professions.ScanTradeSkillWindow()
        ck(partial == nil and why == "incomplete",
           "a scan with an unresolved row was accepted (" .. tostring(why) .. ")")
        W.coldRow = nil

        -- (3) TEARDOWN: every capture entry point refuses, in both directions.
        Professions._loggingOut = true
        ck(Professions.CaptureAllowed() == false, "the teardown latch did not gate capture")
        ck(Professions.ScanTradeSkillWindow() == nil, "a teardown scan was allowed")
        ck(Professions.CaptureStatic() == false, "a teardown static capture was allowed")
        ck(Professions.Publish() == false, "a teardown publish was allowed")
        Professions._loggingOut = false

        -- (4) COLD: inside the entering-world grace, same refusal.
        Professions._enteredWorldAt = 10000
        ck(Professions.CaptureAllowed() == false, "the entering-world grace did not gate capture")
        Professions._enteredWorldAt = 0

        -- (5) THE CLASS-6 POLARITY. A character with blacksmithing who has
        --     never opened the window must read as UNKNOWN, not as "knows
        --     nothing". This is the defect the addendum found shipped.
        Professions._live = nil
        local L = Professions.Live()
        L.p.blacksmithing = { l = 300, m = 300, t = 4 }      -- proven, never scanned
        local payload = Professions.BuildPayload()
        ck(payload and payload.p.blacksmithing and payload.p.blacksmithing.k == nil
           and payload.p.blacksmithing.a == nil,
           "an unscanned profession published a known-set")
        local state = Professions.KnownState(payload, "blacksmithing", bsList[1])
        ck(state == "unknown",
           "an unscanned alt answered '" .. tostring(state) .. "' instead of 'unknown'")

        -- RED CONTROL. The polarity this module refuses, implemented here so the
        -- green row above is not asserting a tautology: store the MISSING set
        -- and answer "known" for anything absent from it. Against the very same
        -- unscanned alt it reports the recipe as ALREADY KNOWN — which is the
        -- defect the addendum found shipped (§5.3), and it is the single answer
        -- that hides exactly the alt the player went looking for.
        local function preFixAnswer(missingSet, spellID)
            return missingSet[spellID] and "missing" or "known"
        end
        ck(preFixAnswer({}, bsList[1]) == "known",
           "RED: the pre-fix polarity did not reproduce its own defect")
        ck(preFixAnswer({}, bsList[1]) ~= state,
           "GREEN: our answer for an unscanned alt agrees with the pre-fix defect")
        -- ...and a SCANNED alt answers the other two states properly.
        local scanned = Professions.ScanTradeSkillWindow()
        Professions.ApplyScan(scanned, 1700000000)
        local p2 = Professions.BuildPayload()
        ck(Professions.KnownState(p2, "blacksmithing", bsList[1]) == "known",
           "a scanned alt did not report a known recipe as known")
        ck(Professions.KnownState(p2, "blacksmithing", bsList[#bsList]) == "missing",
           "a scanned alt did not report an unlearned recipe as missing")
        ck(Professions.KnownState(p2, "alchemy", bsList[1]) == "unknown",
           "a profession the character does not have answered something other than unknown")

        -- (6) A payload from a FOREIGN dataset version never resolves to a
        --     recipe list — it degrades to unknown.
        local foreign = { v = 1, ds = "not-ours", p = { blacksmithing = p2.p.blacksmithing } }
        ck(Professions.KnownState(foreign, "blacksmithing", bsList[1]) == "unknown",
           "a foreign-dataset payload was decoded instead of refused")

        -- (7) COOLDOWN PROOF GATES. A running cooldown is recorded from a
        --     complete scan; a proven-ready one is deleted; and the shared
        --     transmute group folds thirteen recipes onto one key.
        Professions._live = nil
        local alList = Dataset.profRecipes[Dataset.profIdx.alchemy]
        local transmutes = {}
        for i = 1, #alList do
            local r = Dataset.recipe[alList[i]]
            if r.cd == 1 then transmutes[#transmutes + 1] = alList[i] end
        end
        ck(#transmutes >= 12, "the alchemy transmute group is smaller than expected")
        W.rows = {}
        for i = 1, #transmutes do W.rows[i] = transmutes[i] end
        W.rows[#W.rows + 1] = alList[1]                    -- a non-transmute alchemy recipe
        W.cds = { [1] = 3600, [2] = 7200 }                 -- two transmutes on cooldown
        _G.GetTradeSkillLine = function() return "Alchemy", 300, 300 end
        local aScan = Professions.ScanTradeSkillWindow()
        ck(aScan and aScan.profKey == "alchemy", "the alchemy window did not resolve")
        local running, proven = Professions.FoldCooldowns(aScan, 1000)
        ck(running and running.g1 == 1000 + 7200,
           "the shared transmute cooldown did not fold onto one key at its longest stamp")
        local nKeys = 0
        for _ in pairs(running) do nKeys = nKeys + 1 end
        ck(nKeys == 1, "thirteen transmutes produced " .. nKeys .. " cooldown keys, not 1")
        local _, consumed = Professions.ApplyCooldowns(running, proven)
        ck(consumed == true, "a cooldown that started did not report as consumed")
        ck(Professions.Live().c.g1 == 1000 + 7200, "the cooldown stamp did not store")

        -- Re-scanning with the SAME cooldown is not a consumption.
        local r2, p2b = Professions.FoldCooldowns(aScan, 1000)
        local _, again = Professions.ApplyCooldowns(r2, p2b)
        ck(again == false, "an unchanged cooldown reported as a fresh consumption")

        -- A PROVEN-ready scan deletes the stamp. The delete is what makes the
        -- gate a gate and not a one-way ratchet.
        W.cds = {}
        local r3, p3 = Professions.FoldCooldowns(aScan, 20000)
        Professions.ApplyCooldowns(r3, p3)
        ck(Professions.Live().c.g1 == nil, "a proven-ready cooldown was not cleared")

        -- ...but a scan of ANOTHER profession never clears alchemy's stamps.
        Professions.Live().c.g1 = 99999
        W.rows = {}
        for i = 1, 20 do W.rows[i] = bsList[i] end
        W.cds = {}
        _G.GetTradeSkillLine = function() return "Blacksmithing", 300, 300 end
        local bScan = Professions.ScanTradeSkillWindow()
        local r4, p4 = Professions.FoldCooldowns(bScan, 30000)
        Professions.ApplyCooldowns(r4, p4)
        ck(Professions.Live().c.g1 == 99999,
           "a blacksmithing scan cleared an alchemy cooldown it never observed")

        -- (8) THE CRAFT SURFACE refuses the hunter beast-training window.
        _G.CraftIsEnchanting = function() return false end
        _G.GetNumCrafts = function() return 3 end
        _G.GetCraftInfo = function(i) return "pet" .. i, "Rank 1", "optimal" end
        _G.GetCraftRecipeLink = function() return nil end
        local cScan, cWhy = Professions.ScanCraftWindow()
        ck(cScan == nil and cWhy == "not-a-profession",
           "the beast-training window was accepted as a profession (" .. tostring(cWhy) .. ")")

        -- ...and accepts a real enchanting window, by id.
        local enList = Dataset.profRecipes[Dataset.profIdx.enchanting]
        _G.CraftIsEnchanting = function() return true end
        _G.GetNumCrafts = function() return 10 end
        _G.GetCraftInfo = function(i) return "row" .. i, nil, "optimal" end
        _G.GetCraftRecipeLink = function(i)
            return "|cffffd000|Henchant:" .. tostring(enList[i]) .. "|h[x]|h|r"
        end
        _G.GetCraftDisplaySkillLine = function() return "Enchanting", 290, 300 end
        local eScan = Professions.ScanCraftWindow()
        ck(eScan and eScan.profKey == "enchanting" and eScan.l == 290,
           "a real enchanting craft window did not resolve")

        -- (9) THE PRESENCE PROBE is id-keyed and witness-gated.
        local knownSpells = {}
        for tier = 1, 4 do
            knownSpells[Dataset.ranks[Dataset.profIdx.blacksmithing][tier].spell] = true
        end
        knownSpells[Dataset.ranks[Dataset.profIdx.cooking][1].spell] = true
        knownSpells[Dataset.specs[1].id] = true     -- a blacksmithing specialisation
        _G.IsSpellKnown = function(id) return knownSpells[id] == true end
        _G.GetNumSkillLines = function() return 0 end        -- the panel is NOT populated
        ck(Professions.ProbeProfessions() == nil,
           "the presence probe answered from an unwitnessed client (class 6)")
        _G.GetNumSkillLines = function() return 12 end
        local probe = Professions.ProbeProfessions()
        ck(probe and probe.blacksmithing and probe.blacksmithing.t == 4,
           "the rank tier did not come out of the rank spells")
        ck(probe and probe.cooking and probe.cooking.t == 1, "the cooking apprentice rank was missed")
        ck(probe and probe.alchemy == nil, "a profession the character lacks was reported")
        ck(probe and probe.blacksmithing.s and #probe.blacksmithing.s == 1,
           "the learned specialisation did not capture")

        -- (10) The skill panel never produces a zero level for an unrecognised
        --      name — unknown stays unknown.
        _G.GetSpellInfo = function() return nil end
        _G.GetSkillLineInfo = function(i)
            if i == 1 then return "Blacksmithing", false, true, 275, 0, 0, 300 end
            if i == 2 then return "Riding", false, true, 75, 0, 0, 75 end
            return "Ein Beruf Den Wir Nicht Kennen", false, true, 200, 0, 0, 300
        end
        _G.GetNumSkillLines = function() return 3 end
        local levels = Professions.CaptureSkillLines()
        ck(levels and levels.blacksmithing and levels.blacksmithing.l == 275,
           "the skill panel did not read blacksmithing")
        local nLevels = 0
        for _ in pairs(levels or {}) do nLevels = nLevels + 1 end
        ck(nLevels == 1, "the skill panel invented " .. nLevels .. " profession rows from 3 skill lines")
    end)

    _G.GetNumTradeSkills, _G.GetTradeSkillInfo = saved.numTS, saved.tsInfo
    _G.GetTradeSkillRecipeLink, _G.GetTradeSkillLine = saved.tsLink, saved.tsLine
    _G.GetTradeSkillCooldown = saved.tsCD
    _G.GetNumCrafts, _G.GetCraftInfo = saved.numCraft, saved.craftInfo
    _G.GetCraftRecipeLink, _G.CraftIsEnchanting = saved.craftLink, saved.craftEnch
    _G.GetCraftDisplaySkillLine = saved.craftLine
    _G.IsSpellKnown, _G.GetNumSkillLines = saved.known, saved.numSkill
    _G.GetSkillLineInfo, _G.GetSpellInfo = saved.skillInfo, saved.spellInfo
    _G.GetTime = saved.getTime
    Professions._leavingWorld, Professions._loggingOut = savedLatch[1], savedLatch[2]
    Professions._enteredWorldAt, Professions._live = savedLatch[3], savedLatch[4]
    Professions._lastSig = savedLatch[5]

    if not ok then fails[#fails + 1] = "error in capture-honesty fixtures: " .. tostring(err) end
end

local function testReagentHarvest(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    Dataset.LoadCore()

    local bsList = Dataset.profRecipes[Dataset.profIdx.blacksmithing]
    local scan = { complete = true, surface = "tradeskill", profKey = "blacksmithing",
                   rows = { { i = 1, spell = bsList[1] }, { i = 2, spell = bsList[2] } } }

    local cold = {}       -- rows whose reagent links have not arrived
    local api = {
        numReagents = function(i) return 2 end,
        reagentInfo = function(i, j) return "reagent", nil, j * 2 end,
        reagentLink = function(i, j)
            if cold[i] then return nil end
            return "|cffffffff|Hitem:" .. (1000 + i * 10 + j) .. ":0|h[r]|h|r"
        end,
        itemLink = function(i) return "|cffffffff|Hitem:" .. (2000 + i) .. ":0|h[o]|h|r" end,
        numMade  = function(i) return 1, 1 end,
    }

    local out = Professions.HarvestReagents(scan, api)
    ck(out and out[bsList[1]], "a warm harvest produced nothing")
    if out and out[bsList[1]] then
        local e = out[bsList[1]]
        ck(e.r[1011] == 2 and e.r[1012] == 4, "reagent counts did not capture")
        ck(e.o == 2001, "the produced item id did not capture")
        ck(e.n == 1, "the craft yield did not capture")
    end

    -- CLASS 4: one cold reagent link must drop THAT RECIPE from the harvest
    -- entirely. A partial reagent list understates the cost of a craft, and an
    -- understated cost is worse than no answer.
    cold[1] = true
    local partial = Professions.HarvestReagents(scan, api)
    ck(partial and partial[bsList[1]] == nil,
       "a recipe with one unresolved reagent was harvested anyway")
    ck(partial and partial[bsList[2]] ~= nil,
       "the cold row poisoned a sibling recipe that resolved fine")
end

local function testPublishDelta(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    Dataset.LoadCore()

    local base = {
        v = 1, ds = "ds1", ts = 100,
        p = { tailoring = { l = 300, m = 300, t = 4, k = "AAA", n = 3, a = 100 } },
        c = { g1 = 500 },
    }
    local sameLater = {
        v = 1, ds = "ds1", ts = 999,          -- ts moved
        p = { tailoring = { l = 300, m = 300, t = 4, k = "AAA", n = 3, a = 999 } },  -- a moved
        c = { g1 = 500 },
    }
    ck(Professions.PayloadSignature(base) == Professions.PayloadSignature(sameLater),
       "a re-scan that changed nothing but the timestamps still signed differently")

    local levelUp = { v = 1, ds = "ds1", ts = 100,
        p = { tailoring = { l = 301, m = 300, t = 4, k = "AAA", n = 3, a = 100 } }, c = { g1 = 500 } }
    ck(Professions.PayloadSignature(base) ~= Professions.PayloadSignature(levelUp),
       "a skill-up did not change the signature")

    local newRecipe = { v = 1, ds = "ds1", ts = 100,
        p = { tailoring = { l = 300, m = 300, t = 4, k = "AAB", n = 4, a = 100 } }, c = { g1 = 500 } }
    ck(Professions.PayloadSignature(base) ~= Professions.PayloadSignature(newRecipe),
       "a newly learned recipe did not change the signature")

    local cdUsed = { v = 1, ds = "ds1", ts = 100,
        p = { tailoring = { l = 300, m = 300, t = 4, k = "AAA", n = 3, a = 100 } }, c = { g1 = 900 } }
    ck(Professions.PayloadSignature(base) ~= Professions.PayloadSignature(cdUsed),
       "a consumed cooldown did not change the signature")

    local cdCleared = { v = 1, ds = "ds1", ts = 100,
        p = { tailoring = { l = 300, m = 300, t = 4, k = "AAA", n = 3, a = 100 } }, c = {} }
    ck(Professions.PayloadSignature(base) ~= Professions.PayloadSignature(cdCleared),
       "a cooldown coming back up did not change the signature")

    local scanned = { v = 1, ds = "ds1", ts = 100,
        p = { tailoring = { l = 300, m = 300, t = 4 } }, c = { g1 = 500 } }
    ck(Professions.PayloadSignature(base) ~= Professions.PayloadSignature(scanned),
       "'never scanned' and 'scanned' signed the same")

    ck(Professions.PayloadSignature(nil) == "", "a non-table payload did not sign empty")

    -- The signature must not inherit table iteration order (class 8).
    local a = { v = 1, ds = "d", p = { tailoring = { s = { 10656, 10658 } } } }
    local b = { v = 1, ds = "d", p = { tailoring = { s = { 10658, 10656 } } } }
    ck(Professions.PayloadSignature(a) == Professions.PayloadSignature(b),
       "two specialisation orders of the same set signed differently")

    -- The live publish path: unchanged means unchanged.
    local savedSync = _G.Daseeki
    local savedLive, savedSig = Professions._live, Professions._lastSig
    local savedTear = { Professions._loggingOut, Professions._enteredWorldAt }
    local savedName, savedRealm = _G.UnitName, _G.GetRealmName
    local ok, err = pcall(function()
        -- The publish path needs an owner key and a warm world; both are pinned
        -- here so the row tests the DETECTOR and not the harness's stubs.
        _G.UnitName = function() return "Tester" end
        _G.GetRealmName = function() return "TestRealm" end
        Professions._loggingOut, Professions._enteredWorldAt = false, -1e9
        local pushes = 0
        _G.Daseeki = { Sync = {
            RegisterNamespace = function() return true end,
            MarkDirty = function() pushes = pushes + 1; Professions._provideFn(); return true end,
            Get = function() return {} end,
        } }
        Professions._live = { p = { cooking = { l = 300, m = 300, t = 4 } }, c = {} }
        Professions._lastSig = nil
        ck(Professions.Publish() == true, "the first publish of a fresh character did not go out")
        ck(pushes == 1, "the first publish did not reach the wire")
        ck(Professions.Publish() == "unchanged", "an unchanged payload published again")
        ck(pushes == 1, "an unchanged payload reached the wire (" .. pushes .. " pushes)")
        Professions._live.c.g1 = 12345
        ck(Professions.Publish() == true, "a consumed cooldown did not publish")
        ck(pushes == 2, "the cooldown publish did not reach the wire")
        ck(Professions.Publish(true) == true, "a forced republish was refused")
        ck(pushes == 3, "the forced republish did not reach the wire")
    end)
    _G.Daseeki = savedSync
    _G.UnitName, _G.GetRealmName = savedName, savedRealm
    Professions._live, Professions._lastSig = savedLive, savedSig
    Professions._loggingOut, Professions._enteredWorldAt = savedTear[1], savedTear[2]
    if not ok then fails[#fails + 1] = "error in publish-delta fixtures: " .. tostring(err) end
end

local function testInertness(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local S = ns.Store
    local db = S and S.GetSettings and S.GetSettings()
    local savedSetting = db and db.professionsEnabled
    local savedFrame, savedActive = Professions._frame, Professions._activated
    local savedLive = Professions._live
    local savedData = S and S.data and S.data.professions

    local ok, err = pcall(function()
        ck(Professions.IsEnabled() == true, "the module is not default-ON")
        if db then
            db.professionsEnabled = nil
            ck(Professions.IsEnabled() == true, "an ABSENT setting did not read as ON")
        end

        -- OFF: the dataset is dropped, the frame is gone, capture refuses, and
        -- the saved-variable area is never created.
        if S and S.data then S.data.professions = nil end
        Professions.SetEnabled(false)
        ck(Professions.IsEnabled() == false, "SetEnabled(false) did not disable")
        ck(Dataset.IsLoaded() == false, "the dataset stayed parsed after the module was disabled")
        ck(Professions._frame == nil, "the event frame survived the module being disabled")
        ck(Professions._activated == false, "the module still reports itself active")
        ck(Professions._live == nil, "the live capture survived the module being disabled")
        ck(Professions.CaptureStatic() == false, "a disabled module captured")
        ck(Professions.CaptureWindow("tradeskill") == false, "a disabled module scanned a window")
        ck(Professions.Publish() == false, "a disabled module published")
        ck(Professions.BuildPayload() == nil, "a disabled module built a payload")
        ck(Professions.Activate() == false, "a disabled module activated")
        ck(not (S and S.data and S.data.professions),
           "a disabled module created its saved-variable area")

        -- The raw dataset string is still in memory — Era's .toc has no
        -- per-file load-on-demand, so this is the honest floor and the test
        -- says so out loud rather than pretending otherwise.
        ck(type(ns.ProfessionsDataRaw) == "string",
           "the dataset string vanished; the toc no longer ships professions_data.lua")

        -- ON again: everything comes back, and the store is only touched once
        -- something is actually captured.
        Professions.SetEnabled(true)
        ck(Professions.IsEnabled() == true, "SetEnabled(true) did not enable")
        ck(Dataset.LoadCore() == true, "the dataset did not re-parse after re-enabling")
    end)

    Professions.SetEnabled(false)
    if db then db.professionsEnabled = savedSetting end
    Professions._frame, Professions._activated = savedFrame, savedActive
    Professions._live = savedLive
    if S and S.data then S.data.professions = savedData end
    if not ok then fails[#fails + 1] = "error in inertness fixtures: " .. tostring(err) end
end

function Professions.RunSelfTests(verbose)
    local suites = {
        { name = "dataset integrity (census + referential + the fixed game facts)",
          fn = testDatasetIntegrity },
        { name = "wire encoding round-trip + payload budget", fn = testEncodingRoundTrip },
        { name = "capture honesty gates (class 4/6/7: cold, partial, polarity, cooldown proof)",
          fn = testCaptureHonesty },
        { name = "reagent harvest (class 4: partial lists are not lists)", fn = testReagentHarvest },
        { name = "publish delta detector", fn = testPublishDelta },
        { name = "module inertness (off = no frame, no events, no dataset, no SV)",
          fn = testInertness },
    }
    local allPass = true
    for _, suite in ipairs(suites) do
        local f = {}
        local ok = pcall(suite.fn, f)
        local passed = ok and #f == 0
        if not passed then allPass = false end
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS professions/" .. suite.name)
            elseif not ok then ns:Print("  FAIL professions/" .. suite.name .. " :: error in test")
            else for _, m in ipairs(f) do ns:Print("  FAIL professions/" .. suite.name .. " :: " .. m) end end
        end
    end
    if verbose and ns and ns.Print then
        ns:Print(string.format(
            "  professions: worst-case bitmaps %s chars; packed payload %s bytes maxed,"
            .. " %s bytes half-known",
            tostring(Professions._measuredBitmapBytes or "?"),
            tostring(Professions._measuredPayloadBytes or "n/a"),
            tostring(Professions._measuredMixedBytes or "n/a")))
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("professions", Professions.RunSelfTests)
end
