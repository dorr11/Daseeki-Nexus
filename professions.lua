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
local SCAN_THROTTLE        = 1     -- seconds between two coalesced window scans

Professions.PUBLISH_DEBOUNCE = PUBLISH_DEBOUNCE
Professions.ENTERING_WORLD_GRACE = ENTERING_WORLD_GRACE
Professions.SCAN_THROTTLE = SCAN_THROTTLE

----------------------------------------------------------------------
-- THE RETRY LADDER  (CLIENT_ASYNC_LESSONS class 7)
--
-- The window's data is not on the window's SHOW. TRADE_SKILL_SHOW is the client
-- saying "a profession window is opening"; the rows arrive with the server's own
-- list packet, which surfaces as one or more TRADE_SKILL_UPDATEs some unknown
-- number of frames later. A scan taken at SHOW can therefore legitimately find
-- an EMPTY enumeration, and the settle signal we need is not the event we were
-- woken by.
--
-- Class 7's fix shape is exactly this: "a capture that observed a locked slot
-- schedules its own follow-up". So a refusal that could plausibly heal on its
-- own re-asks on a bounded ladder while the window is still open, instead of
-- trusting that some later event will wake us. The ladder is short, finite, and
-- dies with the window: it can never become a poll.
--
-- The rungs are cumulative delays from the refusal, spread over ~6 seconds —
-- long enough to outlast a bad-latency list packet, short enough that the player
-- has not closed the window and moved on.
----------------------------------------------------------------------

local RETRY_LADDER = { 0.10, 0.25, 0.50, 1.00, 2.00, 4.00 }
Professions.RETRY_LADDER = RETRY_LADDER

-- Refusals that mean "not yet" rather than "not ever". A reason absent from this
-- set is a settled state and re-asking it would only burn frames: `disabled` is
-- a setting, `view-filtered` clears through the filter panel's own re-capture,
-- `no-api` is a client that will not grow the function back.
local RETRYABLE = {
    ["cold"] = true, ["empty"] = true, ["incomplete"] = true, ["unresolved"] = true,
    ["row-error"] = true, ["unidentified"] = true, ["throttled"] = true,
}
Professions.RETRYABLE = RETRYABLE

-- How many trace rows survive in the saved variables. Bounded because a ring
-- that grows without limit is a saved-variable leak wearing a diagnostic's hat.
local TRACE_CAP = 30
Professions.TRACE_CAP = TRACE_CAP

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
Professions._scanAt        = nil    -- GetTime of the last SUCCESSFUL window scan (throttle)
Professions._staticAt      = nil    -- GetTime of the last presence/level probe (throttle)
Professions._harvested     = nil    -- profKey -> reagents already harvested this session
Professions._windowOpen    = nil    -- surface -> true while the client says the window is up
Professions._retry         = nil    -- surface -> { step, timer } the bounded ladder
Professions._stats         = nil    -- key -> per-profession/surface scan forensics
Professions._trace         = nil    -- the session's own copy of the bounded trace ring
Professions._nameMap       = nil    -- memoised localized-skill-name -> profKey

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
    Professions._nameMap = nil
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

----------------------------------------------------------------------
-- STAGE ITEMS — the teaching-item -> recipe relation, ALONE  (wave P3)
--
-- The recipe tooltip needs exactly one fact out of the source graph: "this item
-- in my bag teaches THAT recipe". Building the whole SOURCES stage to get it
-- would drag in the NPC / zone / quest / object / event / faction indices and
-- the trainer sets — ~1,900 rows of graph that a hover has not asked for — on
-- the first recipe a player mouses over in the auction house.
--
-- So this is a third stage, and it is the only one a tooltip ever triggers.
-- LoadSources still builds the same map as part of its own pass; whichever runs
-- first wins and the other is a no-op, because the map is a pure function of
-- the frozen dataset.
--
-- The addendum's §5.2 finding is why the map exists at all: the shipped
-- third-party tooltip resolves the profession from the item's recipe SUBCLASS
-- ORDINAL through a fixed list of eight professions, so poisons and fishing
-- recipes silently get no lines, and a client that ever renumbers subclasses
-- re-attributes every recipe to the wrong profession. An item-id lookup into
-- our own dataset has neither failure: it covers every profession we carry and
-- it cannot be renumbered out from under us.
----------------------------------------------------------------------

function Dataset.LoadItemIndex()
    if Dataset.itemOfRecipe then return true end
    if not Professions.IsEnabled() then return false end
    if not Dataset.LoadCore() then return false end
    local map = {}
    local ok = Dataset.Walk(rawText(), function(section, line)
        if section == "recipe" then
            local f = splitFields(line)
            local spell = tonumber(f[2])
            if spell then
                for tid in tostring(f[8]):gmatch("I(%d+)") do
                    map[tonumber(tid)] = spell
                end
            end
        end
    end)
    if not ok then return false end
    Dataset.itemOfRecipe = map
    return true
end

-- itemID -> teaching spell id, or nil. The one entry point a tooltip needs.
function Dataset.RecipeItemSpell(itemID)
    itemID = tonumber(itemID)
    if not itemID then return nil end
    if not Dataset.LoadItemIndex() then return nil end
    return Dataset.itemOfRecipe[itemID]
end

-- The learnability facts for a teaching spell: which profession it belongs to,
-- the skill it requires, and the specialisation spell id that gates it (nil
-- when it is ungated). Everything a reader needs to answer "could that alt
-- learn this?" without touching the dataset itself.
function Dataset.RecipeFacts(spellID)
    spellID = tonumber(spellID)
    if not spellID then return nil end
    if not Dataset.LoadCore() then return nil end
    local r = Dataset.recipe[spellID]
    if not r then return nil end
    local specID
    if r.spec then
        local s = Dataset.specs[r.spec]
        specID = s and s.id or nil
    end
    return {
        profKey = Dataset.ProfKey(r.p),
        spell   = spellID,
        req     = r.s,
        specID  = specID,
        prof    = (Dataset.profs[r.p] and Dataset.profs[r.p].name) or nil,
    }
end

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
    if Professions._nameMap then return Professions._nameMap end
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
    -- Memoised: the map is a pure function of the dataset and the client's own
    -- spell names, neither of which changes inside a session, and the forensics
    -- path now asks for it on every refused scan. Dataset.Unload() drops it.
    Professions._nameMap = map
    return map
end

-- WHICH PROFESSION IS THIS WINDOW SHOWING — asked of a window whose scan FAILED.
--
-- A refusal we cannot attribute is a refusal the owner cannot act on: "some
-- window refused" is not a diagnosis. The window names its own skill line even
-- when its rows have not arrived, so the reason can be filed against the
-- profession it belongs to. Localized, so it goes through the same client-built
-- name map the skill panel uses, and it returns nil rather than guessing.
function Professions.WindowProfKey(surface)
    local fn
    if surface == "craft" then fn = GetCraftDisplaySkillLine else fn = GetTradeSkillLine end
    if not fn then return nil end
    local ok, name = pcall(fn)
    if not ok or type(name) ~= "string" or name == "" then return nil end
    return Professions.SkillNameMap()[name:lower()]
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

----------------------------------------------------------------------
-- SCAN FORENSICS  (this ships whether or not it ever catches anything)
--
-- The defect this section was written for was invisible for a whole wave: the
-- window opened, the module was enabled, the frame was up, the levels captured,
-- and every profession still read NEVER SCANNED. The debug print could say that
-- the scan had not happened and nothing at all about WHY, so there was no way to
-- tell a throttle from a filter from a client that had not sent its rows yet.
--
-- So every window-capture attempt now leaves a record, and the record names the
-- gate. Three layers, cheapest first:
--
--   STATS   per profession (and per surface when the profession is unknown):
--           attempts, the last attempt's epoch, the last refusal reason, the
--           last success, and a tally per reason. Two numbers and a string.
--
--   TRACE   a bounded ring of the last TRACE_CAP attempts, each carrying the
--           event that woke us, the row count the client enumerated, how many
--           rows did not resolve, the view-guard verdict AND which getter
--           produced it, and where the retry ladder stood. Saved-variable
--           backed and BUILD-STAMPED, so the answer survives the /reload the
--           owner does before reporting and cannot silently blend two builds.
--
--   LADDER  the deferral state itself is a trace field, because "the deferred
--           re-capture never fired" and "it fired and was refused" look
--           identical from the outside and are opposite bugs.
--
-- Cost when nothing is wrong: one small table per window open, plus one per
-- coalesced update. The ring is capped and the stats table has at most a dozen
-- keys — one per profession this character can hold.
----------------------------------------------------------------------

local function nowEpoch()
    return (ns.Store and ns.Store.Now and ns.Store.Now()) or (time and time()) or 0
end

local function nowMono()
    return (GetTime and GetTime()) or 0
end

Professions.NowEpoch = nowEpoch

function Professions.BuildStamp()
    return tostring(ns.VERSION or "?")
end

-- The session stats table. Keyed by profession key when we could name the
-- window's profession, and by "surface:<name>" when we could not — an
-- unattributable refusal is still a refusal and must not vanish.
function Professions.Stats(key, create)
    if not create then
        local s = Professions._stats
        return s and s[key] or nil
    end
    Professions._stats = Professions._stats or {}
    local s = Professions._stats[key]
    if not s then
        s = { attempts = 0, ok = 0, reasons = {} }
        Professions._stats[key] = s
    end
    return s
end

function Professions.AllStats()
    return Professions._stats or {}
end

-- The ring, session copy first so the diagnostics work even when the store is
-- not up (the harness, an early error, a disabled store).
function Professions.TraceRows()
    return Professions._trace or {}
end

function Professions.ClearTrace()
    Professions._trace = nil
    local S = ns.Store
    local t = S and S.ProfessionsTrace and S.ProfessionsTrace(false)
    if t then t.rows = {} end
end

-- PURE-ish. Append one attempt record, cap the ring, mirror it into the saved
-- variables when the store is up. Never creates the saved-variable area unless
-- the module is enabled — the inertness rule outranks the diagnostic.
function Professions.RecordAttempt(rec)
    if type(rec) ~= "table" then return false end
    if not Professions.IsEnabled() then return false end
    rec.t = rec.t or nowEpoch()

    -- A note from the filter layer's convention probe is EVIDENCE, not a capture
    -- attempt. Counting it as one would inflate the attempt tally with our own
    -- measurements and file "form-learned" among the refusal reasons, which is
    -- the diagnostic reading its own handwriting back as a symptom.
    if rec.e ~= "filter-probe" then
        local key = rec.p or ("surface:" .. tostring(rec.s or "?"))
        local st = Professions.Stats(key, true)
        st.attempts = st.attempts + 1
        st.lastAt = rec.t
        st.lastReason = rec.r
        st.lastEvent = rec.e
        if rec.r == "ok" then
            st.ok = st.ok + 1
            st.lastOkAt = rec.t
        else
            st.reasons[rec.r or "?"] = (st.reasons[rec.r or "?"] or 0) + 1
        end
    end

    -- SELF-INFLICTED REFUSALS DO NOT GET RING SPACE. Measuring what the client's
    -- filter setters do means moving them on purpose, and every one of those
    -- calls echoes back as an update that this layer correctly refuses. Ten of
    -- those per probe would push the rows that actually explain something off
    -- the end of a thirty-row ring. They are still tallied in the stats, so the
    -- work is not invisible — it just does not get to drown out the evidence.
    local selfInflicted = rec.r == "view-filtered"
        and tostring(rec.g or ""):find("probing", 1, true) ~= nil
    if not selfInflicted then
        local ring = Professions._trace
        if not ring then ring = {} Professions._trace = ring end
        ring[#ring + 1] = rec
        while #ring > TRACE_CAP do table.remove(ring, 1) end
    end

    local S = ns.Store
    if not selfInflicted and S and S.ProfessionsTrace then
        local t = S.ProfessionsTrace(true, Professions.BuildStamp())
        if t then
            t.rows[#t.rows + 1] = rec
            while #t.rows > TRACE_CAP do table.remove(t.rows, 1) end
        end
    end
    return true
end

-- One trace row rendered for a human. The field order is the order the question
-- is asked in: when, what woke us, which window, which profession, what the
-- gate said, and then the evidence that produced that verdict.
function Professions.FormatTraceRow(rec)
    if type(rec) ~= "table" then return "" end
    local parts = {
        tostring(rec.t or "?"),
        (rec.e or "?") .. (rec.f and "!" or ""),
        tostring(rec.s or "?"),
        rec.p or "(unattributed)",
        "=> " .. tostring(rec.r or "?"),
    }
    if rec.n ~= nil then parts[#parts + 1] = "rows=" .. tostring(rec.n) end
    if rec.i ~= nil then parts[#parts + 1] = "ids=" .. tostring(rec.i) end
    if rec.u ~= nil and rec.u > 0 then parts[#parts + 1] = "unresolved=" .. tostring(rec.u) end
    if rec.g then parts[#parts + 1] = "guard=" .. tostring(rec.g) end
    if rec.d then parts[#parts + 1] = "ladder=" .. tostring(rec.d) end
    return table.concat(parts, " | ")
end

----------------------------------------------------------------------
-- THE VIEW GUARD — filtering the VIEW must never filter the CAPTURE
--
-- Era's own client filters the trade-skill list SERVER-SIDE: with a name
-- filter, a subclass filter or "have materials" engaged, GetNumTradeSkills()
-- answers with the NARROWED count and the enumeration walks only the surviving
-- rows. Nothing about that read looks broken — every row resolves, nothing is
-- missing in the sense §7 defect 10 means — so the capture's completeness gate
-- (`missed > 0`) cannot see it. The scan would simply write a smaller known
-- set: the exact failure this module exists to prevent, arriving through the
-- front door.
--
-- This predates wave P3's filter panel. A player who leaves Blizzard's own
-- "Have Materials" box ticked has always been able to hand us a short list.
--
-- So: any surface that narrows the client's enumeration registers a witness
-- here, and a narrowed window CAPTURES NOTHING. Refusing leaves the last proven
-- known set standing (and the payload's `a` stamp honest about when it was
-- taken); writing would replace it with a subset. professions_filters.lua
-- registers its own state and re-captures the moment the narrowing clears.
----------------------------------------------------------------------

Professions._viewGuards = nil

function Professions.RegisterViewGuard(fn)
    if type(fn) ~= "function" then return false end
    Professions._viewGuards = Professions._viewGuards or {}
    local list = Professions._viewGuards
    for i = 1, #list do if list[i] == fn then return true end end
    list[#list + 1] = fn
    return true
end

function Professions.ClearViewGuards()
    Professions._viewGuards = nil
end

-- narrowed(bool), why(string). `why` is the WITNESS, not a label: it names the
-- guard or the getter that produced the verdict, so a capture refused as
-- "view-filtered" can be told apart from a capture refused because a panel of
-- ours forgot to deregister. "clear" is the honest answer for "nothing that can
-- be read is narrowing anything".
--
-- Anything we cannot READ we do not assert: a false "narrowed" would stop the
-- capture forever, which is its own kind of lie.
function Professions.ViewNarrowedWhy(surface)
    local list = Professions._viewGuards
    if list then
        for i = 1, #list do
            local ok, narrowed, why = pcall(list[i], surface)
            if ok and narrowed then
                return true, "guard#" .. i .. (why and (":" .. tostring(why)) or "")
            end
        end
    end
    -- Two of the client's own filter states have getters, and both survive
    -- across window sessions, so they are worth asking even when no panel of
    -- ours is up — a player who leaves Blizzard's own "Have Materials" ticked
    -- has always been able to hand us a short list.
    if surface ~= "craft" and GetTradeSkillItemNameFilter then
        local ok, txt = pcall(GetTradeSkillItemNameFilter)
        if ok and type(txt) == "string" and txt:gsub("%s+", "") ~= "" then
            return true, "client-name-filter"
        end
    end
    if GetOnlyShowMakeable then
        local ok, only = pcall(GetOnlyShowMakeable)
        if ok and only then return true, "client-have-materials" end
    end
    -- The third readable one, added after the live miss made it obvious how much
    -- a missing witness costs: the client's own "only show skill-ups" box hides
    -- most of a maxed character's list and has a getter, so there is no reason
    -- for it to have been invisible except that nobody looked. A refusal here
    -- can now be diagnosed from the trace, which is what makes it safe to add:
    -- the alternative was writing a truncated known set and calling it the
    -- truth.
    if GetOnlyShowSkillUps then
        local ok, only = pcall(GetOnlyShowSkillUps)
        if ok and only then return true, "client-skill-ups-only" end
    end
    -- The subclass and inventory-slot filters have getters too
    -- (GetTradeSkillSubClassFilter / GetTradeSkillInvSlotFilter) and their
    -- VALUES are still not interpreted here. Their "show everything" sentinel is
    -- a numeric convention the catalog does not carry, and reading it wrong in
    -- the narrowing direction would wedge the capture shut forever — a refusal
    -- that can never clear is its own kind of lie. professions_filters.lua
    -- covers them by MEASURING what a call actually does to the client's own row
    -- count and registering a guard while it is measuring, which is a fact we
    -- establish rather than a value we interpret.
    return false, "clear"
end

-- true when something is currently narrowing the client's own enumeration of
-- `surface`. The boolean form, kept because every reader outside the capture
-- path only wants the verdict.
function Professions.ViewNarrowed(surface)
    local narrowed = Professions.ViewNarrowedWhy(surface)
    return narrowed
end

function Professions.ScanTradeSkillWindow()
    -- Every exit carries the same shaped evidence table, so a refusal is as
    -- readable as a success: how many rows the client offered, how many resolved
    -- to a teaching spell, and how many did not.
    local ev = { n = 0, ids = 0, missed = 0 }
    if not Professions.CaptureAllowed() then return nil, "cold", ev end
    if not (GetNumTradeSkills and GetTradeSkillInfo and GetTradeSkillRecipeLink) then
        return nil, "no-api", ev
    end
    local okN, n = pcall(GetNumTradeSkills)
    if not okN or type(n) ~= "number" then return nil, "empty", ev end
    ev.n = n
    if n <= 0 then return nil, "empty", ev end

    local rows, ids, missed = {}, {}, 0
    for i = 1, n do
        local ok, name, kind = pcall(GetTradeSkillInfo, i)
        if not ok then return nil, "row-error", ev end
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
    ev.ids, ev.missed = #ids, missed
    if #ids == 0 then return nil, "unresolved", ev end
    if missed > 0 then return nil, "incomplete", ev end

    local profKey, unknown = Professions.ResolveProfession(ids)
    if not profKey then return nil, "unidentified", ev end

    local scan = { profKey = profKey, rows = rows, ids = ids, unknown = unknown,
                   complete = true, surface = "tradeskill", ev = ev }
    if GetTradeSkillLine then
        local ok, _, rank, maxRank = pcall(GetTradeSkillLine)
        if ok and type(rank) == "number" and type(maxRank) == "number" and maxRank > 0 then
            scan.l, scan.m = rank, maxRank
        end
    end
    return scan
end

function Professions.ScanCraftWindow()
    local ev = { n = 0, ids = 0, missed = 0 }
    if not Professions.CaptureAllowed() then return nil, "cold", ev end
    -- The craft surface is shared with hunter beast training, which is not a
    -- profession. This is the discriminator, and it is a refusal, not a filter.
    if not CraftIsEnchanting then return nil, "no-api", ev end
    local okE, isEnch = pcall(CraftIsEnchanting)
    if not okE or not isEnch then return nil, "not-a-profession", ev end
    if not (GetNumCrafts and GetCraftInfo and GetCraftRecipeLink) then return nil, "no-api", ev end

    local okN, n = pcall(GetNumCrafts)
    if not okN or type(n) ~= "number" then return nil, "empty", ev end
    ev.n = n
    if n <= 0 then return nil, "empty", ev end

    local rows, ids, missed = {}, {}, 0
    for i = 1, n do
        local ok, name, _, kind = pcall(GetCraftInfo, i)
        if not ok then return nil, "row-error", ev end
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
    ev.ids, ev.missed = #ids, missed
    if #ids == 0 then return nil, "unresolved", ev end
    if missed > 0 then return nil, "incomplete", ev end

    local profKey, unknown = Professions.ResolveProfession(ids)
    if not profKey then return nil, "unidentified", ev end

    local scan = { profKey = profKey, rows = rows, ids = ids, unknown = unknown,
                   complete = true, surface = "craft", ev = ev }
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

-- THE BOUNDED RETRY LADDER
--
-- Armed by a refusal that could heal, disarmed by a success or by the window
-- closing. One timer per surface, at most #RETRY_LADDER rungs per window
-- session, and every rung is recorded in the trace so "the deferral never fired"
-- can never again be confused with "it fired and was refused".

function Professions.CancelRetry(surface)
    local r = Professions._retry and Professions._retry[surface]
    if not r then return false end
    if r.timer then pcall(function() r.timer:Cancel() end) end
    Professions._retry[surface] = nil
    return true
end

function Professions.RetryState(surface)
    local r = Professions._retry and Professions._retry[surface]
    if not r then return "idle" end
    return string.format("rung %d/%d %s", r.step, #RETRY_LADDER,
        r.pending and "pending" or "fired")
end

-- Returns true when a rung was armed. Refuses to arm when the window is not
-- open, when the ladder is spent, or when the client has no timer service —
-- three honest "no"s rather than a poll.
function Professions.ScheduleRetry(surface, reason)
    if not RETRYABLE[reason or ""] then return false end
    if not (Professions._windowOpen and Professions._windowOpen[surface]) then return false end
    if not Professions.IsEnabled() or Professions.IsTeardown() then return false end
    Professions._retry = Professions._retry or {}
    local r = Professions._retry[surface]
    -- A rung already in flight is the answer. The filter clears alone fire four
    -- update echoes in one frame, and letting each refusal advance the ladder
    -- would spend all six rungs before the first one had a chance to run — a
    -- ladder that climbs itself is not a ladder.
    if r and r.pending then return false end
    local step = (r and r.step or 0) + 1
    local delay = RETRY_LADDER[step]
    if not delay then return false end                    -- the ladder is finite on purpose
    local rec = { step = step, timer = nil, pending = true }
    Professions._retry[surface] = rec
    local run = function()
        local cur = Professions._retry and Professions._retry[surface]
        if cur ~= rec then return end                     -- superseded
        rec.timer, rec.pending = nil, false
        if not Professions.IsEnabled() then return end
        if not (Professions._windowOpen and Professions._windowOpen[surface]) then
            Professions.CancelRetry(surface)
            return
        end
        -- Give the filter sub-surface a chance to finish measuring first. Its
        -- clear-on-open can only be measured against a window that has rows, and
        -- when the rows arrive without an event this rung is the only thing that
        -- will ever ask again.
        local F = ns.ProfessionFilters
        if F and F.Settle then pcall(F.Settle, surface) end
        Professions.CaptureWindow(surface, true, "retry")
    end
    if C_Timer and C_Timer.NewTimer then
        rec.timer = C_Timer.NewTimer(delay, run)
    elseif C_Timer and C_Timer.After then
        C_Timer.After(delay, run)
    else
        -- No timer service: no ladder, and no phantom rung left behind either.
        -- A step counter that advanced without a timer would spend the ladder
        -- on deferrals that never existed.
        Professions._retry[surface] = r
        return false
    end
    return true
end

-- The authoritative half: an open window. `surface` is "tradeskill" or "craft";
-- `event` names what woke us and exists only for the trace.
--
-- THROTTLE. The window's update event fires on every craft, and a full scan of
-- a 300-row profession is ~300 link reads plus ~300 cooldown reads. Crafting a
-- stack of potions would otherwise re-ask the same questions dozens of times a
-- second. `force` (the window's SHOW) always scans; an update inside the window
-- coalesces. One second is short enough that a cooldown that just started is
-- still published within the same breath.
--
-- THE THROTTLE IS ARMED BY SUCCESS, NEVER BY A REFUSAL. That distinction is the
-- whole live defect. TRADE_SKILL_SHOW arrives before the server's row list does,
-- so the forced scan at SHOW legitimately finds an empty enumeration; arming the
-- throttle on that failure then made the module deaf for a second — and the
-- TRADE_SKILL_UPDATE that finally CARRIED the rows lands inside that second.
-- Every subsequent update was answered "throttled", nothing re-fired afterwards,
-- and the profession read NEVER SCANNED for the rest of the session. A throttle
-- exists to coalesce work that was already done; a refusal did no work, so it
-- has nothing to coalesce.
function Professions.CaptureWindow(surface, force, event)
    if not Professions.IsEnabled() then return false, "disabled" end
    event = event or (force and "forced" or "update")

    local function refuse(reason, ev, guard)
        Professions.RecordAttempt({
            e = event, s = surface, f = force and true or nil,
            p = Professions.WindowProfKey(surface),
            r = reason, n = ev and ev.n, i = ev and ev.ids, u = ev and ev.missed,
            g = guard, d = Professions.RetryState(surface),
        })
        Professions.ScheduleRetry(surface, reason)
        return false, reason
    end

    if not Professions.CaptureAllowed() then return refuse("cold") end
    -- A narrowed list is a SHORT list, and a short list written as the known set
    -- is a confident lie about this character. See the view guard above.
    local narrowed, guardWhy = Professions.ViewNarrowedWhy(surface)
    if narrowed then return refuse("view-filtered", nil, guardWhy) end

    local now = nowMono()
    if not force and Professions._scanAt and (now - Professions._scanAt) < SCAN_THROTTLE then
        return refuse("throttled", nil, guardWhy)
    end

    local scan, why, ev
    if surface == "craft" then scan, why, ev = Professions.ScanCraftWindow()
    else scan, why, ev = Professions.ScanTradeSkillWindow() end
    if not scan then return refuse(why, ev, guardWhy) end

    Professions._scanAt = now
    Professions.CancelRetry(surface)
    Professions.RecordAttempt({
        e = event, s = surface, f = force and true or nil, p = scan.profKey,
        r = "ok", n = ev and ev.n, i = ev and ev.ids, u = ev and ev.missed,
        g = guardWhy, d = "cleared",
    })

    local stamp = nowEpoch()
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
-- WINDOW SESSIONS
--
-- "Is the window open" is a fact the retry ladder needs and no client API
-- answers cheaply for both surfaces, so it is latched from the events that
-- bracket it. Opening also resets the ladder: a second open of the same window
-- is a fresh chance, not a continuation of the last one's spent rungs.
----------------------------------------------------------------------

-- Tri-state on purpose: nil = never seen this session, true = open, false = the
-- client TOLD us it closed. Only the SHOW event may lift a `false`.
--
-- That distinction is not pedantry. Closing the window makes the filter panel
-- clear the client's filters on the way out, and every one of those setter calls
-- comes back as a TRADE_SKILL_UPDATE — arriving AFTER the close we are handling.
-- If an update could re-latch the window open, every close would re-arm a retry
-- ladder against a window that is not there.
function Professions.OpenWindow(surface, authoritative)
    Professions._windowOpen = Professions._windowOpen or {}
    local was = Professions._windowOpen[surface]
    if was == false and not authoritative then return false end
    if was == true then return false end
    Professions._windowOpen[surface] = true
    Professions.CancelRetry(surface)
    return true
end

function Professions.CloseWindow(surface)
    Professions._windowOpen = Professions._windowOpen or {}
    Professions._windowOpen[surface] = false
    Professions.CancelRetry(surface)
    return true
end

function Professions.WindowIsOpen(surface)
    return (Professions._windowOpen and Professions._windowOpen[surface]) == true
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
        Professions.OpenWindow("tradeskill", true)
        Professions.CaptureWindow("tradeskill", true, "TRADE_SKILL_SHOW")
    elseif event == "TRADE_SKILL_UPDATE" then
        -- The rows usually arrive HERE, not on SHOW. An update on a surface we
        -- were never told opened is still an open window as far as the client is
        -- concerned, so the ladder is allowed to arm from it.
        Professions.OpenWindow("tradeskill")
        Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE")
    elseif event == "CRAFT_SHOW" then
        Professions.OpenWindow("craft", true)
        Professions.CaptureWindow("craft", true, "CRAFT_SHOW")
    elseif event == "CRAFT_UPDATE" then
        Professions.OpenWindow("craft")
        Professions.CaptureWindow("craft", false, "CRAFT_UPDATE")
    elseif event == "TRADE_SKILL_CLOSE" or event == "CRAFT_CLOSE" then
        -- Nothing to tear down: the scan already wrote what it proved. The
        -- close is only interesting as a publish opportunity — and as the
        -- moment the retry ladder must stop, because a ladder that outlives its
        -- window is a poll against a window that is not there.
        Professions.CloseWindow(event == "CRAFT_CLOSE" and "craft" or "tradeskill")
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

    -- The in-frame filter panel (professions_filters.lua) is a SUB-SURFACE of
    -- this module, so it lives and dies with it: no separate setting, no
    -- separate login hook, nothing of its own registered while the module is
    -- off. Loaded after this file, so the lookup is deferred to runtime.
    local F = ns.ProfessionFilters
    if F and F.Activate then F.Activate() end
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
    local F = ns.ProfessionFilters
    if on then
        if not Professions._activated then
            Professions.Activate()
        else
            Professions.CaptureStatic()
            Professions.MarkDirty()
            if F and F.Activate then F.Activate() end
        end
    else
        if F and F.Teardown then F.Teardown() end
        Professions.ClearViewGuards()
        cancelDirty()
        for _, surface in ipairs({ "tradeskill", "craft" }) do
            Professions.CloseWindow(surface)
        end
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
        Professions._windowOpen, Professions._retry = nil, nil
        -- The forensics go too. They are session state describing a module that
        -- is no longer running, and a stats table that outlived its module would
        -- report attempts against a build path that is not there any more. The
        -- saved-variable ring is left alone: it is the record of what happened
        -- while the module WAS on, and that is exactly what a bug report needs.
        Professions._stats, Professions._trace = nil, nil
        Dataset.Unload()
    end
    -- Readers that cache anything derived from the dataset (the recipe tooltip's
    -- item->recipe answers) drop it here: a disabled module has unloaded the
    -- dataset those answers came out of.
    if ns.Fire then ns:Fire("PROFESSIONS_TOGGLED", Professions.IsEnabled()) end
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
            -- The forensics line, right under the profession it explains. This
            -- is the line the last wave did not have: "NEVER SCANNED" with no
            -- attempts is a dead event chain, "NEVER SCANNED" with 7 attempts
            -- all refused `empty` is a client that never sent its rows, and
            -- "NEVER SCANNED" with `view-filtered` is a filter nobody cleared.
            local st = P.Stats(keys[i])
            if st then
                local tally = {}
                for reason, n in pairs(st.reasons) do tally[#tally + 1] = reason .. "x" .. n end
                table.sort(tally)
                ns:Print(string.format("      scans: %d attempt(s), %d ok | last %s at %s (%s)%s",
                    st.attempts, st.ok, tostring(st.lastReason or "?"),
                    tostring(st.lastAt or "never"), tostring(st.lastEvent or "?"),
                    (#tally > 0) and (" | refusals " .. table.concat(tally, ",")) or ""))
            else
                ns:Print("      scans: NO ATTEMPT RECORDED — no window event ever reached the capture")
            end
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

    -- Windows and ladders: the two pieces of state that decide whether another
    -- attempt is coming at all.
    for _, surface in ipairs({ "tradeskill", "craft" }) do
        local st = P.Stats("surface:" .. surface)
        ns:Print(string.format("  %s window: open=%s | ladder %s%s", surface,
            tostring(P.WindowIsOpen(surface)), P.RetryState(surface),
            st and string.format(" | unattributed %d attempt(s), last %s",
                st.attempts, tostring(st.lastReason or "?")) or ""))
    end

    -- The ring. Newest last, because that is the order the events happened in
    -- and a trace read backwards is a trace read wrong. The session's own copy
    -- is preferred; the stored ring answers after a /reload.
    local rows = P.TraceRows()
    if #rows == 0 then
        local stored = S and S.ProfessionsTrace and S.ProfessionsTrace(false)
        rows = (stored and stored.rows) or {}
        if #rows > 0 then
            ns:Print("  scan trace (from saved variables, build "
                .. tostring(stored.build) .. "):")
        end
    else
        ns:Print("  scan trace (this session, build " .. P.BuildStamp() .. "):")
    end
    if #rows == 0 then
        ns:Print("  scan trace: EMPTY — not one window-capture attempt has been recorded")
    else
        local from = math.max(1, #rows - 12)
        if from > 1 then ns:Print("    ... " .. (from - 1) .. " older row(s)") end
        for i = from, #rows do
            ns:Print("    " .. P.FormatTraceRow(rows[i]))
        end
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

----------------------------------------------------------------------
-- THE COMPOSED CHAIN — the suite that would have caught the live miss
--
-- Every earlier suite drives ONE layer with the others held still: the scanner
-- against a fixed row list, the interlock against a fixed filter state, the
-- codec against fixed ids. The defect that shipped lived in none of them. It
-- lived in the COMPOSITION — module init, then the client's real event order,
-- then wave P3's filter clears (each of which the client echoes back as an
-- update), then the deferred re-capture — and every layer, tested alone, was
-- correct.
--
-- So this fixture drives the whole chain, and its client is UNKIND by default
-- (simulator doctrine, CLIENT_ASYNC_LESSONS):
--
--   * TRADE_SKILL_SHOW arrives BEFORE the rows. GetNumTradeSkills answers 0
--     until the server's list packet lands some frames later — the thing that
--     makes the SHOW-time scan legitimately fail.
--   * every filter setter echoes TRADE_SKILL_UPDATE, so one clear is four more
--     re-entrant capture attempts in the same frame.
--   * deferred work does not run itself. C_Timer is a queue this fixture pumps
--     frame by frame against a virtual clock, so "the timer never fired" is a
--     state the test can actually be in.
--   * the SILENT profile is harsher still: the rows land with NO event at all,
--     which is the only profile the retry ladder can survive.
--
-- The RED CONTROL is the pre-fix gate, written out here as eight lines and
-- replayed against the SAME recorded opportunity list the real module was given.
-- Without it the green rows below assert only that the current code does what
-- the current code does.
----------------------------------------------------------------------

-- A pumpable C_Timer over a virtual clock. Returns the fixture; call :install()
-- and :restore(). `pump(to)` runs every callback due at or before `to` in due
-- order, advancing the clock as it goes, so callbacks scheduled by callbacks
-- run at their own honest time.
local function newClock(t0)
    local C = { now = t0 or 1000, q = {}, seq = 0 }
    local savedTime, savedTimer

    local function push(delay, fn)
        C.seq = C.seq + 1
        local item = { due = C.now + (tonumber(delay) or 0), fn = fn,
                       seq = C.seq, cancelled = false }
        C.q[#C.q + 1] = item
        return item
    end

    function C:install()
        savedTime, savedTimer = _G.GetTime, _G.C_Timer
        _G.GetTime = function() return C.now end
        _G.C_Timer = {
            After = function(delay, fn) push(delay, fn) end,
            NewTimer = function(delay, fn)
                local item = push(delay, fn)
                return { Cancel = function() item.cancelled = true end }
            end,
            NewTicker = function() return { Cancel = function() end } end,
        }
    end

    function C:restore()
        _G.GetTime, _G.C_Timer = savedTime, savedTimer
    end

    -- Run everything due up to `to`, in (due, seq) order. Bounded so a callback
    -- that re-arms itself at zero delay cannot hang the suite.
    function C:pump(to)
        local guard = 0
        while true do
            guard = guard + 1
            if guard > 500 then error("timer pump did not settle") end
            local best
            for i = 1, #C.q do
                local it = C.q[i]
                if not it.cancelled and not it.done and it.due <= to then
                    if not best or it.due < best.due
                       or (it.due == best.due and it.seq < best.seq) then best = it end
                end
            end
            if not best then break end
            best.done = true
            C.now = math.max(C.now, best.due)
            best.fn()
        end
        C.now = math.max(C.now, to)
    end

    return C
end

-- A widget mock that answers METHODS and nothing else. The harness's frame mock
-- hands back a callable for every key, which makes `if box.editBox then` take
-- the wrong branch; here anything that is not an upper-case method name reads as
-- absent, which is what the panel code is actually asking about.
local mockMeta = {}
mockMeta.__index = function(t, k)
    if type(k) ~= "string" then return nil end
    local first = k:sub(1, 1)
    if first == "_" or first:upper() ~= first then return nil end
    return function(_, ...) return t end
end
local function newMock(fields)
    local m = setmetatable(fields or {}, mockMeta)
    return m
end

-- The unkind trade-skill client. `profile` is "echo" (the landing announces
-- itself with an update) or "silent" (it does not).
local function newWindowSim(rows, landedAt, profile)
    local W = {
        rows = rows, landedAt = landedAt, profile = profile or "echo",
        events = {}, echoes = 0, filters = { text = "", makeable = false },
    }
    local saved = {}
    local G = _G

    local function landed() return (G.GetTime() + 1e-9) >= W.landedAt end

    -- Emit an event to BOTH modules in registration order — professions.lua
    -- creates its frame first, then hands off to professions_filters.lua, so
    -- that is the order the client would use.
    function W.emit(event)
        W.events[#W.events + 1] = { t = G.GetTime(), e = event }
        if Professions._onEvent then Professions._onEvent(nil, event) end
        local F = ns.ProfessionFilters
        if F and F._onEvent then F._onEvent(nil, event) end
    end

    -- The client's own echo: any filter setter rebuilds the list and tells the
    -- UI about it. This is what turns one clear into four capture attempts.
    local function echo()
        W.echoes = W.echoes + 1
        W.events[#W.events + 1] = { t = G.GetTime(), e = "TRADE_SKILL_UPDATE" }
        if Professions._onEvent then Professions._onEvent(nil, "TRADE_SKILL_UPDATE") end
        local F = ns.ProfessionFilters
        if F and F._onEvent then F._onEvent(nil, "TRADE_SKILL_UPDATE") end
    end

    function W:install()
        saved = {
            num = G.GetNumTradeSkills, info = G.GetTradeSkillInfo,
            link = G.GetTradeSkillRecipeLink, line = G.GetTradeSkillLine,
            cd = G.GetTradeSkillCooldown,
            setText = G.SetTradeSkillItemNameFilter, getText = G.GetTradeSkillItemNameFilter,
            makeable = G.TradeSkillOnlyShowMakeable, getMakeable = G.GetOnlyShowMakeable,
            setSub = G.SetTradeSkillSubClassFilter, getSub = G.GetTradeSkillSubClassFilter,
            subs = G.GetTradeSkillSubClasses,
            setSlot = G.SetTradeSkillInvSlotFilter, getSlot = G.GetTradeSkillInvSlotFilter,
            slots = G.GetTradeSkillInvSlots,
            numReagents = G.GetTradeSkillNumReagents, reagentInfo = G.GetTradeSkillReagentInfo,
            reagentLink = G.GetTradeSkillReagentItemLink, itemLink = G.GetTradeSkillItemLink,
            numMade = G.GetTradeSkillNumMade,
            frame = G.TradeSkillFrame, update = G.TradeSkillFrame_Update,
        }
        G.GetNumTradeSkills = function() return landed() and #W.rows or 0 end
        G.GetTradeSkillInfo = function(i)
            if not landed() then return nil end
            local row = W.rows[i]
            if not row then return nil end
            return row.name, (row.kind == "header") and "header" or "optimal", 1, false
        end
        G.GetTradeSkillRecipeLink = function(i)
            if not landed() then return nil end
            local row = W.rows[i]
            if not row or row.kind == "header" then return nil end
            return "|cffffd000|Henchant:" .. tostring(row.s) .. "|h[x]|h|r"
        end
        G.GetTradeSkillLine = function() return "Blacksmithing", 275, 300 end
        G.GetTradeSkillCooldown = function() return nil end
        G.SetTradeSkillItemNameFilter = function(t) W.filters.text = t or ""; echo() end
        G.GetTradeSkillItemNameFilter = function() return W.filters.text end
        G.TradeSkillOnlyShowMakeable = function(v)
            W.filters.makeable = v and true or false; echo()
        end
        G.GetOnlyShowMakeable = function() return W.filters.makeable end
        G.SetTradeSkillSubClassFilter = function(...) W.lastSub = { ... }; echo() end
        G.GetTradeSkillSubClassFilter = function() return 0 end
        G.GetTradeSkillSubClasses = function() return { "Weapon", "Armor" } end
        G.SetTradeSkillInvSlotFilter = function(...) W.lastSlot = { ... }; echo() end
        G.GetTradeSkillInvSlotFilter = function() return 0 end
        G.GetTradeSkillInvSlots = function() return { "Head", "Chest" } end
        G.GetTradeSkillNumReagents = function() return 1 end
        G.GetTradeSkillReagentInfo = function() return "reagent", nil, 2 end
        G.GetTradeSkillReagentItemLink = function() return "|Hitem:2840:0|h[Copper]|h|r" end
        G.GetTradeSkillItemLink = function() return "|Hitem:2841:0|h[out]|h|r" end
        G.GetTradeSkillNumMade = function() return 1, 1 end
        -- The Blizzard frame IS present, because a chain that never builds the
        -- filter panel never fires the clears, and the clears are half of what
        -- this fixture exists to compose.
        W.frame = newMock({ GetFrameLevel = function() return 3 end })
        G.TradeSkillFrame = W.frame
        W.redraws = 0
        G.TradeSkillFrame_Update = function() W.redraws = W.redraws + 1 end
        -- The widget kit the panel builds with. The harness's DaseekiUI stub
        -- carries FlatFrame and MakeButton but not the three control factories,
        -- so they are supplied here and taken away again on restore.
        local UI = G.DaseekiUI
        if UI then
            saved.mkEdit, saved.mkCheck, saved.mkDrop =
                UI.MakeEditBox, UI.MakeCheckbox, UI.MakeDropdown
            UI.MakeEditBox  = function() return newMock() end
            UI.MakeCheckbox = function() return newMock() end
            UI.MakeDropdown = function() return newMock() end
        end
    end

    function W:restore()
        G.GetNumTradeSkills, G.GetTradeSkillInfo = saved.num, saved.info
        G.GetTradeSkillRecipeLink, G.GetTradeSkillLine = saved.link, saved.line
        G.GetTradeSkillCooldown = saved.cd
        G.SetTradeSkillItemNameFilter, G.GetTradeSkillItemNameFilter = saved.setText, saved.getText
        G.TradeSkillOnlyShowMakeable, G.GetOnlyShowMakeable = saved.makeable, saved.getMakeable
        G.SetTradeSkillSubClassFilter, G.GetTradeSkillSubClassFilter = saved.setSub, saved.getSub
        G.GetTradeSkillSubClasses = saved.subs
        G.SetTradeSkillInvSlotFilter, G.GetTradeSkillInvSlotFilter = saved.setSlot, saved.getSlot
        G.GetTradeSkillInvSlots = saved.slots
        G.GetTradeSkillNumReagents, G.GetTradeSkillReagentInfo = saved.numReagents, saved.reagentInfo
        G.GetTradeSkillReagentItemLink, G.GetTradeSkillItemLink = saved.reagentLink, saved.itemLink
        G.GetTradeSkillNumMade = saved.numMade
        G.TradeSkillFrame, G.TradeSkillFrame_Update = saved.frame, saved.update
        local UI = G.DaseekiUI
        if UI then
            UI.MakeEditBox, UI.MakeCheckbox, UI.MakeDropdown =
                saved.mkEdit, saved.mkCheck, saved.mkDrop
        end
    end

    -- The landing. In the ECHO profile the client announces it; in the SILENT
    -- profile the rows simply become readable and nothing says so.
    function W:land()
        if W.profile == "echo" then W.emit("TRADE_SKILL_UPDATE") end
    end

    return W
end

-- THE PRE-FIX CHAIN, written down. This is the sequence of capture
-- opportunities the shipped code had on a live window open, and it is stated
-- here rather than recorded from the current code because the current code has
-- MORE opportunities — that is what the fix consists of, and a red control fed
-- the green code's opportunity list would quietly stop reproducing anything.
--
-- Times are seconds from TRADE_SKILL_SHOW. The rows land at 0.30.
local PREFIX_CHAIN = {
    { t = 0.00, force = true,  what = "TRADE_SKILL_SHOW" },
    { t = 0.00, force = false, what = "echo: name filter cleared" },
    { t = 0.00, force = false, what = "echo: have-materials cleared" },
    { t = 0.00, force = false, what = "echo: subclass cleared" },
    { t = 0.00, force = false, what = "echo: inv-slot cleared" },
    { t = 0.00, force = true,  what = "P3's one-frame deferred re-capture" },
    { t = 0.30, force = false, what = "TRADE_SKILL_UPDATE carrying the rows" },
}

-- THE RED CONTROL: the pre-fix gate, in eight lines. `_scanAt` is armed by the
-- ATTEMPT rather than by the SCAN, so one legitimately-empty read at SHOW
-- deafens the module for a second — and the update that finally carries the
-- rows lands inside it.
local function legacyGate(opportunities, landedAt)
    local scanAt, captured = nil, false
    for i = 1, #opportunities do
        local o = opportunities[i]
        local throttled = (not o.force) and scanAt and (o.t - scanAt) < 1
        if not throttled then
            scanAt = o.t                                 -- armed by the attempt
            if o.t + 1e-9 >= landedAt then captured = true end
        end
    end
    return captured
end

local function testComposedChain(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    if not Dataset.LoadCore() then
        fails[#fails + 1] = "the dataset would not load"
        return
    end

    local bs = Dataset.profRecipes[Dataset.profIdx.blacksmithing]
    local function fixtureRows()
        return {
            { kind = "header", name = "Weapons" },
            { kind = "recipe", name = "Arcanite Reaper", s = bs[1] },
            { kind = "recipe", name = "Iron Sword",      s = bs[2] },
            { kind = "header", name = "Armor" },
            { kind = "recipe", name = "Iron Shield",     s = bs[3] },
            { kind = "recipe", name = "Copper Chain",    s = bs[4] },
        }
    end

    local F = ns.ProfessionFilters
    local savedLatch = {
        Professions._leavingWorld, Professions._loggingOut, Professions._enteredWorldAt,
        Professions._live, Professions._scanAt, Professions._harvested,
        Professions._windowOpen, Professions._retry, Professions._stats,
        Professions._trace, Professions._lastSig,
    }
    local savedFilters = F and { F._state, F._prof, F._panels, F._hooked, F._activated }
    local savedGuards = Professions._viewGuards
    local savedStore = ns.Store and ns.Store.data and ns.Store.data.professions

    -- One run of the whole chain. Returns a report the rows below assert on.
    local function runChain(profile)
        local clock = newClock(1000)
        local sim = newWindowSim(fixtureRows(), 1000.30, profile)
        local opportunities = {}
        local realCapture = Professions.CaptureWindow

        clock:install()
        sim:install()
        -- Wrap the capture so the RED CONTROL is replayed against exactly the
        -- opportunities the client and wave P3 handed the real module — the
        -- ladder's own rungs are excluded, because the pre-fix code had none.
        Professions.CaptureWindow = function(surface, force, event)
            if event ~= "retry" then
                opportunities[#opportunities + 1] =
                    { t = _G.GetTime() - 1000, force = force and true or false, e = event }
            end
            return realCapture(surface, force, event)
        end

        Professions._leavingWorld, Professions._loggingOut = false, false
        Professions._enteredWorldAt = 0
        Professions._live, Professions._scanAt = nil, nil
        Professions._harvested, Professions._windowOpen, Professions._retry = nil, nil, nil
        Professions._stats, Professions._trace = nil, nil
        Professions._viewGuards = nil
        if F then
            F._state, F._prof, F._panels, F._hooked = nil, nil, nil, nil
            F._activated = false
            F.Activate()                                  -- registers the view guard
        end

        local ok, err = pcall(function()
            sim.emit("TRADE_SKILL_SHOW")                  -- t = 0, before the rows
            clock:pump(1000.30)                           -- P3's deferral + every early rung
            sim:land()                                    -- t = 0.30: the rows are readable
            clock:pump(1000 + 8)                          -- let the ladder run itself out
        end)

        local rec = Professions._live and Professions._live.p
                    and Professions._live.p.blacksmithing
        -- WHICH mechanism landed the scan. Two different fixes are in play and a
        -- green row that cannot say which one did the work would go on passing
        -- after one of them regressed.
        local landedBy
        for _, row in ipairs(Professions.TraceRows()) do
            if row.r == "ok" and not landedBy then landedBy = row.e end
        end
        local report = {
            captured = (rec and rec.k) and true or false,
            landedBy = landedBy,
            known = rec and rec.n or 0,
            opportunities = opportunities,
            attempts = (Professions.Stats("blacksmithing") or {}).attempts or 0,
            trace = Professions.TraceRows(),
            echoes = sim.echoes,
            err = (not ok) and err or nil,
        }

        Professions.CaptureWindow = realCapture
        sim:restore()
        clock:restore()
        return report
    end

    local ok, err = pcall(function()
        -- ══ (1) THE ECHO PROFILE — the live shape, exactly ═══════════════════
        local echoRun = runChain("echo")
        ck(echoRun.err == nil, "the echo chain errored: " .. tostring(echoRun.err))
        ck(echoRun.echoes > 0,
           "the sim never echoed a single filter clear back as an update; the fixture "
           .. "is kinder than the client and proves nothing")

        -- RED: the pre-fix gate over the pre-fix chain never captures. Every
        -- opportunity after the SHOW is either an echo inside the throttled
        -- second or a forced read taken before the rows existed, and the one
        -- read that would have worked is refused as "throttled".
        ck(legacyGate(PREFIX_CHAIN, 0.30) == false,
           "RED CONTROL DID NOT REPRODUCE: the pre-fix throttle captured the window. "
           .. "Either the chain model is wrong or the miss is elsewhere.")
        -- ...and the model is not fiction: the live fixture really does hand the
        -- module a forced read at SHOW, a burst of clear echoes in the same
        -- frame, and a deferred forced read, all before the rows land.
        do
            local preLanding, echoesAtOpen, forced = 0, 0, 0
            for _, o in ipairs(echoRun.opportunities) do
                if o.t < 0.30 then
                    preLanding = preLanding + 1
                    if o.force then forced = forced + 1 else echoesAtOpen = echoesAtOpen + 1 end
                end
            end
            ck(forced >= 2, "the fixture produced " .. forced .. " forced pre-landing reads; "
               .. "the live chain has at least two (SHOW and the deferral)")
            ck(echoesAtOpen >= 3, "the fixture produced " .. echoesAtOpen
               .. " clear echoes; the live clear fires one per filter setter")
        end

        -- GREEN: the shipped gate does.
        ck(echoRun.captured == true,
           "the composed chain did not capture (attempts " .. echoRun.attempts
           .. ", opportunities " .. #echoRun.opportunities .. ")")
        ck(echoRun.known == 4,
           "the chain captured " .. tostring(echoRun.known) .. " recipes, expected 4")
        -- ...and it was the LANDING UPDATE that landed it, not a ladder rung.
        -- That is the throttle fix and nothing else: the update carrying the
        -- rows arrives 0.28s after the last refused attempt, deep inside the
        -- one-second window a refusal used to arm.
        ck(echoRun.landedBy == "TRADE_SKILL_UPDATE",
           "the echo chain was rescued by '" .. tostring(echoRun.landedBy)
           .. "' rather than by the update that carried the rows — the throttle "
           .. "is swallowing the settle signal again")

        -- The forensics are not decoration: the refusals BEFORE the capture are
        -- on the record with reasons, and the capture itself is on the record.
        local sawEmpty, sawOk = false, false
        for i = 1, #echoRun.trace do
            local r = echoRun.trace[i]
            if r.r == "empty" then sawEmpty = true end
            if r.r == "ok" then sawOk = true end
        end
        ck(sawEmpty, "no refusal reason was recorded for the pre-landing reads")
        ck(sawOk, "the successful scan left no trace row")

        -- ══ (2) THE SILENT PROFILE — the rows land and nothing says so ═══════
        -- The only thing that can save this is the ladder. If it ever becomes a
        -- one-shot again this row goes red.
        local silentRun = runChain("silent")
        ck(silentRun.err == nil, "the silent chain errored: " .. tostring(silentRun.err))
        -- The pre-fix chain minus its last row: in the silent profile nothing at
        -- all fires after the rows arrive, so there is not even a throttled
        -- opportunity to lose.
        local silentChain = {}
        for i = 1, #PREFIX_CHAIN - 1 do silentChain[i] = PREFIX_CHAIN[i] end
        ck(legacyGate(silentChain, 0.30) == false,
           "RED CONTROL DID NOT REPRODUCE on the silent profile")
        ck(silentRun.captured == true,
           "the retry ladder did not heal a window whose rows arrived without an event "
           .. "(attempts " .. silentRun.attempts .. ")")
        ck(silentRun.landedBy == "retry",
           "the silent chain was landed by '" .. tostring(silentRun.landedBy)
           .. "' — this profile has no event after the landing, so only a ladder "
           .. "rung can honestly have done it")

        -- ══ (3) THE LADDER IS BOUNDED AND DIES WITH THE WINDOW ═══════════════
        do
            local clock = newClock(2000)
            local sim = newWindowSim(fixtureRows(), 1e9, "silent")   -- rows never arrive
            clock:install()
            sim:install()
            Professions._live, Professions._scanAt = nil, nil
            Professions._windowOpen, Professions._retry = nil, nil
            Professions._stats, Professions._trace = nil, nil
            local function totalAttempts()
                return ((Professions.Stats("blacksmithing") or {}).attempts or 0)
                     + ((Professions.Stats("surface:tradeskill") or {}).attempts or 0)
            end
            local settledBy
            local okRun = pcall(function()
                sim.emit("TRADE_SKILL_SHOW")
                clock:pump(2000 + 10)          -- the whole ladder, and then some
                settledBy = totalAttempts()
                clock:pump(2000 + 60)          -- fifty more seconds of nothing
            end)
            ck(okRun, "the never-landing window errored")
            -- The bound that matters is not the count, it is that the work STOPS.
            -- A poll would keep going for the whole minute.
            ck(totalAttempts() == settledBy,
               "the ladder was still working " .. (totalAttempts() - (settledBy or 0))
               .. " attempts later, fifty seconds after the window opened — that is a poll")
            ck(settledBy and settledBy <= 60,
               "a window that never sent its rows cost " .. tostring(settledBy)
               .. " capture attempts before it gave up")
            ck(Professions.RetryState("tradeskill"):find("idle") == nil,
               "the spent ladder reported itself idle instead of naming its last rung")

            -- ...and the close disarms it.
            sim.emit("TRADE_SKILL_CLOSE")
            ck(Professions.WindowIsOpen("tradeskill") == false,
               "the window stayed open after TRADE_SKILL_CLOSE")
            ck(Professions.RetryState("tradeskill") == "idle",
               "the ladder outlived the window it belonged to")
            sim:restore()
            clock:restore()
        end

        -- ══ (4) THE INTERLOCK STILL STANDS INSIDE THE CHAIN ══════════════════
        -- A capture that fires while a filter is engaged must refuse, and the
        -- refusal must name the witness rather than a generic "no".
        do
            local clock = newClock(3000)
            local sim = newWindowSim(fixtureRows(), 3000, "echo")    -- rows already there
            clock:install()
            sim:install()
            Professions._live, Professions._scanAt = nil, nil
            Professions._windowOpen, Professions._retry = nil, nil
            Professions._stats, Professions._trace = nil, nil
            local okRun = pcall(function()
                sim.emit("TRADE_SKILL_SHOW")
                clock:pump(3000 + 1)
                _G.SetTradeSkillItemNameFilter("iron")
                Professions._scanAt = nil
                Professions.CaptureWindow("tradeskill", true, "test")
            end)
            ck(okRun, "the interlock leg errored")
            local narrowed, why = Professions.ViewNarrowedWhy("tradeskill")
            ck(narrowed == true, "a client-side name filter was invisible to the guard")
            ck(why == "client-name-filter",
               "the guard did not name its witness (" .. tostring(why) .. ")")
            local last = Professions.TraceRows()[#Professions.TraceRows()]
            ck(last and last.r == "view-filtered" and last.g == "client-name-filter",
               "the filtered refusal did not record which witness produced it")
            local rec = Professions._live and Professions._live.p
                        and Professions._live.p.blacksmithing
            ck(rec and rec.n == 4,
               "the filtered capture replaced the known set instead of leaving it standing")
            sim:restore()
            clock:restore()
        end
    end)

    Professions.CaptureWindow = Professions.CaptureWindow      -- (restored inside runChain)
    Professions._leavingWorld, Professions._loggingOut = savedLatch[1], savedLatch[2]
    Professions._enteredWorldAt, Professions._live = savedLatch[3], savedLatch[4]
    Professions._scanAt, Professions._harvested = savedLatch[5], savedLatch[6]
    Professions._windowOpen, Professions._retry = savedLatch[7], savedLatch[8]
    Professions._stats, Professions._trace = savedLatch[9], savedLatch[10]
    Professions._lastSig = savedLatch[11]
    Professions._viewGuards = savedGuards
    if F then
        F._state, F._prof, F._panels = savedFilters[1], savedFilters[2], savedFilters[3]
        F._hooked, F._activated = savedFilters[4], savedFilters[5]
    end
    if ns.Store and ns.Store.data then ns.Store.data.professions = savedStore end
    if not ok then fails[#fails + 1] = "error in composed-chain fixtures: " .. tostring(err) end
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
        { name = "composed chain (open -> clears -> deferral -> landing, with the red control)",
          fn = testComposedChain },
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
