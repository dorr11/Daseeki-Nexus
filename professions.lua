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
--                  GetTradeSkillInfo gives a name and a row kind. The function
--                  GetTradeSkillRecipeLink EXISTS on this surface but was
--                  MEASURED LIVE (build 1.15.9 / interface 11509, blacksmithing
--                  open) returning NIL for real recipe rows — while
--                  GetTradeSkillItemLink answered with the crafted PRODUCT's
--                  item link. So on this surface the teaching spell id — our
--                  primary key — cannot come from the recipe link alone: rows
--                  resolve through the STRATEGY CHAIN documented above
--                  ResolveRowSpell (recipe link first, should a future client
--                  start answering; the row name against the client's own
--                  names for the dataset spells second). Matching stays
--                  id-keyed on the wire; the name is only the bridge from the
--                  client's row to the dataset's id, and it is the CLIENT'S
--                  name via GetSpellInfo, never a shipped string (main spec
--                  §7 defect 8's locale rule is preserved).
--
--   CRAFT_*        enchanting — and ALSO the hunter beast-training window,
--                  which is not a profession at all. CraftIsEnchanting() is the
--                  discriminator and this module refuses the craft window
--                  without it, so a hunter opening pet training can never be
--                  mistaken for an enchanter with an empty book. HERE the
--                  recipe link works: GetCraftRecipeLink's "enchant:" form was
--                  verified correct live, so the chain's first rung is the one
--                  that fires; the name rung is its safety net only.
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
--   <payload>, the wire shape, frozen for this schema (sh/cv are ADDITIVE —
--   feat/dataset-migration; a reader that ignores them is merely incomplete,
--   never wrong, which is why v stays 1):
--     {
--       v  = 1,                       payload schema
--       ds = "<dataset version>",     the bitmap's coordinate system
--       sh = "<recipe-set hash>",     the coordinate system's IDENTITY — the
--                                     part of ds the bitmaps actually depend
--                                     on. Absent on pre-migration payloads;
--                                     derived from ds via the shipped
--                                     [stampset] table then.
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
--                cv = "<coverage bitmap>", PRESENT ONLY on a migrated record
--                                     whose original scan predates recipes in
--                                     the current set: the current ordinals its
--                                     scan actually covered. A recipe OUTSIDE
--                                     the coverage is UNSCANNED for this
--                                     character, never "missing" — the scan
--                                     never saw it. Absent = full coverage.
--              }, ... },
--       c  = { [cdKey] = <epoch the cooldown is ready> },
--     }
--
--   cdKey is the teaching spell id as a string, or "g<n>" for a shared-cooldown
--   group ("g1" is alchemy's transmutes).
--
--   A profKey present with `k` absent means: this character HAS the profession
--   (proved by the rank spells, or by a witnessed skill-panel row — herbalism
--   and mining hold their profession with ZERO book-known tier spells) and has
--   NOT opened its window since we started looking. Render the level, render
--   the cooldowns, render the recipe list as UNKNOWN. Do not render it as
--   empty.
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
    -- A window whose collapsed headers could not be expanded (calls absent, or
    -- the expand-all convention measured a no-op on this client). The rows are
    -- still THERE server-side and the player can expand by hand, so re-asking
    -- on the ladder is honest; writing the visible subset never is.
    ["collapsed"] = true,
}
Professions.RETRYABLE = RETRYABLE

-- How many trace rows survive in the saved variables. Bounded because a ring
-- that grows without limit is a saved-variable leak wearing a diagnostic's hat.
local TRACE_CAP = 30
Professions.TRACE_CAP = TRACE_CAP

-- Blizzard events the module subscribes to, on ITS OWN frame, only while
-- enabled. Listed here so the inertness self-test can assert the set rather
-- than trusting a comment.
--
-- EVERY name in this list must exist in the client's event registry. That is
-- not a convention any more: the harness gate (nexus-test-harness/harness/
-- eventcheck.lua) derives the registry from the wow-api-catalog dump and turns
-- the run RED on a name the client does not know. See the LEARNED_SPELL_IN_TAB
-- note at Professions.RegisterEventList for why the gate had to exist.
Professions.EVENTS = {
    "TRADE_SKILL_SHOW", "TRADE_SKILL_UPDATE", "TRADE_SKILL_CLOSE",
    "CRAFT_SHOW", "CRAFT_UPDATE", "CRAFT_CLOSE",
    "SKILL_LINES_CHANGED", "SPELLS_CHANGED",
    "PLAYER_ENTERING_WORLD", "PLAYER_LEAVING_WORLD", "PLAYER_LOGOUT",
    -- STALENESS SIGNALS (perf/professions-scan). Catalog-verified at 11509:
    --   CHAT_MSG_SKILL              Event.ChatInfo.ChatMsgSkill — skill rank-ups.
    --   LEARNED_SPELL_IN_SKILL_LINE Event.SpellBook.LearnedSpellInSkillLine —
    --                               carries the spellID, so the mark can usually
    --                               be attributed to ONE profession.
    --   UNIT_SPELLCAST_SUCCEEDED    Event.Unit.UnitSpellcastSucceeded — a craft
    --                               landing names its teaching spell; the hook
    --                               that lets a consumed cooldown publish even
    --                               when the window's own update echo goes
    --                               missing. Unit-filtered to "player" where the
    --                               client offers RegisterUnitEvent.
    "CHAT_MSG_SKILL", "LEARNED_SPELL_IN_SKILL_LINE",
    "UNIT_SPELLCAST_SUCCEEDED",
}

-- Session state. All of it is nil/false until Activate() runs.
Professions._frame         = nil
Professions._activated     = false
-- Event names THIS CLIENT refused, one entry each, ever (see
-- Professions.RegisterEventList). Deliberately NOT cleared with the rest of the
-- session state on disable: it describes the client, not the module's run, and
-- one entry is the whole point — a refusal that can repeat is the bug.
Professions._refusedEvents = nil
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
Professions._recipeNames   = nil    -- memoised per-profession recipe-name -> spell id (chain rung 3)
Professions._settled       = nil    -- profKey -> settled-signature record (session mirror of the store)
Professions._stale         = nil    -- profKey -> true: a learning signal fired; next look is a FULL capture
Professions._harvestJob    = nil    -- the in-flight chunked reagent harvest, if any
Professions._harvestGen    = 0      -- supersession counter for harvest jobs
Professions._collapseLatch = nil    -- surface -> true while OUR expand/collapse calls are echoing
Professions._collapseDepth = nil    -- surface -> nesting depth of those calls (the class-9 fuse)
Professions._collapseRefused = nil  -- how many roundtrips the depth fuse refused outright
Professions._collapseWorld = nil    -- surface -> the last-witnessed collapse world (debug readout)

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
Dataset.compat  = false

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

-- The recipe-set hash: the version stamp names the whole content, this names
-- the one thing the bitmaps depend on — per-profession recipe membership and
-- ordering. Metadata-only bumps move Version() and leave SetHash() alone.
function Dataset.SetHash()
    local m = ns.ProfessionsDataMeta
    return (m and m.setHash) or "?"
end

function Dataset.Unload()
    Dataset.core, Dataset.sources = false, false
    Dataset.compat = false
    Dataset.stampSet, Dataset.migrations = nil, nil
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
    Professions._recipeNames = nil
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
            -- Field 7 (FIX-4) is the parent spec ORDINAL — the era Blacksmithing
            -- tree is nested (the three Master smith specs sit under
            -- Weaponsmith). 0/absent both read as "root": a pre-FIX-4 payload
            -- has six fields and tonumber(nil) answers nil.
            local par = tonumber(f[7])
            specs[idx] = { id = id, p = tonumber(f[3]), minSkill = tonumber(f[4]),
                           quest = tonumber(f[5]), name = f[6],
                           parent = (par and par > 0) and par or nil }
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
-- DATASET MIGRATION  (feat/dataset-migration)
--
-- The 2026-08-10 incident: a spec-tree addition moved the dataset stamp
-- (p1-f84a5fa0 -> p1-4b17878e) WITHOUT changing one recipe, and every
-- character's record went "not checked" — a full re-scan tour of the alts,
-- twice in one day. The gate was honest and wasteful: it keyed validity on the
-- WHOLE-CONTENT stamp when the bitmaps depend only on the recipe set.
--
-- Two layers end that cost:
--
--   LAYER 1 — METADATA-IMMUNE VALIDITY. The dataset ships a recipe-SET hash
--   (Meta.setHash) beside the stamp, plus a [stampset] table naming every
--   historical stamp's set hash. A record whose set hash matches ours is valid
--   VERBATIM, whatever its stamp says: same membership, same order, same bits.
--
--   LAYER 2 — ORDINAL TRANSLATION. When the set genuinely changed, the shipped
--   [migration] rows translate old ordinals to current ones by teaching-spell
--   id: survivors keep their known/missing truth, removed recipes drop
--   silently (nothing to claim), and ADDITIONS — recipes the record's scan
--   never saw — are tracked by a per-profession coverage bitmap (`cv`) so
--   every reader renders them as UNSCANNED, never "missing". Migration
--   preserves truth BETWEEN window opens; it never fakes completeness — the
--   settled-signature layer sees the row-count drift at the next open and
--   forces a real rescan.
--
-- An unknown coordinate system still refuses exactly as before: refusing
-- renders as "not scanned", translating by guesswork would render as a
-- confident list of recipes somebody's alt cannot make.
----------------------------------------------------------------------

-- PURE. Parse the shipped compat blob. Returns stampSet (stamp -> set hash)
-- and migrations (old set hash -> { [profIdx] = { n, identity | map } }).
function Professions.ParseCompat(raw)
    local stampSet, migrations = {}, {}
    if type(raw) ~= "string" or raw == "" then return stampSet, migrations end
    local section
    for line in (raw .. "\n"):gmatch("(.-)\n") do
        line = line:gsub("\r$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" then
            local s = line:match("^%[(%a+)%]$")
            if s then
                section = s
            elseif section == "stampset" then
                local stamp, sh = line:match("^([^|]+)|([^|]+)$")
                if stamp then stampSet[stamp] = sh end
            elseif section == "migration" then
                local sh, pIdx, spec = line:match("^([^|]+)|(%d+)|(.+)$")
                if sh then
                    local entry = migrations[sh]
                    if not entry then entry = {} migrations[sh] = entry end
                    local ident = spec:match("^=(%d+)$")
                    if ident then
                        entry[tonumber(pIdx)] = { n = tonumber(ident), identity = true }
                    else
                        local map, n = {}, 0
                        for tok in (spec .. ","):gmatch("(.-),") do
                            n = n + 1
                            map[n] = tonumber(tok) or 0
                        end
                        entry[tonumber(pIdx)] = { n = n, map = map }
                    end
                end
            end
        end
    end
    return stampSet, migrations
end

function Dataset.LoadCompat()
    if Dataset.compat then return true end
    Dataset.stampSet, Dataset.migrations = Professions.ParseCompat(ns.ProfessionsDataCompat)
    Dataset.compat = true
    return true
end

-- The set hash a payload's bitmaps were written against, or nil when we cannot
-- name it: the explicit `sh` first (new payloads), the current stamp next (an
-- own-build payload from before `sh` existed), the shipped stamp table last
-- (old payloads that carry only a foreign `ds`).
function Professions.ResolveSetHash(payload)
    if type(payload) ~= "table" then return nil end
    if type(payload.sh) == "string" then return payload.sh end
    if payload.ds == Dataset.Version() then return Dataset.SetHash() end
    Dataset.LoadCompat()
    return Dataset.stampSet and Dataset.stampSet[payload.ds] or nil
end

-- Deep-enough copy for migration: fresh payload, fresh profession records
-- (spec arrays included), fresh cooldown map. The original is NEVER mutated —
-- it may be the sync store's cached blob, and those bytes are relay material
-- that must stay exactly what the owning peer published.
function Professions.CopyPayload(payload)
    local out = {}
    for k, v in pairs(payload) do out[k] = v end
    if type(payload.p) == "table" then
        local p = {}
        for key, rec in pairs(payload.p) do
            local r = {}
            for k, v in pairs(rec) do r[k] = v end
            if type(rec.s) == "table" then
                local s = {}
                for i = 1, #rec.s do s[i] = rec.s[i] end
                r.s = s
            end
            p[key] = r
        end
        out.p = p
    end
    if type(payload.c) == "table" then
        local c = {}
        for k, v in pairs(payload.c) do c[k] = v end
        out.c = c
    end
    return out
end

-- PURE against the injected migration entry: an old-coordinate bitmap to a
-- current-coordinate one. Returns bits, survivors — or nil when the bitmap
-- does not decode against the migration's own length (corruption: refuse,
-- never guess). Deterministic output whatever the iteration luck (class 8):
-- EncodeBits walks ordinals 1..n.
function Professions.TranslateBits(bits, mig, nNew)
    if type(mig) ~= "table" then return nil end
    local set = Professions.DecodeBits(bits, mig.n or 0)
    if not set then return nil end
    if mig.identity then
        local count = 0
        for _ in pairs(set) do count = count + 1 end
        return bits, count                -- same membership, same order, same bytes
    end
    local out, survivors = {}, 0
    for oldOrd in pairs(set) do
        local newOrd = mig.map and mig.map[oldOrd] or 0
        if newOrd > 0 then
            if not out[newOrd] then survivors = survivors + 1 end
            out[newOrd] = true
        end
        -- newOrd 0: the recipe left the dataset — nothing to claim, drop silently.
    end
    return Professions.EncodeBits(out, nNew), survivors
end

-- The migration's own coverage of the CURRENT ordering: which current ordinals
-- existed in the old set at all, as a bitmap in current coordinates.
function Professions.MigrationCoverageBits(mig, nNew)
    local set = {}
    if type(mig) == "table" then
        if mig.identity then
            local top = mig.n or 0
            if top > nNew then top = nNew end
            for i = 1, top do set[i] = true end
        else
            for o = 1, mig.n or 0 do
                local nn = mig.map and mig.map[o]
                if nn and nn > 0 and nn <= nNew then set[nn] = true end
            end
        end
    end
    return Professions.EncodeBits(set, nNew)
end

-- Record-load / receive-time translation. Returns payloadOut, changed, verdict:
--   "current"   already in current coordinates; payloadOut IS payload, untouched
--   "rescued"   Layer 1 — the recipe set is identical to ours (metadata-only
--               bump): bitmaps kept verbatim, only the stamps rewritten
--   "migrated"  Layer 2 — a genuine set change we ship a migration for
--   "unknown"   a coordinate system we cannot name: payload returned untouched
--               and every decode gate downstream refuses exactly as before
--   "invalid"   not a payload at all
function Professions.MigratePayload(payload)
    if type(payload) ~= "table" then return nil, false, "invalid" end
    local curDS, curSH = Dataset.Version(), Dataset.SetHash()
    if payload.ds == curDS and (payload.sh == nil or payload.sh == curSH) then
        return payload, false, "current"
    end
    if not Dataset.LoadCore() then return payload, false, "unknown" end
    local sh = Professions.ResolveSetHash(payload)
    if sh == nil then return payload, false, "unknown" end
    if sh == curSH then
        local out = Professions.CopyPayload(payload)
        out.ds, out.sh = curDS, curSH
        return out, true, "rescued"
    end
    Dataset.LoadCompat()
    local entry = Dataset.migrations and Dataset.migrations[sh]
    if not entry then return payload, false, "unknown" end
    local out = Professions.CopyPayload(payload)
    out.ds, out.sh = curDS, curSH
    for key, rec in pairs(out.p or {}) do
        if rec.k ~= nil then
            local idx = Dataset.profIdx[key]
            local mig = idx and entry[idx]
            local list = idx and Dataset.profRecipes[idx] or nil
            local bits, survivors
            if mig and list then
                bits, survivors = Professions.TranslateBits(rec.k, mig, #list)
            end
            if bits == nil then
                -- No map for this profession, or a bitmap that does not decode
                -- against it: the third state, never a guess.
                rec.k, rec.n, rec.u, rec.a, rec.cv = nil, nil, nil, nil, nil
            else
                rec.k, rec.n = bits, survivors
                -- Coverage: what the record's ORIGINAL scan actually saw, in
                -- current coordinates. A record migrated once already carries
                -- `cv`; translating that bitmap through THIS migration keeps
                -- the whole chain exact (old coverage ∩ every set since).
                local cvBits
                if rec.cv ~= nil then
                    cvBits = Professions.TranslateBits(rec.cv, mig, #list)
                    if cvBits == nil then
                        rec.k, rec.n, rec.u, rec.a, rec.cv = nil, nil, nil, nil, nil
                    end
                else
                    cvBits = Professions.MigrationCoverageBits(mig, #list)
                end
                if rec.k ~= nil then
                    local _, covered = Professions.DecodeBits(cvBits, #list)
                    rec.cv = (covered and covered < #list) and cvBits or nil
                end
            end
        end
    end
    return out, true, "migrated"
end

-- One pass over the stored owners graph at activation: translate every record
-- written under another dataset build — IN THE PROJECTION ONLY. The sync
-- store's cached namespace blobs are relay bytes and stay exactly as the
-- owning peer published them; each receiver translates for itself.
function Professions.MigrateStoredOwners()
    local S = ns.Store
    if not (S and S.ProfessionsOwners) then return 0 end
    local owners = S.ProfessionsOwners()
    local keys = {}
    for key in pairs(owners) do keys[#keys + 1] = key end
    table.sort(keys)                       -- class 8: one order, every login
    local n = 0
    for i = 1, #keys do
        local e = owners[keys[i]]
        if type(e) == "table" and type(e.data) == "table" then
            local mp, changed = Professions.MigratePayload(e.data)
            if changed then
                e.data = mp
                n = n + 1
            end
        end
    end
    return n
end

----------------------------------------------------------------------
-- THE THREE-STATE ANSWER
--
-- The one seam every reader (tooltip, panel row, census, shopping list,
-- delegate loud line) must go through — KnownState for the per-recipe answer,
-- KnownSetFor for the per-profession set (ui_professions.lua's KnownSet
-- delegates here, so the list path and the tooltip path cannot drift).
-- Returns "unknown" | "known" | "missing", plus the character's skill in that
-- profession when we have it. There is no boolean form on purpose.
--
-- Migration rides INSIDE the seam: a payload from another build is translated
-- (never mutated — the caller's table is copied) before decoding, so every
-- consumer inherits Layer 1 and Layer 2 without knowing they exist. A recipe
-- OUTSIDE a migrated record's coverage answers "unknown": the scan that wrote
-- the record predates the recipe, and "missing" would be a lie about an alt.
----------------------------------------------------------------------

-- The per-profession known set. Returns set|nil, state, coverage:
--   set       { [spellID] = true } for every recipe the bitmap proves known
--   state     "scanned" | "unscanned" — nil set ALWAYS means unscanned
--   coverage  nil = the record covers the full current set; otherwise
--             { [spellID] = true } for exactly the recipes the record's scan
--             could see — a recipe absent from BOTH set and coverage is
--             UNSCANNED for this character, never missing.
function Professions.KnownSetFor(payload, profKey)
    if type(payload) ~= "table" then return nil, "unscanned" end
    local p0 = payload.p and payload.p[profKey]
    if not p0 then return nil, "unscanned" end
    if p0.k == nil or p0.a == nil then return nil, "unscanned" end   -- never scanned
    local mp, _, verdict = Professions.MigratePayload(payload)
    if verdict ~= "current" and verdict ~= "rescued" and verdict ~= "migrated" then
        return nil, "unscanned"           -- a coordinate system we cannot name
    end
    local rec = mp.p and mp.p[profKey]
    if not rec or rec.k == nil or rec.a == nil then return nil, "unscanned" end
    local ids = Professions.DecodeKnown(profKey, rec.k, mp.ds)
    if type(ids) ~= "table" then return nil, "unscanned" end
    local set = {}
    for i = 1, #ids do set[ids[i]] = true end
    local cov = nil
    if rec.cv ~= nil then
        local idx = Dataset.profIdx and Dataset.profIdx[profKey]
        local list = idx and Dataset.profRecipes[idx] or nil
        local cset = list and Professions.DecodeBits(rec.cv, #list) or nil
        if not cset then return nil, "unscanned" end    -- corrupt coverage: refuse
        cov = {}
        for i = 1, #list do
            if cset[i] then cov[list[i]] = true end
        end
    end
    return set, "scanned", cov
end

function Professions.KnownState(payload, profKey, spellID)
    if type(payload) ~= "table" then return "unknown" end
    local p = payload.p and payload.p[profKey]
    if not p then return "unknown" end            -- no such profession recorded
    local set, state, cov = Professions.KnownSetFor(payload, profKey)
    if state ~= "scanned" then return "unknown", p.l end
    if set[spellID] then return "known", p.l end
    if cov and not cov[spellID] then return "unknown", p.l end   -- outside the scan's set
    return "missing", p.l
end

----------------------------------------------------------------------
-- DELEGATE LANES  (profession-delegates phase 1)
--
-- The owner designates, per FACTION and per PROFESSION, primary/secondary
-- collector characters — scoped to SPECIALISATION LANES, because one
-- profession can have several primaries at once (a main Armorsmith AND a main
-- Axesmith are both Blacksmithing mains, each for their own lane). A lane key
-- is "general" or the tostring() of a specialisation's teaching spell id —
-- spell ids, not dataset ordinals, so a stored designation survives any future
-- reordering of the [spec] section.
--
-- THE RESOLUTION RULE (one pure seam; the tooltip reads it today, Conduit's
-- recipe routing will read it later):
--   * a recipe gated on spec S resolves through lane S; a lane with no
--     designation walks UP the parent chain (FIX-4: Master Axesmith ->
--     Weaponsmith) and lands on "general" last.
--   * a recipe with NO spec gate resolves through "general" ONLY — general
--     recipes belong to the general primary; the walk never descends.
--   * a designation is INTENT, not a mirror of current state: a character who
--     does not (yet) hold the designated spec still resolves — the owner
--     designates planned mains. Only a character whose RECORD no longer
--     exists is skipped (read-side heal, report-don't-crash), letting the
--     walk continue as if the lane were empty.
----------------------------------------------------------------------

Professions.LANE_GENERAL = "general"

-- Spec spell id -> the PARENT spec's spell id, or nil for a root spec.
function Dataset.SpecParentID(specSpellID)
    if not Dataset.LoadCore() then return nil end
    local idx = Dataset.specById[tonumber(specSpellID) or -1]
    local sp = idx and Dataset.specs[idx]
    local par = sp and sp.parent and Dataset.specs[sp.parent]
    return par and par.id or nil
end

-- PURE core: the lane chain for a recipe's gating spec, most specific first,
-- "general" always last. `parentOf` maps specID -> parent specID (injected so
-- the walk is testable without the dataset). Bounded, cycle-proof.
function Professions.LaneChainFrom(specID, parentOf)
    local chain, seen = {}, {}
    local id = tonumber(specID)
    local hops = 0
    while id and id > 0 and not seen[id] and hops < 6 do
        seen[id] = true
        chain[#chain + 1] = tostring(id)
        id = parentOf and tonumber(parentOf(id)) or nil
        hops = hops + 1
    end
    chain[#chain + 1] = Professions.LANE_GENERAL
    return chain
end

-- Live: the chain against the shipped dataset's FIX-4 parent edges.
function Professions.LaneChain(specID)
    return Professions.LaneChainFrom(specID, Dataset.SpecParentID)
end

-- PURE. Resolve one role ("p" primary / "s" secondary) for a recipe.
--   cfg        the delegates config table ({ [faction] = { profs=..., bank=... } })
--   faction    the VIEWER's faction ("Alliance"/"Horde")
--   profKey    the recipe's profession
--   chain      Professions.LaneChain(recipe spec id)
--   role       "p" | "s"
--   charExists optional predicate(ownerKey) -> bool; a designation whose
--              character record vanished is skipped, never an error.
-- Returns ownerKey, laneKey — or nil.
function Professions.ResolveDelegate(cfg, faction, profKey, chain, role, charExists)
    if type(cfg) ~= "table" or type(faction) ~= "string" then return nil end
    local fac = cfg[faction]
    local prof = type(fac) == "table" and type(fac.profs) == "table"
                 and fac.profs[profKey] or nil
    local lanes = type(prof) == "table" and type(prof.lanes) == "table"
                  and prof.lanes or nil
    if not lanes then return nil end
    chain = chain or { Professions.LANE_GENERAL }
    for i = 1, #chain do
        local lane = lanes[chain[i]]
        local who = type(lane) == "table" and lane[role or "p"] or nil
        if type(who) == "string" and who ~= "" then
            if charExists == nil or charExists(who) then
                return who, chain[i]
            end
            -- record gone: heal to "lane empty", keep walking (report-don't-crash)
        end
    end
    return nil
end

-- Live wrapper the tooltip calls: the viewer's-faction PRIMARY for a recipe,
-- against the cross-account EFFECTIVE config (last-writer-wins, store seam).
function Professions.ResolvePrimary(faction, profKey, specID)
    local S = ns.Store
    if not (S and S.DelegatesEffective) then return nil end
    local cfg = S.DelegatesEffective()
    if not cfg then return nil end
    return Professions.ResolveDelegate(cfg, faction, profKey,
        Professions.LaneChain(specID), "p",
        S.CharacterRecordExists and function(k) return S.CharacterRecordExists(k) end or nil)
end

----------------------------------------------------------------------
-- PROFESSION PRESENCE, RANK AND SPECIALISATION  (id-keyed, locale-proof)
--
-- The addendum's §4.7 finding: rank detection in the examined implementation is
-- an equality test on the reported skill ceiling with a silent fall-through to
-- "apprentice", so any unexpected ceiling marks the character as missing every
-- tier. Where spells answer we do not infer the rank from a number at all —
-- each rank tier IS a spell, and IsSpellKnown answers for it directly. The
-- rank is the highest tier whose spell the character knows. There is nothing
-- to fall through.
--
-- The same query answers "does this character have this profession" without
-- reading one localized string, which is what §7 defect 17's deviation asks for.
--
-- BUT THE SPELL WITNESS IS NOT SUFFICIENT — proven live 2026-08 on Orn:
-- Herbalism 300 answered false to IsSpellKnown for every tier spell (its only
-- book spell is "Find Herbs"), so the profession was invisible and its level
-- with it. The skill panel is therefore a SECOND presence witness (see
-- ProbePanelPresence below), and its tier statement obeys §4.7 the other way
-- round: a strict ceiling->tier map, and an unexpected ceiling degrades to the
-- floor tier the RANK VALUE proves — never to a silent apprentice.
----------------------------------------------------------------------

-- A positive witness that the client's spell/skill data is populated. Class 6:
-- "no professions" and "the list has not been filled in yet" are the same
-- answer from an unwitnessed read, and only one of them may erase anything.
function Professions.SpellDataWitnessed()
    if not GetNumSkillLines then return false end
    local ok, n = pcall(GetNumSkillLines)
    return ok and type(n) == "number" and n > 0
end

----------------------------------------------------------------------
-- THE TIER STATEMENT FOR A PANEL-WITNESSED PROFESSION
--
-- The spell probe's tier is exact where it answers: each tier IS a spell. But
-- HERBALISM's tier entries are not book-known spells on the live client —
-- IsSpellKnown answered false for a character with Herbalism 300 (Orn,
-- 2026-08) — so a panel-witnessed profession needs its tier stated from the
-- panel's own numbers, and the addendum §4.7 rule holds with full force: an
-- unexpected ceiling must NEVER fall through to apprentice.
--
-- Two pure readers, both against the DATASET'S OWN tier ceilings (75/150/225/
-- 300 in this Era, but read from the rank rows so a dataset change cannot
-- desynchronise them from a hard-coded map):
--
--   TierFromCeiling  the strict map: a maxRank that IS a tier's ceiling names
--                    that tier exactly. Anything else answers nil — never a
--                    guess.
--   TierFloorFromRank  the honest fallback when the ceiling is unexpected: a
--                    character whose RANK is 280 provably holds at least the
--                    tier whose ceiling covers 280, because a rank cannot
--                    exceed its tier's cap. This is a statement justified by
--                    the rank VALUE, not a default — rank 80 under a weird
--                    ceiling of 90 answers tier 2 (150 covers 80), never a
--                    silent tier 1. A rank past every ceiling clamps to the
--                    top tier: "at least artisan" is the best honest statement
--                    the 1..4 vocabulary can make.
----------------------------------------------------------------------

function Professions.TierFromCeiling(profIdx, maxRank)
    if type(maxRank) ~= "number" then return nil end
    local tiers = Dataset.ranks and Dataset.ranks[profIdx]
    if not tiers then return nil end
    for tier = 1, 4 do
        local t = tiers[tier]
        if t and t.ceil == maxRank then return tier end
    end
    return nil
end

function Professions.TierFloorFromRank(profIdx, rank)
    if type(rank) ~= "number" or rank < 1 then return nil end
    local tiers = Dataset.ranks and Dataset.ranks[profIdx]
    if not tiers then return nil end
    local top
    for tier = 1, 4 do
        local t = tiers[tier]
        if t then
            top = tier
            if t.ceil >= rank then return tier end
        end
    end
    return top                       -- rank beyond every ceiling: at least the top tier
end

----------------------------------------------------------------------
-- THE PANEL WITNESS (the second presence witness)
--
-- The live defect this answers: Orn has Herbalism 300, and the spell probe
-- reported only Alchemy. Herbalism grants the character "Find Herbs" — its
-- rank-tier entries are NOT book-known spells, so IsSpellKnown answers false
-- for every tier and the profession never existed in the record, which also
-- silenced its LEVEL (ApplySkillLines only writes onto professions that
-- exist). Mining is built the same way (its book spell is Smelting; the
-- dataset's mining tiers 2575/2576/3564/10248 are the Mining rank line, not
-- book spells), so it is presumed to share the failure. Skinning does NOT —
-- its tier-1 spell IS the book spell "Skinning" (live-confirmed on Senche).
--
-- So presence gains the skill panel as a second witness. Rows are matched
-- through the same client-built name map the level reader uses (the client's
-- own GetSpellInfo names first, dataset English as fallback — the locale rule
-- holds), and a matched row with rank >= 1 is a profession this character
-- holds, spell answer or no spell answer.
--
-- Class-6 rules, verbatim:
--   * no GetSkillLineInfo, an unreadable count, or an enumeration in which
--     ZERO rows could be read is UNWITNESSED: nil, never "no professions";
--   * a row that could not be read is SKIPPED and poisons only `complete` —
--     it never erases, because the unreadable row could have been ours;
--   * `complete` is the erase licence: only a panel whose every row was read
--     may later prove a profession ABSENT (see ApplyProbe).
--
-- Returns rows, complete — rows = { [profKey] = { l = rank, m = maxRank } } —
-- or nil when the panel could not be witnessed at all.
----------------------------------------------------------------------

function Professions.ProbePanelPresence()
    if not (GetNumSkillLines and GetSkillLineInfo) then return nil end
    local okN, n = pcall(GetNumSkillLines)
    if not okN or type(n) ~= "number" or n <= 0 then return nil end

    local map = Professions.SkillNameMap()
    local rows, readable, complete = {}, 0, true
    for i = 1, n do
        local ok, name, isHeader, _, rank, _, _, maxRank = pcall(GetSkillLineInfo, i)
        if not ok or (not isHeader and type(name) ~= "string") then
            complete = false          -- an unreadable row could be any profession
        elseif isHeader then
            readable = readable + 1   -- a header is a read row, just not a skill
        else
            readable = readable + 1
            local key = map[name:lower()]
            if key then
                if type(rank) == "number" and rank >= 1 then
                    rows[key] = { l = rank, m = maxRank }
                else
                    -- OUR row with a cold rank: skip it, and the panel can no
                    -- longer prove any absence (class 4 — partial is not full).
                    complete = false
                end
            end
            -- an unrecognised name is riding / defense / a language: skipped
            -- in silence, and it does not poison completeness.
        end
    end
    if readable == 0 then return nil end     -- enumerated nothing: unwitnessed
    return rows, complete
end

-- Returns probe, panelSound.
--   probe       { [profKey] = { t = <tier>, s = { specIDs } } } or nil when the
--               client could not be witnessed. An EMPTY table is a real answer
--               ("this character has no professions") and is only ever produced
--               under a witness.
--   panelSound  true only when the skill panel was witnessed AND every row was
--               read — the licence ApplyProbe needs before it may treat absence
--               from this probe as proof of unlearning. The spell probe alone
--               can no longer carry that licence: Herbalism proved that a
--               profession can be held with ZERO book-known tier spells.
--
-- The spell probe stays primary and authoritative where it answers; the panel
-- only ADDS professions the spells missed. It never removes or overrides a
-- spell-probe result.
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

    -- THE SECOND WITNESS: a skill-panel row with rank >= 1 marks a profession
    -- PRESENT even when no tier spell answered (the Orn defect). Additive
    -- only — a spell-probed profession keeps its spell-derived tier untouched.
    local panel, panelComplete = Professions.ProbePanelPresence()
    if panel then
        for key, row in pairs(panel) do
            if not out[key] then
                local pIdx = Dataset.profIdx[key]
                local tier = Professions.TierFromCeiling(pIdx, row.m)
                          or Professions.TierFloorFromRank(pIdx, row.l)
                if tier then out[key] = { t = tier, s = {} } end
            end
        end
    end
    local panelSound = (panel ~= nil and panelComplete == true) or false

    -- Specialisations: one spell query each, and only for a profession the
    -- character actually has (a specialisation without its profession is not a
    -- fact, it is a leak). A panel-witnessed profession takes part exactly like
    -- a spell-witnessed one — its spec spells ARE book-known even when its
    -- tier spells are not.
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
    return out, panelSound
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
-- own update event to re-fire. A non-header row whose NAME reads nil is a row
-- the client has not filled in yet, and it counts as missed for the same
-- reason — skipping it silently would complete a scan around a hole.
--
-- The evidence table `ev` both adapters return additionally carries:
--   ev.res     which chain rung(s) resolved the rows of a usable scan
--              ("recipe-link" / "name" / mixed tallies) — the trace renders it
--              as res=… so the owner can see which strategy is carrying the
--              surface on their client.
--   ev.sample  for a refused scan, the RAW evidence of ONE missed row (row
--              name, recipe-link string or "nil", item-link string or "nil"),
--              bounded and defanged — the exact facts that diagnosed the live
--              11509 miss, kept on the record so the next drift does not need
--              a hand-typed /run to see.
----------------------------------------------------------------------

-- Both link shapes a recipe link has been seen (or could reasonably start) to
-- carry. The craft surface answers "enchant:<teaching spell id>" — verified
-- correct live. "spell:" is accepted as well so a future client that starts
-- returning spell links on either surface resolves through the cheap rung
-- instead of falling to the name rung.
local function spellFromRecipeLink(link)
    if type(link) ~= "string" then return nil end
    local id = link:match("enchant:(%d+)") or link:match("spell:(%d+)")
    return tonumber(id)
end
Professions.SpellFromRecipeLink = spellFromRecipeLink

local function itemIDFromLink(link)
    if type(link) ~= "string" then return nil end
    return tonumber(link:match("item:(%d+)"))
end
Professions.ItemIDFromLink = itemIDFromLink

----------------------------------------------------------------------
-- THE ROW RESOLUTION CHAIN — measured, not assumed
--
-- The defect this section answers was measured on the owner's live client
-- (1.15.9 / 11509, blacksmithing open, a real recipe row):
--
--     GetTradeSkillRecipeLink(2)  =>  nil
--     GetTradeSkillItemLink(2)    =>  [Glinting Steel Dagger]   (an ITEM link)
--
-- The function exists — the no-api gate passes — and it answers nil for every
-- real row, so a resolver built on the recipe link alone reads 165 recipes and
-- resolves none of them: rows=176 ids=0 unresolved, forever, which is exactly
-- what the live trace showed. The craft surface (enchanting) is DIFFERENT: its
-- "enchant:" link was verified correct, so the link stays the chain's first
-- rung everywhere and the surfaces simply fall through it differently.
--
-- The rungs, in order, per row:
--
--   1  RECIPE LINK   "enchant:" or "spell:" — free when the client answers.
--   2  PRODUCT ITEM  the crafted item's id against the DATASET would be next,
--                    but the dataset carries NO produced-item ids: the fact
--                    source (dev/professions-facts.txt) has none to generate
--                    from — addendum §2, the same hole that forced the reagent
--                    harvest. The 770 [item] rows are the TEACHING items
--                    (plans/schematics), a different thing. The one measured
--                    source of product ids we do hold is the reagent harvest
--                    (`reagents[spell].o`), taken live from this very window
--                    on an earlier complete scan — so product ids serve as the
--                    NAME-COLLISION TIEBREAK below rather than as a rung of
--                    their own, because a cache seeded by successful scans
--                    cannot be the thing successful scans depend on.
--   3  NAME          the row's name from GetTradeSkillInfo/GetCraftInfo IS the
--                    teaching spell's name, and the client resolves dataset
--                    spell ids to names in its own locale via GetSpellInfo
--                    (spell data is client-local on Era). The map is built
--                    from the CLIENT'S names, so the locale rule holds; a
--                    dataset spell whose name reads nil is a class-4 cold read
--                    and is simply absent from the map — an unmatched row
--                    stays MISSED, never guessed.
--
-- A row no rung resolves is MISSED, and the three-state honesty above does the
-- rest: missed > 0 refuses the whole scan and writes nothing.
----------------------------------------------------------------------

-- name(lower) -> teaching spell id for ONE profession, built from the client's
-- own spell names. Returns map, ambiguous — `ambiguous` holds the names that
-- belong to MORE than one dataset spell in this profession (sorted candidate
-- lists, class 8), because letting pairs()-luck pick a winner would be a wrong
-- answer wearing a right one's name. Memoised only when EVERY spell in the
-- profession yielded a name: a map built over a cold read must not stick for
-- the session (class 5 — sticky calibration), so a partial build serves its one
-- scan and is thrown away.
function Professions.RecipeNameMap(profKey)
    local cached = Professions._recipeNames and Professions._recipeNames[profKey]
    if cached then return cached.map, cached.ambiguous end
    if not GetSpellInfo then return nil end
    if not Dataset.LoadCore() then return nil end
    local idx = Dataset.profIdx[profKey]
    if not idx then return nil end
    local list = Dataset.profRecipes[idx] or {}

    local byName, full = {}, true
    for i = 1, #list do
        local spell = list[i]
        local ok, name = pcall(GetSpellInfo, spell)
        if ok and type(name) == "string" and name ~= "" then
            local nm = name:lower()
            local b = byName[nm]
            if b then b[#b + 1] = spell else byName[nm] = { spell } end
        else
            full = false               -- cold read: this spell answers nothing today
        end
    end

    local map, ambiguous = {}, nil
    for nm, spells in pairs(byName) do
        if #spells == 1 then
            map[nm] = spells[1]
        else
            table.sort(spells)
            ambiguous = ambiguous or {}
            ambiguous[nm] = spells
        end
    end

    if full then
        Professions._recipeNames = Professions._recipeNames or {}
        Professions._recipeNames[profKey] = { map = map, ambiguous = ambiguous }
    end
    return map, ambiguous
end

-- Which of `cands` (teaching spell ids) produces item `itemID`? Answered ONLY
-- from the harvested reagent cache — a fact measured off a live window by an
-- earlier complete scan — and only when exactly ONE candidate claims the item.
-- Anything less certain is nil, and the row stays missed.
function Professions.SpellForProduct(cands, itemID)
    itemID = tonumber(itemID)
    if not itemID or type(cands) ~= "table" then return nil end
    local S = ns.Store
    local area = S and S.ProfessionsReagents and S.ProfessionsReagents(false)
    if not area then return nil end
    local pick
    for i = 1, #cands do
        local e = area[cands[i]]
        if e and e.o == itemID then
            if pick then return nil end          -- two claims: still ambiguous
            pick = cands[i]
        end
    end
    return pick
end

-- One row of either surface through the chain. Returns spell, how — where
-- `how` names the rung for the forensics ("recipe-link", "name",
-- "name+product") — or nil for a row nothing resolved.
function Professions.ResolveRowSpell(rowName, recipeLink, itemLink, profKey)
    local spell = spellFromRecipeLink(recipeLink)
    if spell then return spell, "recipe-link" end
    if profKey and type(rowName) == "string" and rowName ~= "" then
        local map, ambiguous = Professions.RecipeNameMap(profKey)
        if map then
            local nm = rowName:lower()
            local hit = map[nm]
            if hit then return hit, "name" end
            local cands = ambiguous and ambiguous[nm]
            if cands then
                local pick = Professions.SpellForProduct(cands, itemIDFromLink(itemLink))
                if pick then return pick, "name+product" end
            end
        end
    end
    return nil
end

-- Raw-evidence sample for ONE missed row, bounded for the saved-variable ring:
-- the link escapes are defanged (| -> !) so a pasted trace row cannot render as
-- a live link mid-bug-report, and everything is truncated.
local function sampleLink(v)
    if v == nil then return "nil" end
    if type(v) ~= "string" then return "(" .. type(v) .. ")" end
    v = v:gsub("|", "!")
    if #v > 70 then v = v:sub(1, 67) .. "..." end
    return v
end

function Professions.MissSample(rowName, recipeLink, itemLink)
    return {
        nm = (type(rowName) == "string") and rowName:sub(1, 40) or "nil",
        rl = sampleLink(recipeLink),
        il = sampleLink(itemLink),
    }
end

-- The per-scan strategy tally rendered for the trace: one rung's name when one
-- rung did all the work (the common case), "rung=n" pairs when they mixed.
function Professions.SummarizeVia(via)
    local keys = {}
    for k in pairs(via or {}) do keys[#keys + 1] = k end
    if #keys == 0 then return nil end
    if #keys == 1 then return keys[1] end
    table.sort(keys)
    local parts = {}
    for i = 1, #keys do parts[#parts + 1] = keys[i] .. "=" .. tostring(via[keys[i]]) end
    return table.concat(parts, ",")
end

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
        elseif rec.r == "settled" then
            -- A verified skip is neither a full success nor a refusal: it gets
            -- its own tally so "247 settled, 1 ok" reads as the design working
            -- rather than as 247 of something going wrong.
            st.settled = (st.settled or 0) + 1
        elseif rec.r == "settled-collapsed" then
            -- The loop killer's verdict: a collapsed VIEW of the settled truth
            -- was witnessed and declined to verify — deliberately, not as a
            -- failure. Its own tally, so a player who lives with collapsed
            -- headers reads as the design working, not as endless refusals.
            st.settledc = (st.settledc or 0) + 1
        else
            st.reasons[rec.r or "?"] = (st.reasons[rec.r or "?"] or 0) + 1
        end
    end

    -- Settled verdicts COALESCE in the ring: a crafting spree answers "settled"
    -- once per craft, and thirty of those would push the rows that explain
    -- refusals off the end of the ring. Consecutive settled rows for the same
    -- profession collapse onto one row with a running count. The session and
    -- stored rings share row TABLES, so bumping the shared row updates both.
    -- "settled-collapsed" coalesces for the same reason: a crafting spree in a
    -- collapsed window answers it once per craft.
    if rec.r == "settled" or rec.r == "settled-collapsed" then
        local ring = Professions._trace
        local last = ring and ring[#ring]
        if last and last.r == rec.r and last.p == rec.p and last.s == rec.s then
            last.c = (last.c or 1) + 1
            last.t = rec.t
            return true
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
    if rec.c ~= nil then parts[#parts + 1] = "x" .. tostring(rec.c) end
    if rec.n ~= nil then parts[#parts + 1] = "rows=" .. tostring(rec.n) end
    if rec.i ~= nil then parts[#parts + 1] = "ids=" .. tostring(rec.i) end
    if rec.u ~= nil and rec.u > 0 then parts[#parts + 1] = "unresolved=" .. tostring(rec.u) end
    if rec.res then parts[#parts + 1] = "res=" .. tostring(rec.res) end
    if rec.w then parts[#parts + 1] = "collapse=" .. tostring(rec.w) end
    if rec.g then parts[#parts + 1] = "guard=" .. tostring(rec.g) end
    if rec.d then parts[#parts + 1] = "ladder=" .. tostring(rec.d) end
    if type(rec.x) == "table" then
        parts[#parts + 1] = "miss[nm=" .. tostring(rec.x.nm)
            .. " rl=" .. tostring(rec.x.rl) .. " il=" .. tostring(rec.x.il) .. "]"
    end
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

----------------------------------------------------------------------
-- THE COLLAPSE WITNESS  (fix/professions-collapse)
--
-- The exposure this section closes: a window opened with COLLAPSED category
-- headers enumerates fewer rows, every visible row resolves, nothing reads as
-- missing — and a full scan of it would write the shortened set as the
-- character's complete known-recipe list. The view guard cannot see it (no
-- filter is engaged) and the completeness gate cannot see it (nothing visible
-- failed). It is the view-filter lie arriving through a door nobody watched.
--
-- The witness: on this API family a header row reports its expanded state
-- through the same info getter the row walk already calls — one return past
-- numAvailable on the trade-skill surface, one further on the craft surface.
-- The catalog (11509) carries NAMES ONLY, no signatures, so the position is
-- never trusted raw: the value is accepted only when it is a BOOLEAN and only
-- when it is COHERENT — a header that claims "collapsed" while its member rows
-- are visibly enumerated right under it is not a witness, it is a client whose
-- return layout we misread, and guessing there would wedge the capture. Any
-- non-boolean or incoherent read files the whole window as "unreadable" and the
-- capture falls back to expand-all-before-every-full-scan (blind, no restore —
-- restoring needs a witness to know what to restore).
--
-- With a READABLE witness, a full scan of a collapsed window becomes:
-- expand all (the index-0 convention, verified by MEASUREMENT — the call must
-- actually clear the witnessed collapse, the way professions_filters.lua
-- verifies its setter conventions) -> take the complete scan -> RESTORE the
-- player's exact prior collapse set, per header, by name. A collapse that
-- cannot be expanded is the refusal "collapsed" — retryable, never a shortened
-- write. Our own expand/collapse calls echo back as window updates; the latch
-- below keeps those echoes from re-entering the capture mid-flight.
----------------------------------------------------------------------

-- Fold the row walk's header observations into the scan evidence. Writes
-- ev.clp (array of { i, name } for witnessed-collapsed headers, top to bottom)
-- when every header's state is readable, or ev.cwit = "unreadable" when any is
-- not. No headers => neither field: nothing can be collapsed.
function Professions.FoldCollapseEvidence(ev, hdrs, hdrAt, n)
    if type(ev) ~= "table" or type(hdrs) ~= "table" or #hdrs == 0 then return ev end
    local clp = nil
    for k = 1, #hdrs do
        local h = hdrs[k]
        if type(h.x) ~= "boolean" or type(h.name) ~= "string" then
            -- Non-boolean: the return position did not answer the question on
            -- this client. Nameless: even a true collapse could not be restored.
            ev.cwit = "unreadable"
            ev.clp = nil
            return ev
        end
        if h.x == false then
            if h.i < n and not hdrAt[h.i + 1] then
                -- "Collapsed", yet the very next enumerated row is a member.
                -- Incoherent — a real collapse hides its members — so the whole
                -- witness is disqualified rather than half-trusted.
                ev.cwit = "unreadable"
                ev.clp = nil
                return ev
            end
            clp = clp or {}
            clp[#clp + 1] = { i = h.i, name = h.name }
        end
    end
    ev.clp = clp
    return ev
end

-- Every expand/collapse call WE issue makes the client rebuild its list and
-- announce it (TRADE_SKILL_UPDATE / CRAFT_UPDATE). Handling our own echo as a
-- capture opportunity mid-roundtrip would recurse into the capture that issued
-- it. The latch is held only across the client call itself.
--
-- THE DISCIPLINE, STATED FOR SYNCHRONOUS DISPATCH (fix/filter-reentry, class 9):
-- on interface 11509 the client dispatches that update INSIDE the expand call,
-- so every handler in the session — ours, the filter sub-surface's, and every
-- other addon's — runs before expandFn returns. Two properties make that safe
-- and both are now explicit rather than incidental:
--
--   * the latch is armed BEFORE the call and released only after it returns
--     (it always was — this is the half professions_filters.lua got wrong);
--   * it SAVES AND RESTORES rather than clearing to nil, so a restore nested
--     inside an expand cannot disarm the expand's own latch on the way out,
--     and a depth fuse refuses a third level outright instead of recursing.
--
-- The filter sub-surface reads this latch too (Filters.PeerBusy): our expand
-- echo must not make its clear-on-open fire in the middle of our scan.
local MAX_ECHO_DEPTH = 2
local function withCollapseLatch(surface, fn)
    Professions._collapseLatch = Professions._collapseLatch or {}
    Professions._collapseDepth = Professions._collapseDepth or {}
    local depth = Professions._collapseDepth[surface] or 0
    if depth >= MAX_ECHO_DEPTH then
        Professions._collapseRefused = (Professions._collapseRefused or 0) + 1
        Professions.RecordAttempt({
            e = "collapse", s = surface, r = "reentry-refused",
            g = Professions.ClientBuild and Professions.ClientBuild() or nil,
        })
        return false
    end
    local was = Professions._collapseLatch[surface]
    Professions._collapseDepth[surface] = depth + 1
    Professions._collapseLatch[surface] = true
    local ok = pcall(fn)
    Professions._collapseLatch[surface] = was
    Professions._collapseDepth[surface] = depth
    return ok
end
Professions._withCollapseLatch = withCollapseLatch   -- the self-tests drive it directly

-- Is one of OUR client roundtrips in flight on this surface? The filter
-- sub-surface asks before it acts on any window update (class 9).
function Professions.WindowEchoLatched(surface)
    local L = Professions._collapseLatch
    if not L then return false end
    if surface then return L[surface] and true or false end
    for _, v in pairs(L) do if v then return true end end
    return false
end

-- Find the CURRENT row index of the header named `name`. Indexes shift every
-- time a header collapses or expands, so a restore must never reuse the index
-- the collapse was witnessed at — it re-finds by name, fresh, per call.
local function findHeaderRow(surface, name)
    local numFn, infoFn
    if surface == "craft" then numFn, infoFn = GetNumCrafts, GetCraftInfo
    else numFn, infoFn = GetNumTradeSkills, GetTradeSkillInfo end
    if not (numFn and infoFn) then return nil end
    local okN, n = pcall(numFn)
    if not okN or type(n) ~= "number" then return nil end
    for i = 1, n do
        local nm, kind
        if surface == "craft" then
            local ok, a, _, c = pcall(infoFn, i)
            if ok then nm, kind = a, c end
        else
            local ok, a, b = pcall(infoFn, i)
            if ok then nm, kind = a, b end
        end
        if kind == "header" and nm == name then return i end
    end
    return nil
end

-- Re-collapse the player's prior collapse set, bottom-up (collapsing a header
-- shifts only the indexes BELOW it, and the per-call re-find covers even that).
-- Best effort by design: a header that vanished mid-restore is skipped, a
-- window that closed stops the walk cold. Returns how many were restored.
local function restoreCollapse(surface, names)
    local collapseFn
    if surface == "craft" then collapseFn = CollapseCraftSkillLine
    else collapseFn = CollapseTradeSkillSubClass end
    if not collapseFn or type(names) ~= "table" then return 0 end
    local restored = 0
    for k = #names, 1, -1 do
        if not Professions.WindowIsOpen(surface) then break end
        local i = findHeaderRow(surface, names[k])
        if i then
            withCollapseLatch(surface, function() collapseFn(i) end)
            restored = restored + 1
        end
    end
    return restored
end
Professions._restoreCollapse = restoreCollapse   -- the self-tests drive it directly

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

    -- The name rung needs to know WHICH profession's names to build; the window
    -- names its own skill line even when the rows have not resolved, and the
    -- same localized map the skill panel uses turns that into a profKey. nil
    -- simply leaves the name rung unarmed — rows the link cannot resolve then
    -- stay missed, which is the honest degradation.
    local windowProf = Professions.WindowProfKey("tradeskill")
    local itemLinkFn = GetTradeSkillItemLink        -- catalog-verified at 11509

    local rows, ids, missed, via, names = {}, {}, 0, {}, {}
    local hdrs, hdrAt = {}, {}
    for i = 1, n do
        -- The 4th return rides the info read this loop already pays for: on this
        -- API family a header row carries its expanded state there. The value is
        -- WITNESSED, never assumed — anything non-boolean lands in the
        -- "unreadable" world below, because the catalog carries names only and a
        -- guessed collapse state wedges the capture in whichever direction the
        -- guess was wrong.
        local ok, name, kind, _, xpd = pcall(GetTradeSkillInfo, i)
        if not ok then return nil, "row-error", ev end
        names[i] = name                               -- the settled signature's per-row witness
        if kind ~= "header" then
            local okL, rl = pcall(GetTradeSkillRecipeLink, i)
            rl = okL and rl or nil
            local il
            if itemLinkFn then
                local okI, l = pcall(itemLinkFn, i)
                il = okI and l or nil
            end
            local spell, how = Professions.ResolveRowSpell(name, rl, il, windowProf)
            if spell then
                rows[#rows + 1] = { i = i, spell = spell }
                ids[#ids + 1] = spell
                via[how] = (via[how] or 0) + 1
            else
                missed = missed + 1
                if not ev.sample then ev.sample = Professions.MissSample(name, rl, il) end
            end
        else
            hdrAt[i] = true
            hdrs[#hdrs + 1] = { i = i, name = name, x = xpd }
        end
    end
    Professions.FoldCollapseEvidence(ev, hdrs, hdrAt, n)
    ev.ids, ev.missed = #ids, missed
    ev.res = Professions.SummarizeVia(via)
    if #ids == 0 then return nil, "unresolved", ev end
    if missed > 0 then return nil, "incomplete", ev end

    local profKey, unknown = Professions.ResolveProfession(ids)
    if not profKey then return nil, "unidentified", ev end

    local scan = { profKey = profKey, rows = rows, ids = ids, unknown = unknown,
                   complete = true, surface = "tradeskill", ev = ev, names = names }
    if GetTradeSkillLine then
        local ok, lname, rank, maxRank = pcall(GetTradeSkillLine)
        if ok and type(rank) == "number" and type(maxRank) == "number" and maxRank > 0 then
            scan.l, scan.m = rank, maxRank
        end
        if ok and type(lname) == "string" and lname ~= "" then scan.line = lname end
    end
    -- The evidence rides the success too: the ok trace row wants rows/ids/res.
    return scan, nil, ev
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

    -- Same chain as the trade-skill surface, same order. Here the recipe link
    -- was verified CORRECT live ("enchant:"), so rung 1 is expected to do all
    -- the work; the name rung is the safety net should this surface ever drift
    -- the way the trade-skill one did. Most enchants produce no item, so the
    -- item link (GetCraftItemLink, catalog-verified) is mostly nil here — it
    -- rides along for the forensics sample and the collision tiebreak only.
    local windowProf = Professions.WindowProfKey("craft")
    local itemLinkFn = GetCraftItemLink

    local rows, ids, missed, via, names = {}, {}, 0, {}, {}
    local hdrs, hdrAt = {}, {}
    for i = 1, n do
        -- Same collapse witness as the trade-skill surface, one return further
        -- along: this getter answers (name, subSpell, type, numAvailable,
        -- isExpanded). Non-boolean => unreadable, never a guess.
        local ok, name, _, kind, _, xpd = pcall(GetCraftInfo, i)
        if not ok then return nil, "row-error", ev end
        names[i] = name                               -- the settled signature's per-row witness
        if kind == "header" then
            hdrAt[i] = true
            hdrs[#hdrs + 1] = { i = i, name = name, x = xpd }
        end
        if kind ~= "header" then
            local okL, rl = pcall(GetCraftRecipeLink, i)
            rl = okL and rl or nil
            local il
            if itemLinkFn then
                local okI, l = pcall(itemLinkFn, i)
                il = okI and l or nil
            end
            local spell, how = Professions.ResolveRowSpell(name, rl, il, windowProf)
            if spell then
                rows[#rows + 1] = { i = i, spell = spell }
                ids[#ids + 1] = spell
                via[how] = (via[how] or 0) + 1
            else
                missed = missed + 1
                if not ev.sample then ev.sample = Professions.MissSample(name, rl, il) end
            end
        end
    end
    Professions.FoldCollapseEvidence(ev, hdrs, hdrAt, n)
    ev.ids, ev.missed = #ids, missed
    ev.res = Professions.SummarizeVia(via)
    if #ids == 0 then return nil, "unresolved", ev end
    if missed > 0 then return nil, "incomplete", ev end

    local profKey, unknown = Professions.ResolveProfession(ids)
    if not profKey then return nil, "unidentified", ev end

    local scan = { profKey = profKey, rows = rows, ids = ids, unknown = unknown,
                   complete = true, surface = "craft", ev = ev, names = names }
    if GetCraftDisplaySkillLine then
        local ok, lname, rank, maxRank = pcall(GetCraftDisplaySkillLine)
        if ok and type(rank) == "number" and type(maxRank) == "number" and maxRank > 0 then
            scan.l, scan.m = rank, maxRank
        end
        if ok and type(lname) == "string" and lname ~= "" then scan.line = lname end
    end
    return scan, nil, ev
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
-- THE SETTLED SIGNATURE  (perf/professions-scan)
--
-- The live defect this section answers: CaptureWindow ran the FULL resolve —
-- 176 rows x (info + recipe link + item link + name-map lookup), a name map of
-- up to 1,251 GetSpellInfo calls, the store diff, the cooldown fold and (first
-- time) the reagent harvest — on EVERY window event behind a one-second
-- throttle. Crafting a stack re-ran all of it per craft. The owner's report was
-- "pretty significant lag whenever i open my profession menus".
--
-- The fix shape: scan once, then VERIFY cheaply. After a complete accepted scan
-- the signature below is persisted; a later window event re-reads only the
-- cheap half of the window — GetNum*, the skill line, and one GetTradeSkillInfo/
-- GetCraftInfo per row — and compares it against the record. NO link asks, NO
-- GetSpellInfo, NO ApplyScan, NO harvest. Only when every component matches is
-- the event answered "settled" (a distinct trace verdict, never an "ok").
--
-- WHY THE COMPONENTS CANNOT LIE (the honesty argument, stated so the next
-- reader can attack it):
--
--   * row count + per-row NAME + per-row header/recipe shape, in order.
--     Learning a recipe INSERTS a row: the count changes, and every row at or
--     after the insertion point changes name. There is no edit of the recipe
--     list that leaves both the count and the full ordered name sequence
--     intact. A narrowed view that slipped past the guard, a client that
--     reordered its list — they move names or counts. A COLLAPSED header moves
--     them too, but in a shape the verify can PROVE is only a collapse
--     (fix/professions-collapse): that one shape earns the distinct
--     "settled-collapsed" verdict instead of a drift-forced rescan, because
--     rescanning a restored-collapsed window would loop forever. See
--     VerifySettled's second verdict.
--   * the window's own skill line (name, rank, maxRank). A rank-up changes
--     `rank`; a different profession in the same window changes `name`.
--   * the LIVE record must already hold the bitmap the skip preserves (same
--     known count as the record). A skip never substitutes for data we no
--     longer have — a wiped store or an unseeded session falls through to a
--     full capture instead of skipping over a hole.
--   * ANY unreadable component — a nil name, a non-number count, a missing
--     API — is a mismatch, and a mismatch is always answered by a FULL capture.
--     There is no partial credit and no "probably fine".
--   * the record is stamped with the DATASET version and the CLIENT build; a
--     record from either other world is not evidence and is ignored.
--
-- The record also carries the accepted scan's row->teaching-spell mapping.
-- Because the per-row names were just verified IDENTICAL to the enumeration
-- the mapping was proven against, the mapping is licensed for the one job the
-- settled path still has to do every time: reading the COOLDOWNS. Consuming a
-- cooldown recipe fires the window's update; the settled pass folds cooldowns
-- through the same proof-gated FoldCooldowns and publishes a consumption
-- immediately, so "can I transmute today" never waits for a manual rescan.
--
-- Staleness: the learning signals (see Professions.EVENTS) mark a profession
-- STALE, and a stale profession never settles — the next window look runs the
-- full capture, which refreshes the record and clears the mark. A signal that
-- cannot be attributed to one profession marks every profession that could
-- have skipped. Manual rescan (ForceRescan) bypasses the signature entirely.
----------------------------------------------------------------------

function Professions.ClientBuild()
    if not GetBuildInfo then return "?" end
    local ok, v, b = pcall(GetBuildInfo)
    if not ok then return "?" end
    return tostring(v) .. "-" .. tostring(b)
end

-- The staleness marks. `profKey` nil means "could not attribute": every
-- profession that holds a settled record — session or store — is marked,
-- because those are exactly the professions a skip could otherwise hide the
-- change from. A profession with no record always full-scans anyway.
function Professions.MarkStale(profKey)
    Professions._stale = Professions._stale or {}
    if profKey then
        Professions._stale[profKey] = true
        return true
    end
    for key in pairs(Professions._settled or {}) do
        Professions._stale[key] = true
    end
    local mine = Professions.SettledArea(false)
    if mine then
        for key in pairs(mine) do Professions._stale[key] = true end
    end
    return true
end

function Professions.IsStale(profKey)
    return (Professions._stale and Professions._stale[profKey]) and true or false
end

-- The per-character slot in the store's settled area. Keyed by owner because
-- SavedVariables are account-wide and every character shares the file.
function Professions.SettledArea(create)
    local S = ns.Store
    local area = S and S.ProfessionsSettled and S.ProfessionsSettled(create)
    if not area then return nil end
    local key = Professions.SelfKey()
    if key == "" then return nil end
    local mine = area[key]
    if type(mine) ~= "table" then
        if not create then return nil end
        mine = {}
        area[key] = mine
    end
    return mine
end

-- Is this stamp/set-hash pair OUR coordinate system? Same stamp always is;
-- a different stamp is accepted when its recipe-set hash — carried on the
-- record, or named by the shipped [stampset] table — equals ours (Layer 1:
-- the 2026-08-10 metadata-only bump must never again cost a re-scan tour).
local function sameRecipeSet(ds, sh)
    if ds == Dataset.Version() then return true end
    if sh == nil then
        Dataset.LoadCompat()
        sh = Dataset.stampSet and Dataset.stampSet[ds] or nil
    end
    return sh ~= nil and sh == Dataset.SetHash()
end
Professions.SameRecipeSet = sameRecipeSet

local function settledRecordUsable(rec)
    if type(rec) ~= "table" then return false end
    if not sameRecipeSet(rec.ds, rec.sh) then return false end  -- another coordinate system
    if rec.build ~= Professions.ClientBuild() then return false end  -- another client's names
    if type(rec.n) ~= "number" or rec.n <= 0 then return false end
    if type(rec.names) ~= "table" or type(rec.rows) ~= "table" then return false end
    if type(rec.line) ~= "string" or rec.line == "" then return false end
    if type(rec.l) ~= "number" or type(rec.m) ~= "number" then return false end
    if type(rec.known) ~= "number" then return false end
    return true
end

-- Session first, store second (validated and hydrated into the session mirror).
function Professions.SettledGet(profKey)
    local s = Professions._settled and Professions._settled[profKey]
    if s then return s end
    local mine = Professions.SettledArea(false)
    local rec = mine and mine[profKey]
    if not settledRecordUsable(rec) then return nil end
    Professions._settled = Professions._settled or {}
    Professions._settled[profKey] = rec
    return rec
end

function Professions.SettledPut(profKey, rec)
    if type(profKey) ~= "string" or type(rec) ~= "table" then return false end
    Professions._settled = Professions._settled or {}
    Professions._settled[profKey] = rec
    local mine = Professions.SettledArea(true)
    if mine then mine[profKey] = rec end
    return true
end

-- nil clears every record for this character (manual rescan of "everything").
function Professions.SettledClear(profKey)
    if profKey then
        if Professions._settled then Professions._settled[profKey] = nil end
        local mine = Professions.SettledArea(false)
        if mine then mine[profKey] = nil end
    else
        Professions._settled = nil
        local mine = Professions.SettledArea(false)
        if mine then
            for key in pairs(mine) do mine[key] = nil end
        end
    end
    return true
end

-- Which settled record claims this window? Matched on the window's OWN skill
-- line string — no name map, no GetSpellInfo — plus the surface. At most a
-- handful of records exist per character, so the walk is trivial; the store's
-- keys are swept too so a fresh session can hydrate without a full scan.
function Professions.SettledForWindow(surface, lineName)
    for _, rec in pairs(Professions._settled or {}) do
        if rec.surface == surface and rec.line == lineName then return rec end
    end
    local mine = Professions.SettledArea(false)
    if mine then
        for key in pairs(mine) do
            local rec = Professions.SettledGet(key)     -- validates + hydrates
            if rec and rec.surface == surface and rec.line == lineName then return rec end
        end
    end
    return nil
end

-- THE VERIFY. Returns the settled record when — and only when — every
-- component of the live window matches it, or nil. Cost: one GetNum*, one
-- line read, and one info read per row. Nothing else. Every doubt is nil.
--
-- SECOND VERDICT (fix/professions-collapse, the loop killer): a window whose
-- enumeration is SHORTER than the record can be a collapsed VIEW of the very
-- truth the record holds — the player collapsed some headers, hiding exactly
-- those headers' member rows and nothing else. That is not drift and must not
-- be answered as drift: the full path would expand the window to rescan and
-- then restore the collapse, the restore's echo would look shorter again, and
-- expand->shrink->"drift"->rescan->expand would flicker forever. So when every
-- visible row is proven to be the record's row sequence with witnessed-
-- collapsed headers' members removed — header names matching, member runs
-- skipped only under a header whose own state reads boolean-false — the verify
-- DECLINES rather than fails: it returns the record with the verdict
-- "collapsed" and the caller stays settled, leaving staleness to the learning
-- events and the manual rescan. The proof needs the witness, so any
-- non-boolean header state in the shortened window is nil (drift semantics —
-- honest, and the full path's blind expand answers it).
--
-- Returns: rec                              -- exact match
--          rec, "collapsed", visRows, n     -- collapsed view; visRows is the
--                                              visible rows' proven index->spell
--                                              mapping (cooldown license), n the
--                                              visible row count
--          nil                              -- everything else
function Professions.VerifySettled(surface)
    if not Professions.CaptureAllowed() then return nil end
    local numFn, infoFn, lineFn
    if surface == "craft" then
        numFn, infoFn, lineFn = GetNumCrafts, GetCraftInfo, GetCraftDisplaySkillLine
    else
        numFn, infoFn, lineFn = GetNumTradeSkills, GetTradeSkillInfo, GetTradeSkillLine
    end
    if not (numFn and infoFn and lineFn) then return nil end

    local okL, lname, rank, maxRank = pcall(lineFn)
    if not okL or type(lname) ~= "string" or lname == "" then return nil end
    local rec = Professions.SettledForWindow(surface, lname)
    if not rec then return nil end
    if Professions.IsStale(rec.prof) then return nil end
    if type(rank) ~= "number" or type(maxRank) ~= "number" then return nil end
    if rank ~= rec.l or maxRank ~= rec.m then return nil end    -- rank drift => full

    local okN, n = pcall(numFn)
    if not okN or type(n) ~= "number" or n <= 0 then return nil end
    if n > rec.n then return nil end          -- collapse only ever SHRINKS: this is drift

    -- The live record must already carry what the skip preserves.
    local cur = Professions._live and Professions._live.p and Professions._live.p[rec.prof]
    if not (cur and cur.k ~= nil and cur.n == rec.known) then return nil end

    if n == rec.n then
        for i = 1, n do
            local name, isHeader
            if surface == "craft" then
                local ok, nm, _, kind = pcall(infoFn, i)
                if not ok then return nil end
                name, isHeader = nm, (kind == "header")
            else
                local ok, nm, kind = pcall(infoFn, i)
                if not ok then return nil end
                name, isHeader = nm, (kind == "header")
            end
            if type(name) ~= "string" or name ~= rec.names[i] then return nil end
            if isHeader == (rec.rows[i] ~= nil) then return nil end -- shape drifted
        end
        return rec
    end

    -- n < rec.n: the collapsed-view walk. Two pointers — `i` over the visible
    -- rows, `j` over the record — and the ONLY licensed skip is a member run
    -- directly under a header whose expanded state reads boolean false.
    local j = 1
    local visRows, sawCollapsed = nil, false
    for i = 1, n do
        local name, isHeader, xpd
        if surface == "craft" then
            local ok, nm, _, kind, _, x = pcall(infoFn, i)
            if not ok then return nil end
            name, isHeader, xpd = nm, (kind == "header"), x
        else
            local ok, nm, kind, _, x = pcall(infoFn, i)
            if not ok then return nil end
            name, isHeader, xpd = nm, (kind == "header"), x
        end
        if type(name) ~= "string" or j > rec.n then return nil end
        if isHeader then
            if rec.rows[j] ~= nil or rec.names[j] ~= name then return nil end
            j = j + 1
            if type(xpd) ~= "boolean" then return nil end   -- no witness, no license
            if xpd == false then
                sawCollapsed = true
                while j <= rec.n and rec.rows[j] ~= nil do j = j + 1 end
            end
        else
            if rec.rows[j] == nil or rec.names[j] ~= name then return nil end
            visRows = visRows or {}
            visRows[#visRows + 1] = { i = i, spell = rec.rows[j] }
            j = j + 1
        end
    end
    if j ~= rec.n + 1 then return nil end     -- the record was not fully accounted for
    if not sawCollapsed then return nil end   -- shorter with nothing collapsed: real drift
    return rec, "collapsed", visRows, n
end

-- Build the record off a proven-complete scan. Conservative: a scan that could
-- not read its own line, rank or every row name yields NO record — the window
-- simply keeps full-scanning, which is the pre-fix behavior and always honest.
function Professions.BuildSettledRecord(scan)
    if not (scan and scan.complete and scan.profKey and scan.surface) then return nil end
    if type(scan.line) ~= "string" or scan.line == "" then return nil end
    if type(scan.l) ~= "number" or type(scan.m) ~= "number" then return nil end
    if type(scan.names) ~= "table" or type(scan.ev) ~= "table" then return nil end
    local n = scan.ev.n
    if type(n) ~= "number" or n <= 0 then return nil end
    for i = 1, n do
        if type(scan.names[i]) ~= "string" then return nil end  -- an unreadable row is not evidence
    end
    local rows = {}
    for r = 1, #scan.rows do rows[scan.rows[r].i] = scan.rows[r].spell end
    local cur = Professions._live and Professions._live.p and Professions._live.p[scan.profKey]
    if not (cur and cur.k ~= nil and type(cur.n) == "number") then return nil end
    local names = {}
    for i = 1, n do names[i] = scan.names[i] end
    return {
        prof = scan.profKey, surface = scan.surface, line = scan.line,
        l = scan.l, m = scan.m, n = n, known = cur.n,
        names = names, rows = rows,
        at = Professions.NowEpoch(),         -- assigned below; resolved at call time
        ds = Dataset.Version(), sh = Dataset.SetHash(),
        build = Professions.ClientBuild(),
    }
end

-- The record's row list in FoldCooldowns' shape, ordered by row index (class 8:
-- nothing downstream may inherit pairs() luck). Cached on the record.
function Professions.SettledRowsArray(rec)
    if rec._rowsArr then return rec._rowsArr end
    local idx = {}
    for i in pairs(rec.rows) do idx[#idx + 1] = i end
    table.sort(idx)
    local arr = {}
    for j = 1, #idx do arr[j] = { i = idx[j], spell = rec.rows[idx[j]] } end
    rec._rowsArr = arr
    return arr
end

-- The one expensive-ish thing a settled pass still does: read every recipe
-- row's cooldown, through the same proof-gated fold a full scan uses. The
-- pseudo-scan is licensed by the row-for-row name verification that just
-- passed. Returns changed(bool), consumed(bool).
--
-- `rowsArr` (optional) narrows the pass to a VERIFIED SUBSET of the record's
-- rows — the collapsed-view verdict hands its visible rows here, because the
-- hidden rows' indexes name nothing in the current enumeration. The partial
-- fold stays honest: FoldCooldowns only PROVES the keys its rows witness, so a
-- hidden recipe's cooldown is left alone rather than "proven ready" — and a
-- shared-group cooldown (the transmutes) is witnessed by ANY visible member,
-- because sharing is the group's whole meaning.
function Professions.SettledCooldownPass(rec, stamp, rowsArr)
    local pseudo = { complete = true, surface = rec.surface,
                     rows = rowsArr or Professions.SettledRowsArray(rec) }
    local running, proven = Professions.FoldCooldowns(pseudo, stamp)
    if not (running and proven) then return false, false end
    local L = Professions._live
    local before = {}
    if L then
        for key in pairs(proven) do before[key] = L.c[key] end
    end
    local _, consumed = Professions.ApplyCooldowns(running, proven)
    local changed = consumed
    if not changed and L then
        for key in pairs(proven) do
            if L.c[key] ~= before[key] then changed = true break end
        end
    end
    return changed, consumed
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

-- (itemIDFromLink lives beside the row-resolution chain above; the harvest
-- shares it.)

-- PURE-ish: every client call is injectable through `api` so the harness can
-- drive cold, warm and half-warm worlds without a client.
--
-- Returns out, allComplete. `allComplete` is true only when EVERY row that
-- reported reagents produced a complete entry — the witness the persistence
-- stamp below requires, because "harvested" written over a half-warm window
-- would freeze the holes in for a whole dataset generation.
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

    local out, allComplete = {}, true
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
            else
                allComplete = false            -- this recipe stays unharvested today
            end
        end
    end
    return out, allComplete
end

----------------------------------------------------------------------
-- HARVEST PERSISTENCE + TIME-SLICING  (perf/professions-scan)
--
-- Reagents are GAME FACTS: identical across sessions until the dataset (the
-- recipe universe itself) changes. So "harvested" is now a per-profession stamp
-- in the store keyed by the DATASET VERSION rather than a per-session latch —
-- one complete harvest per profession per dataset generation, ever. The stamp
-- is written only off an `allComplete` harvest; a partial one stores its
-- complete entries (each is individually proven) and leaves the stamp absent so
-- the next accepted scan or settled pass tries again. Manual rescan deletes the
-- stamp.
--
-- TIME-SLICING. The harvest was the dominant first-open cost (~4 reagent reads
-- per recipe x ~165 recipes, plus product link and yield — measured in the
-- call-budget suite). Nothing consumes it synchronously — StoreReagents landing
-- a few frames later changes no answer — so the walk is sliced into chunks of
-- HARVEST_CHUNK rows, one chunk per timer tick. Guards per chunk, all of them
-- aborts (never partial stamps): module disabled, teardown, window closed, a
-- newer job superseding this one, or the window's row count drifting from the
-- count the job was built against (the row indexes would no longer name the
-- rows the scan proved). Without a timer service the whole walk runs inline,
-- which is exactly the pre-fix cost and still correct.
----------------------------------------------------------------------

Professions.HARVEST_CHUNK = 24

function Professions.HarvestStamps(create)
    local S = ns.Store
    return S and S.ProfessionsHarvestStamps and S.ProfessionsHarvestStamps(create) or nil
end

-- Is this profession's harvest already complete for THIS dataset? Keyed on
-- the recipe SET, not the whole-content stamp: reagents are per-teaching-spell
-- facts, so a metadata-only bump invalidates none of them (Layer 1).
function Professions.HarvestStamped(profKey)
    local stamps = Professions.HarvestStamps(false)
    local rec = stamps and stamps[profKey]
    if type(rec) ~= "table" then return false end
    return Professions.SameRecipeSet(rec.ds, rec.sh)
end

function Professions.ClearHarvestStamp(profKey)
    local stamps = Professions.HarvestStamps(false)
    if stamps and profKey then stamps[profKey] = nil end
    if Professions._harvested then Professions._harvested[profKey or ""] = nil end
    return true
end

local function harvestWindowStillValid(job)
    if not Professions.IsEnabled() or Professions.IsTeardown() then return false end
    if not (Professions._windowOpen and Professions._windowOpen[job.surface]) then return false end
    local numFn = (job.surface == "craft") and GetNumCrafts or GetNumTradeSkills
    if not numFn then return false end
    local ok, n = pcall(numFn)
    if not ok or n ~= job.n then return false end   -- the enumeration moved: indexes are stale
    return true
end

local function finishHarvest(job)
    Professions._harvestJob = nil
    local stored = Professions.StoreReagents(job.out)
    if stored == false then
        -- No store: fall back to the session latch so an accepted scan does not
        -- reschedule forever against a store that is not there.
        Professions._harvested = Professions._harvested or {}
        Professions._harvested[job.prof] = true
        return false
    end
    if job.allComplete then
        local stamps = Professions.HarvestStamps(true)
        if stamps then
            stamps[job.prof] = { ds = Dataset.Version(), sh = Dataset.SetHash(),
                                 at = Professions.NowEpoch() }
        end
        Professions._harvested = Professions._harvested or {}
        Professions._harvested[job.prof] = true
    end
    return true
end

local function harvestStep(job)
    if Professions._harvestJob ~= job then return end        -- superseded
    if not harvestWindowStillValid(job) then
        Professions._harvestJob = nil
        -- The entries gathered so far are each individually complete facts;
        -- store them, but the profession stays unstamped and retries later.
        if next(job.out) then Professions.StoreReagents(job.out) end
        return
    end
    local from = job.nextRow
    local to = math.min(from + Professions.HARVEST_CHUNK - 1, #job.rows)
    local slice = {}
    for r = from, to do slice[#slice + 1] = job.rows[r] end
    local part, complete = Professions.HarvestReagents(
        { complete = true, surface = job.surface, rows = slice })
    if part then
        for spell, entry in pairs(part) do job.out[spell] = entry end
        if complete == false then job.allComplete = false end
    else
        job.allComplete = false
    end
    job.nextRow = to + 1
    if job.nextRow > #job.rows then
        finishHarvest(job)
        return
    end
    if _G.C_Timer and _G.C_Timer.After then
        _G.C_Timer.After(0, function() harvestStep(job) end)
    else
        harvestStep(job)
    end
end

-- Schedule (or run, timer-less) the harvest for a proven window. `rows` is the
-- accepted scan's (or verified settled record's) row->spell list; `n` the row
-- count the proof was taken against.
function Professions.ScheduleHarvest(surface, profKey, rows, n)
    if type(rows) ~= "table" or #rows == 0 then return false end
    Professions._harvestGen = Professions._harvestGen + 1
    local job = {
        gen = Professions._harvestGen, surface = surface, prof = profKey,
        rows = rows, n = n, nextRow = 1, out = {}, allComplete = true,
    }
    Professions._harvestJob = job
    if _G.C_Timer and _G.C_Timer.After then
        _G.C_Timer.After(0, function() harvestStep(job) end)
    else
        harvestStep(job)
    end
    return true
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
    -- COORDINATE HONESTY (feat/dataset-migration). The stored payload may have
    -- been written against another dataset build, and BuildPayload stamps
    -- whatever it seeds with the CURRENT version — so seeding foreign-ordinal
    -- bitmaps verbatim would REPUBLISH them under our stamp: a wrong decode
    -- sent to every peer, the worst form of the lie. Rescue or translate when
    -- the record's recipe set can be named; otherwise seed only the
    -- coordinate-free facts and let the next window scan rebuild the bitmap.
    local mp, _, verdict = Professions.MigratePayload(d)
    if verdict == "current" or verdict == "rescued" or verdict == "migrated" then
        d = mp
    else
        local stripped = { p = {}, c = d.c }
        for key, rec in pairs(type(d.p) == "table" and d.p or {}) do
            stripped.p[key] = { l = rec.l, m = rec.m, t = rec.t, s = rec.s }
        end
        d = stripped
    end
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
--
-- `panelSound` is ProbeProfessions' second return: true only when the skill
-- panel was witnessed and COMPLETELY read. It is the erase licence. Presence
-- has two witnesses (tier spells, panel rows) and either alone may ADD; but
-- absence can only be proven by the panel, because Herbalism showed live that
-- a held profession can answer false to every tier-spell query. The panel
-- lists every skill the character holds, so a completely-read panel that
-- lacks a profession — with the spells also silent — is a real unlearn, and
-- the drop below fires. An unsound or unwitnessed panel drops NOTHING: a nil
-- read skips a row, it never erases (class 6).
function Professions.ApplyProbe(probe, panelSound)
    if type(probe) ~= "table" then return false end
    local L = live()
    for key, rec in pairs(probe) do
        local cur = L.p[key] or {}
        cur.t = rec.t
        cur.s = (#rec.s > 0) and rec.s or nil
        L.p[key] = cur
    end
    -- A profession the witnesses say this character no longer has is dropped —
    -- professions CAN be unlearned, and a stale row would claim a skill the
    -- character does not have. Secondary professions cannot be unlearned, but
    -- the witnesses answer for them too, so no exception is needed.
    if panelSound then
        for key in pairs(L.p) do
            if not probe[key] then L.p[key] = nil end
        end
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
    cur.cv = nil          -- a complete window scan covers the ENTIRE current set
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
                      u = (rec.u and rec.u > 0) and rec.u or nil, a = rec.a,
                      cv = rec.cv }
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
        sh = Dataset.SetHash(),      -- the coordinate system's IDENTITY (additive)
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
    local out = { "v=" .. tostring(payload.v or 0), "ds=" .. tostring(payload.ds or ""),
                  "sh=" .. tostring(payload.sh or "") }
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
            tostring(r.cv or ""),
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
    -- RECEIVE-TIME MIGRATION (feat/dataset-migration). A payload from a peer on
    -- another dataset build is rescued (identical recipe set) or translated
    -- (shipped migration) into current coordinates BEFORE projection; an
    -- unknown coordinate system is stored untouched and every read seam
    -- refuses it exactly as before — never a wrong decode in either case. The
    -- sync store's cached blob (the relay bytes) is not what we write here:
    -- MigratePayload copies, it never mutates its input.
    local mp, changed = Professions.MigratePayload(data)
    if changed then data = mp end
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
    Professions.RegisterDelegatesNamespace()
    return true
end

----------------------------------------------------------------------
-- THE "delegates" NAMESPACE  (profession-delegates phase 1)
--
-- Account-granular, exactly like syncns.lua's "attune" precedent: ownerKey is
-- the DEFAULT (this Nexus account id) — one payload per ACCOUNT, one rev to
-- gate — and the payload is { v, at, cfg } where `cfg` is the whole delegates
-- config and `at` is the SERVER-TIME stamp of the last local edit. Per-owner
-- transport is the store's owner-wins-by-rev; the CROSS-owner conflict rule
-- (which account's copy IS the config) is last-writer-wins on `at`, decided at
-- read time by Store.DelegatesPickWinner — the Daseeki.Config registry's LWW
-- discipline lifted to cross-owner, with rev then ownerKey as deterministic
-- tiebreaks.
--
-- OLD CLIENTS ARE SAFE BY CONSTRUCTION, the attune argument verbatim:
-- Mesh.HandleNSPayload -> Sync.ApplyInbound stores ANY namespace key it is
-- handed, registered or not; Sync._DeliverOne finds no spec and returns. An
-- un-updated peer caches this payload silently, errors on nothing, and replays
-- it to the consumer the moment it updates (syncns.lua's attune self-test
-- asserts exactly this path for an unregistered key).
--
-- onRemote does NOT adopt anything into the local config — reads resolve
-- through Store.DelegatesEffective every time, so a winning remote payload
-- changes the answer without a write (and a local EDIT adopts the effective
-- winner first, so editing from a second account never clobbers the first's
-- designations). onRemote only pumps the repaint.
----------------------------------------------------------------------

local DELEGATES_NS_KEY = "delegates"
Professions.DELEGATES_NS_KEY = DELEGATES_NS_KEY

local function delegatesProvide()
    local S = ns.Store
    if not (S and S.DelegatesSnapshot) then return nil end
    return S.DelegatesSnapshot()   -- nil until the owner ever edits => nothing to publish
end
Professions._delegatesProvideFn = delegatesProvide

local function onRemoteDelegates(_ownerKey, _data)
    -- The store already holds the payload (Sync.ApplyInbound put it there);
    -- reads re-resolve lazily. One repaint, the mesh's own bulk signal.
    local M = ns.Mesh
    if M and M.NoteStoreChanged then M.NoteStoreChanged()
    elseif ns.Fire then ns:Fire("STORE_REFRESHED") end
end
Professions._onRemoteDelegatesFn = onRemoteDelegates

function Professions.RegisterDelegatesNamespace()
    local S = suiteSync()
    if not S then return false end
    S.RegisterNamespace(DELEGATES_NS_KEY, {
        -- ownerKey omitted on purpose: defaults to this account's Nexus id
        -- (account-granular, the attune precedent).
        provide  = delegatesProvide,
        onRemote = onRemoteDelegates,
        pushOp   = PUSH_OP,
    })
    return true
end

-- The UI's one entry point after a designation edit: snapshot + queue for the
-- mesh (debounced there), and repaint this client immediately.
function Professions.DelegatesMarkDirty()
    local S = suiteSync()
    if S and S.MarkDirty then S.MarkDirty(DELEGATES_NS_KEY) end
    local M = ns.Mesh
    if M and M.NoteStoreChanged then M.NoteStoreChanged()
    elseif ns.Fire then ns:Fire("STORE_REFRESHED") end
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
    local probe, panelSound = Professions.ProbeProfessions()
    if not probe then return false end
    Professions.ApplyProbe(probe, panelSound)
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
    -- Our own expand/restore calls echo back as window updates — synchronously
    -- on some clients, a frame later on others. Re-entering the capture from
    -- inside its own roundtrip would scan a half-mutated window and (worse)
    -- recurse. Self-inflicted, so it gets neither ring space nor a ladder rung:
    -- the roundtrip that caused it records its own verdict.
    if Professions._collapseLatch and Professions._collapseLatch[surface] then
        return false, "collapse-echo"
    end
    -- ...and the same for the filter sub-surface's own native sequence. Its
    -- setters echo the identical events, INSIDE the call on interface 11509
    -- (class 9), and the list it is moving is one it narrows on purpose. The
    -- view guard would refuse this anyway ("probing"), but naming it here keeps
    -- a burst of self-inflicted echoes out of the forensics ring and off the
    -- retry ladder — the sequence issues its own re-capture when it finishes.
    local FS = ns.ProfessionFilters
    if FS and FS.NativeBusy and FS.NativeBusy(surface) then
        return false, "filter-echo"
    end
    event = event or (force and "forced" or "update")

    local wWorld = nil     -- which collapse world this attempt moved through (trace)

    local function refuse(reason, ev, guard)
        Professions.RecordAttempt({
            e = event, s = surface, f = force and true or nil,
            p = Professions.WindowProfKey(surface),
            r = reason, n = ev and ev.n, i = ev and ev.ids, u = ev and ev.missed,
            -- The raw evidence of one missed row and the rung tally of the rows
            -- that DID resolve: an "incomplete" that resolved 164 by name and
            -- missed one is a different diagnosis from one that resolved none.
            res = ev and ev.res, x = ev and ev.sample,
            w = wWorld, g = guard, d = Professions.RetryState(surface),
        })
        Professions.ScheduleRetry(surface, reason)
        return false, reason
    end

    if not Professions.CaptureAllowed() then return refuse("cold") end
    -- A narrowed list is a SHORT list, and a short list written as the known set
    -- is a confident lie about this character. See the view guard above.
    local narrowed, guardWhy = Professions.ViewNarrowedWhy(surface)
    if narrowed then return refuse("view-filtered", nil, guardWhy) end

    -- THE SETTLED SKIP (perf/professions-scan). Before any full work — and
    -- before the throttle, so a consumed cooldown is noticed on the very event
    -- that announced it — the cheap signature verify runs. It matches only when
    -- every component of the live window equals the last accepted scan's record
    -- AND the profession is not stale; every doubt falls through to the full
    -- path below. A manual rescan (event "rescan") never consults it.
    if event ~= "rescan" then
        local rec, view, visRows, nVis = Professions.VerifySettled(surface)
        if rec and view == "collapsed" then
            -- THE LOOP KILLER (fix/professions-collapse). The shorter
            -- enumeration is a collapsed VIEW of the settled truth, proven row
            -- for row — EXPECTED, not drift. Verification is declined but the
            -- profession STAYS SETTLED: no rescan, no expand, no flicker.
            -- Staleness still belongs to the learning/rank-up events and the
            -- manual rescan, both of which bypass this verdict entirely.
            Professions.CancelRetry(surface)
            Professions.RecordAttempt({
                e = event, s = surface, f = force and true or nil, p = rec.prof,
                r = "settled-collapsed", n = nVis, g = guardWhy, d = "cleared",
            })
            -- Cooldowns still publish off the VISIBLE rows — their mapping was
            -- just proven, and a hidden row's key is simply not proven either
            -- way. No harvest here: its indexes would name hidden rows.
            local changed, consumed = false, false
            if visRows and #visRows > 0 then
                changed, consumed = Professions.SettledCooldownPass(
                    rec, nowEpoch(), visRows)
            end
            if changed then Professions.MarkDirty(consumed) end
            return true, rec.prof, consumed
        end
        if rec then
            Professions.CancelRetry(surface)
            Professions.RecordAttempt({
                e = event, s = surface, f = force and true or nil, p = rec.prof,
                r = "settled", n = rec.n, g = guardWhy, d = "cleared",
            })
            local changed, consumed = Professions.SettledCooldownPass(
                rec, nowEpoch())
            -- A harvest this dataset has not completed yet still runs off the
            -- verified row mapping — that is how an aborted (window closed
            -- mid-slices) harvest heals without a full rescan.
            if not Professions.HarvestStamped(rec.prof)
               and not (Professions._harvested and Professions._harvested[rec.prof])
               and not Professions._harvestJob then
                Professions.ScheduleHarvest(surface, rec.prof,
                    Professions.SettledRowsArray(rec), rec.n)
            end
            if changed then Professions.MarkDirty(consumed) end
            return true, rec.prof, consumed
        end
    end

    local now = nowMono()
    if not force and Professions._scanAt and (now - Professions._scanAt) < SCAN_THROTTLE then
        return refuse("throttled", nil, guardWhy)
    end

    local function doScan()
        if surface == "craft" then return Professions.ScanCraftWindow() end
        return Professions.ScanTradeSkillWindow()
    end
    local scan, why, ev = doScan()

    -- ══ THE COLLAPSE GATE (fix/professions-collapse) ═══════════════════════
    -- Runs on the scan's collapse EVIDENCE, whatever its verdict was: a
    -- collapsed window can produce a scan that looks complete (the lie this
    -- branch exists to stop) or a refusal that expanding may heal.
    local expandFn, numFn
    if surface == "craft" then expandFn, numFn = ExpandCraftSkillLine, GetNumCrafts
    else expandFn, numFn = ExpandTradeSkillSubClass, GetNumTradeSkills end
    -- "Closed" here means the client SAID so (the tri-state latch's false) —
    -- a surface never latched this session still captures, as it always has.
    local function windowVanished()
        return (Professions._windowOpen and Professions._windowOpen[surface]) == false
    end
    local restoreNames = nil       -- the player's collapse set, top to bottom

    if ev and ev.cwit == "unreadable" then
        -- THE WITNESS-UNREADABLE WORLD: this client's info getter does not
        -- answer the expanded-state question where we can read it. Honesty
        -- fallback: expand all before every full scan and LEAVE it expanded —
        -- with no witness there is no knowing what to restore. Mild UI
        -- rudeness, recorded (collapse=blind* in the trace), never a lie.
        if expandFn then
            wWorld = "blind"
            withCollapseLatch(surface, function() expandFn(0) end)
            if windowVanished() then return refuse("window-closed", ev, guardWhy) end
            -- Measured, not assumed: only a call that MOVED the enumeration
            -- earns the second walk.
            local okN2, n2 = pcall(numFn)
            if okN2 and type(n2) == "number" and n2 ~= (ev.n or 0) then
                wWorld = "blind-grew"
                scan, why, ev = doScan()
            end
        else
            -- No witness AND no expand call: nothing this client lets us do.
            -- The pre-fix world, named out loud in the trace.
            wWorld = "blind-dark"
        end
        Professions._collapseWorld = Professions._collapseWorld or {}
        Professions._collapseWorld[surface] = wWorld
    elseif ev and ev.clp and #ev.clp > 0 then
        -- WITNESSED COLLAPSE at full-scan time: expand all, take the complete
        -- scan, restore the player's exact prior collapse set afterwards.
        Professions._collapseWorld = Professions._collapseWorld or {}
        Professions._collapseWorld[surface] = "witnessed"
        if not expandFn then
            wWorld = "collapsed-dark"
            return refuse("collapsed", ev, guardWhy)
        end
        restoreNames = {}
        for k = 1, #ev.clp do restoreNames[k] = ev.clp[k].name end
        withCollapseLatch(surface, function() expandFn(0) end)
        if windowVanished() then
            -- Mid-expand close: clean abort. Nothing was written, and there is
            -- no restore against a window that is not there.
            return refuse("window-closed", ev, guardWhy)
        end
        local scan2, why2, ev2 = doScan()
        if ev2 and ev2.clp and #ev2.clp > 0 then
            -- The expand-all convention MEASURED a no-op (or a partial) on this
            -- client. Put back whatever did move, then refuse — "collapsed" is
            -- retryable on the ladder, a shortened write never is.
            local still = {}
            for k = 1, #ev2.clp do still[ev2.clp[k].name] = true end
            local moved = {}
            for k = 1, #restoreNames do
                if not still[restoreNames[k]] then moved[#moved + 1] = restoreNames[k] end
            end
            if #moved > 0 then restoreCollapse(surface, moved) end
            wWorld = "expand-noop"
            return refuse("collapsed", ev2, guardWhy)
        end
        if ev2 and ev2.cwit == "unreadable" then
            -- The witness degraded between the two walks. Without it a restore
            -- cannot be verified against anything: blind semantics from here —
            -- leave expanded, say so.
            restoreNames = nil
            wWorld = "blind"
        else
            wWorld = "roundtrip"
        end
        if not scan2 then
            -- Expanded and still refused (cold rows, unresolved, …). Give the
            -- player their window back before the ladder takes over.
            if restoreNames then restoreCollapse(surface, restoreNames) end
            return refuse(why2, ev2, guardWhy)
        end
        scan, why, ev = scan2, why2, ev2
    end

    if not scan then return refuse(why, ev, guardWhy) end

    Professions._scanAt = now
    Professions.CancelRetry(surface)
    local traceRec = {
        e = event, s = surface, f = force and true or nil, p = scan.profKey,
        r = "ok", n = ev and ev.n, i = ev and ev.ids, u = ev and ev.missed,
        res = ev and ev.res,           -- WHICH rung carried the scan (res=…)
        w = wWorld, g = guardWhy, d = "cleared",
    }
    Professions.RecordAttempt(traceRec)

    local stamp = nowEpoch()
    Professions.ApplyScan(scan, stamp)

    -- Cooldowns fold BEFORE any restore: the fold reads by the EXPANDED scan's
    -- row indexes, and restoring first would shift them under it.
    local running, proven = Professions.FoldCooldowns(scan, stamp)
    local consumed = false
    if running and proven then
        local _, c = Professions.ApplyCooldowns(running, proven)
        consumed = c
    end

    -- The full capture is the moment the settled signature is (re)taken and
    -- the staleness mark comes off: this scan just proved the current truth.
    -- After a roundtrip the record is the scan CAPTURED AT FULL EXPANSION —
    -- that is the whole point — and the collapsed view the restore re-creates
    -- is answered by the verify's "collapsed" verdict, not by drift.
    if Professions._stale then Professions._stale[scan.profKey] = nil end
    local settledRec = Professions.BuildSettledRecord(scan)
    if settledRec then
        Professions.SettledPut(scan.profKey, settledRec)
    else
        -- A scan we could not fingerprint must not leave an OLD fingerprint
        -- standing — the next event would verify against stale evidence.
        Professions.SettledClear(scan.profKey)
    end

    -- Reagents are a GAME FACT and do not change while the window is open —
    -- or between two logins, or until the DATASET itself changes. The harvest
    -- runs once per profession per dataset stamp (store-persisted), is
    -- time-sliced across frames, and a manual rescan clears the stamp first.
    -- NOT after a roundtrip: the restore below shrinks the enumeration before
    -- the first sliced chunk runs, its row indexes would name hidden rows, and
    -- the job's own count guard would abort it anyway. The stamp stays absent
    -- and the first expanded-window session completes it instead.
    if not restoreNames
       and (event == "rescan"
            or (not Professions.HarvestStamped(scan.profKey)
                and not (Professions._harvested and Professions._harvested[scan.profKey]))) then
        Professions.ScheduleHarvest(surface, scan.profKey, scan.rows, ev and ev.n)
    end

    -- THE RESTORE: the player's window goes back exactly as they left it, per
    -- header, by name, bottom-up. Every collapse call echoes; the latch inside
    -- keeps the echoes out of the capture.
    if restoreNames then
        local restored = restoreCollapse(surface, restoreNames)
        traceRec.w = "roundtrip(" .. restored .. "/" .. #restoreNames .. ")"
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
-- MANUAL RESCAN  (perf/professions-scan)
--
-- The one deliberate override of every persistence layer this branch added:
-- the settled signature, the harvest stamp and the filter panel's measured
-- setter conventions are all dropped, and — when the window is up — a full
-- capture runs immediately with the signature bypassed. Two entry points call
-- this: the Rescan button professions_filters.lua places on the Blizzard
-- window's filter bar, and `/nexus profs rescan`. The Nexus tab UI can call
-- Professions.ForceRescan directly when it grows the affordance.
--
-- `what` may be a surface ("tradeskill"/"craft"), a profession key
-- ("blacksmithing", ...), or nil for everything this character has settled.
----------------------------------------------------------------------

local function rescanSurface(surface)
    -- Attribute the window so the right stamps are cleared even when the
    -- capture below cannot run (window closed).
    local prof
    local lineFn = (surface == "craft") and GetCraftDisplaySkillLine or GetTradeSkillLine
    if lineFn then
        local ok, lname = pcall(lineFn)
        if ok and type(lname) == "string" and lname ~= "" then
            local rec = Professions.SettledForWindow(surface, lname)
            if rec then prof = rec.prof end
            if not prof then prof = Professions.SkillNameMap()[lname:lower()] end
        end
    end
    if prof then
        Professions.SettledClear(prof)
        Professions.ClearHarvestStamp(prof)
        Professions.MarkStale(prof)
        if Professions._recipeNames then Professions._recipeNames[prof] = nil end
    else
        -- Cannot attribute: drop everything rather than guess. Honest and rare.
        Professions.SettledClear(nil)
        Professions.MarkStale(nil)
        Professions._recipeNames = nil
    end
    -- The filter probe may re-measure from scratch too.
    local F = ns.ProfessionFilters
    if F and F.ForgetConventions then pcall(F.ForgetConventions, surface) end
    if Professions.WindowIsOpen(surface) then
        Professions._scanAt = nil                      -- the rescan is never coalesced away
        return Professions.CaptureWindow(surface, true, "rescan")
    end
    return false, "window-closed"
end

function Professions.ForceRescan(what)
    if not Professions.IsEnabled() then return false, "disabled" end
    if what == "tradeskill" or what == "craft" then
        return rescanSurface(what)
    end
    if type(what) == "string" and what ~= "" then
        -- A profession key: clear its stamps; if its window is up, rescan now.
        local key = what:lower()
        Professions.SettledClear(key)
        Professions.ClearHarvestStamp(key)
        Professions.MarkStale(key)
        if Professions._recipeNames then Professions._recipeNames[key] = nil end
        local surface = (key == "enchanting") and "craft" or "tradeskill"
        local F = ns.ProfessionFilters
        if F and F.ForgetConventions then pcall(F.ForgetConventions, surface) end
        if Professions.WindowIsOpen(surface) then
            Professions._scanAt = nil
            return Professions.CaptureWindow(surface, true, "rescan")
        end
        return true, "marked"                          -- next window open runs full
    end
    -- Everything: both surfaces' stamps, every settled record.
    Professions.SettledClear(nil)
    Professions.MarkStale(nil)
    Professions._recipeNames = nil
    local stamps = Professions.HarvestStamps(false)
    if stamps then for key in pairs(stamps) do stamps[key] = nil end end
    Professions._harvested = nil
    local any = false
    for _, surface in ipairs({ "tradeskill", "craft" }) do
        local F = ns.ProfessionFilters
        if F and F.ForgetConventions then pcall(F.ForgetConventions, surface) end
        if Professions.WindowIsOpen(surface) then
            Professions._scanAt = nil
            local ok = Professions.CaptureWindow(surface, true, "rescan")
            any = any or (ok == true)
        end
    end
    return any, any and "rescanned" or "marked"
end

-- `/nexus profs rescan [tradeskill|craft|<profession>]` — the slash path.
-- Registered unconditionally (core.lua loads first, so the registry exists);
-- the handler itself gates on the module being enabled.
ns:RegisterSubcommand("profs", function(rest)
    rest = rest and rest:match("^%s*(.-)%s*$") or ""
    local sub, args = rest:match("^(%S*)%s*(.-)$")
    sub = (sub or ""):lower()
    if sub == "rescan" then
        if not Professions.IsEnabled() then
            ns:Print("the Professions module is switched off.")
            return
        end
        local target = (args or ""):lower():match("^(%S*)") or ""
        if target == "" then target = nil end
        local ok, why = Professions.ForceRescan(target)
        if ok == true then
            ns:Print("professions: full rescan captured.")
        elseif why == "marked" then
            ns:Print("professions: rescan armed — the next window open runs a full capture.")
        else
            ns:Print("professions: rescan armed (" .. tostring(why)
                .. ") — open the profession window to capture.")
        end
        return
    end
    ns:Print("usage: /nexus profs rescan [tradeskill|craft|<profession>]")
end, "professions tools (rescan)")

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
    elseif event == "CHAT_MSG_SKILL" then
        -- A skill rank-up, in localized prose we do not parse: unattributable,
        -- so every settled profession is marked. Marking is two table writes;
        -- the cost lands on the NEXT window look, as one full capture.
        Professions.MarkStale(nil)
    elseif event == "LEARNED_SPELL_IN_SKILL_LINE" then
        -- Learning a recipe (or a rank spell) — the id usually names the
        -- profession through the dataset, so the mark can be surgical. An id we
        -- do not carry marks everything: conservative, never silent.
        local spellID = ...
        local prof
        if type(spellID) == "number" and Dataset.LoadCore() then
            local r = Dataset.recipe[spellID]
            if r then prof = Dataset.ProfKey(r.p) end
            if not prof then
                local rk = Dataset.rankSpell[spellID]
                if rk then prof = Dataset.ProfKey(rk.p) end
            end
        end
        Professions.MarkStale(prof)
        -- An open window re-captures NOW rather than on its next event: the
        -- learn usually fires TRADE_SKILL_UPDATE too, but the unkind profile
        -- (rows landing with no event) has already happened once.
        for _, surface in ipairs({ "tradeskill", "craft" }) do
            if Professions.WindowIsOpen(surface) then
                Professions.CaptureWindow(surface, true, "stale-learn")
            end
        end
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        -- A craft landed. If the spell is one of our recipes and its window is
        -- up, run the (settled-cheap) capture so a consumed cooldown publishes
        -- even when the window's own update echo goes missing. One table lookup
        -- for every other player cast.
        local unit, _, spellID = ...
        if unit == "player" and type(spellID) == "number"
           and Dataset.core and Dataset.recipe then
            local r = Dataset.recipe[spellID]
            if r then
                local surface = (Dataset.ProfKey(r.p) == "enchanting") and "craft" or "tradeskill"
                if Professions.WindowIsOpen(surface) then
                    if C_Timer and C_Timer.After then
                        -- The cooldown stamp trails the cast by a beat; read it
                        -- after the client has had a frame to write it.
                        C_Timer.After(0.2, function()
                            if Professions.IsEnabled() and Professions.WindowIsOpen(surface) then
                                Professions.CaptureWindow(surface, false, "cast-landed")
                            end
                        end)
                    else
                        Professions.CaptureWindow(surface, false, "cast-landed")
                    end
                end
            end
        end
    end
end
Professions._onEvent = onEvent

----------------------------------------------------------------------
-- THE REGISTRATION SEAM (fix/phantom-event, 2026-08-10).
--
-- Every list-driven event registration in this module goes through here, and
-- nothing else in the file calls frame:RegisterEvent. Two rules, both scars:
--
--   ONCE PER FRAME. The frame carries its own ledger of what it already holds,
--   so a second pass over the same list registers NOTHING — a toggle race, a
--   self-test that re-enables, or a future caller that forgets the _activated
--   guard all cost zero calls instead of a second full round. Re-registering a
--   VALID event is silent waste; re-registering an invalid one is how one bad
--   name became 32 lines in the owner's BugSack. (The ledger, not
--   IsEventRegistered, is the source of truth: it is the one answer that is
--   identical on a live frame and on the headless harness's chainable mock.
--   The frame is dropped whole on disable, so the ledger cannot outlive the
--   registrations it describes.)
--
--   ONE COMPLAINT, AS DATA. A name the client refuses is recorded ONCE in
--   Professions._refusedEvents and printed by `/dsn debug professions`. It is
--   never re-attempted and never becomes a repeated throw.
--
-- WHY THE OLD SHAPE WAS NOT SAFE: the previous code wrote
-- `pcall(function() f:RegisterEvent(ev) end)` and a comment claiming an unknown
-- name therefore "costs nothing". The live 1.15.9 client disagreed —
-- "Attempt to register unknown event" reached the global error handler (which
-- is the only reason BugGrabber ever saw it), so pcall was never the shield it
-- was described as. pcall stays here as the belt; the braces are the harness
-- gate (nexus-test-harness/harness/eventcheck.lua), which checks every event
-- name in the shipped files against the catalog's registry so a phantom cannot
-- be typed in the first place.
--
-- Returns registered, skipped-as-already-held, refused.
function Professions.RegisterEventList(frame, list)
    if not frame or type(list) ~= "table" then return 0, 0, 0 end
    local held = frame._dsnEvents
    if not held then held = {} frame._dsnEvents = held end
    local registered, already, refused = 0, 0, 0
    for i = 1, #list do
        local ev = list[i]
        if type(ev) == "string" and ev ~= "" then
            if held[ev] == true then
                already = already + 1
            elseif held[ev] == "refused" then
                -- Known bad on THIS frame: counted, never re-attempted. This is
                -- the line that turns "32 occurrences" into "one".
                refused = refused + 1
            else
                local ok
                if ev == "UNIT_SPELLCAST_SUCCEEDED" and frame.RegisterUnitEvent then
                    -- Unit-filtered where the client offers it: the handler only
                    -- ever cares about the player, and the raid's casts are noise.
                    ok = pcall(frame.RegisterUnitEvent, frame, ev, "player")
                    if not ok then ok = pcall(frame.RegisterEvent, frame, ev) end
                else
                    ok = pcall(frame.RegisterEvent, frame, ev)
                end
                if ok then
                    held[ev] = true
                    registered = registered + 1
                else
                    held[ev] = "refused"
                    refused = refused + 1
                    -- Once. The debug command is where this is read; a
                    -- registration the client refused is a build-time fact, not
                    -- something to shout at the player about.
                    local seen = Professions._refusedEvents
                    if not seen then seen = {} Professions._refusedEvents = seen end
                    seen[ev] = (seen[ev] or 0) + 1
                end
            end
        end
    end
    return registered, already, refused
end

function Professions.Activate()
    if Professions._activated then return true end
    if not Professions.IsEnabled() then return false end
    Professions._activated = true

    if not Professions._frame and CreateFrame then
        local f = CreateFrame("Frame")
        f:SetScript("OnEvent", onEvent)
        Professions.RegisterEventList(f, Professions.EVENTS)
        Professions._frame = f
    end

    Dataset.LoadCore()
    -- Translate every stored record written under another dataset build before
    -- anything reads or seeds from them (feat/dataset-migration). Lazy read
    -- seams would cope anyway; the sweep persists the translation so the store
    -- converges once per bump instead of re-deriving per read.
    Professions.MigrateStoredOwners()
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
        -- The settled mirrors and the in-flight harvest are session state of a
        -- module that is no longer running. The STORE copies stay (retained but
        -- stale, like every other stored answer) — they are re-validated
        -- component by component against the live window before ever being
        -- honored again.
        Professions._settled, Professions._stale = nil, nil
        Professions._harvestJob = nil
        Professions._collapseLatch, Professions._collapseWorld = nil, nil
        Professions._collapseDepth, Professions._collapseRefused = nil, nil
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
        .. ", frame " .. (P._frame and "up" or "none")
        .. ", events " .. tostring(#P.EVENTS))
    -- The registration seam's only voice. Empty on a healthy client, and empty
    -- is what the harness gate (eventcheck.lua) is there to keep it.
    if P._refusedEvents then
        local refused = {}
        for ev, n in pairs(P._refusedEvents) do
            refused[#refused + 1] = ev .. " x" .. tostring(n)
        end
        table.sort(refused)
        if #refused > 0 then
            ns:Print("  |cffff5555this client refused|r: " .. table.concat(refused, ", ")
                .. " (attempted once per frame, never retried on one)")
        end
    end
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

    -- The settled-signature layer: which professions can skip, which are
    -- marked stale, and where the harvest stamps stand.
    do
        local parts = {}
        local mine = P.SettledArea and P.SettledArea(false)
        for key in pairs(mine or {}) do
            local rec = P.SettledGet(key)
            parts[#parts + 1] = key
                .. (rec and ("(" .. tostring(rec.n) .. " rows)") or "(invalid)")
                .. (P.IsStale(key) and " STALE" or "")
        end
        table.sort(parts)
        ns:Print("  settled: " .. ((#parts > 0) and table.concat(parts, ", ") or "none"))
        local stamps = P.HarvestStamps and P.HarvestStamps(false)
        local sp = {}
        for key, rec in pairs(stamps or {}) do
            sp[#sp + 1] = key .. "@" .. tostring(rec.ds)
        end
        table.sort(sp)
        ns:Print("  harvest stamps: " .. ((#sp > 0) and table.concat(sp, ", ") or "none")
            .. (P._harvestJob and (" | harvest IN FLIGHT for " .. tostring(P._harvestJob.prof)) or ""))
    end

    -- Windows and ladders: the two pieces of state that decide whether another
    -- attempt is coming at all. The collapse world names which client we are
    -- on: "witnessed" (headers report their state, expand/restore roundtrips
    -- work), "blind*" (state unreadable — every full scan expands and leaves
    -- it that way), or unprobed (no full scan has met a header yet).
    for _, surface in ipairs({ "tradeskill", "craft" }) do
        local st = P.Stats("surface:" .. surface)
        local world = P._collapseWorld and P._collapseWorld[surface]
        ns:Print(string.format("  %s window: open=%s | ladder %s | collapse world %s%s", surface,
            tostring(P.WindowIsOpen(surface)), P.RetryState(surface),
            tostring(world or "unprobed"),
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

    -- FIX-4: the spec PARENT edges — exactly the three Master smith specs
    -- parent to Weaponsmith (matched by NAME, the fix's own rule), everything
    -- else is a root. The whole delegate lane walk rests on these three edges.
    do
        local byName = {}
        for i = 1, #Dataset.specs do byName[Dataset.specs[i].name] = Dataset.specs[i] end
        local weapon = byName["Weaponsmith"]
        ck(weapon ~= nil, "FIX-4: the Weaponsmith spec vanished from the dataset")
        local parented = 0
        for i = 1, #Dataset.specs do
            local sp = Dataset.specs[i]
            if sp.name == "Master Swordsmith" or sp.name == "Master Hammersmith"
               or sp.name == "Master Axesmith" then
                parented = parented + 1
                ck(sp.parent ~= nil and Dataset.specs[sp.parent] == weapon,
                   "FIX-4: " .. sp.name .. " does not parent to Weaponsmith")
                ck(Dataset.SpecParentID(sp.id) == weapon.id,
                   "FIX-4: SpecParentID does not answer Weaponsmith for " .. sp.name)
            else
                ck(sp.parent == nil, "FIX-4: " .. sp.name .. " grew an unexpected parent")
                ck(Dataset.SpecParentID(sp.id) == nil,
                   "FIX-4: SpecParentID invented a parent for " .. sp.name)
            end
        end
        ck(parented == 3, "FIX-4: expected 3 Master smith specs, found " .. parented)
    end

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
    local savedPerf = {
        Professions._settled, Professions._stale, Professions._harvested,
        Professions._harvestJob, Professions._scanAt,
    }
    local savedArea = ns.Store and ns.Store.data and ns.Store.data.professions

    local ok, err = pcall(function()
        Dataset.LoadCore()
        _G.GetTime = function() return 10000 end
        Professions._leavingWorld, Professions._loggingOut = false, false
        Professions._enteredWorldAt = 0            -- long since warm
        Professions._live = nil
        Professions._settled, Professions._stale = nil, nil
        Professions._harvested, Professions._harvestJob = nil, nil

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

        -- (1b) A crafting spree coalesces, but never by going deaf: the first
        --      window event lands the full scan, and every event after it on
        --      the unchanged window is answered by the cheap SETTLED verify —
        --      a distinct verdict, never a re-scan and never a dropped event.
        Professions._scanAt = nil
        local okFirst = Professions.CaptureWindow("tradeskill", true)
        ck(okFirst == true, "the window-open scan did not land")
        local aStamp = Professions._live.p.blacksmithing.a
        local okSecond, profSecond = Professions.CaptureWindow("tradeskill")
        ck(okSecond == true and profSecond == "blacksmithing",
           "an update on the unchanged window was not answered (" .. tostring(profSecond) .. ")")
        local ring = Professions.TraceRows()
        ck(ring[#ring] and ring[#ring].r == "settled",
           "the unchanged-window answer was not the settled verdict ("
           .. tostring(ring[#ring] and ring[#ring].r) .. ")")
        ck(Professions._live.p.blacksmithing.a == aStamp,
           "a settled skip re-stamped the scan epoch — it must not masquerade as a full scan")
        ck(Professions.CaptureWindow("tradeskill", true) == true,
           "a forced re-open of the unchanged window was refused")
        -- The throttle still guards the UNSETTLED path: drop the record and the
        -- live bitmap gate and an update inside the second coalesces as before.
        Professions._settled = nil
        local mineSA = Professions.SettledArea and Professions.SettledArea(false)
        if mineSA then mineSA.blacksmithing = nil end
        Professions._live.p.blacksmithing.k = nil       -- no truth to skip over
        Professions._scanAt = 10000                     -- a scan "just" happened
        local okThrottled, whyT = Professions.CaptureWindow("tradeskill")
        ck(okThrottled == false and whyT == "throttled",
           "an unsettled update inside the throttle window re-scanned instead of coalescing")
        Professions._scanAt = nil
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
    Professions._settled, Professions._stale = savedPerf[1], savedPerf[2]
    Professions._harvested, Professions._harvestJob = savedPerf[3], savedPerf[4]
    Professions._scanAt = savedPerf[5]
    if ns.Store and ns.Store.data then ns.Store.data.professions = savedArea end

    if not ok then fails[#fails + 1] = "error in capture-honesty fixtures: " .. tostring(err) end
end

----------------------------------------------------------------------
-- PANEL-WITNESSED PRESENCE (the Orn defect, 2026-08)
--
-- The live bug: Orn holds Herbalism 300 + Alchemy, and the module reported
-- only Alchemy. Herbalism's rank-tier entries are not book-known spells —
-- IsSpellKnown answers false for all four — so the spell-only probe never
-- created the profession, and ApplySkillLines (which only writes onto
-- professions that exist) silenced the level too. Mining shares the build
-- (book spell Smelting, tiers on the Mining rank line) and is pinned here.
----------------------------------------------------------------------

local function testPanelPresence(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    local saved = {
        known = _G.IsSpellKnown, numSkill = _G.GetNumSkillLines,
        skillInfo = _G.GetSkillLineInfo, spellInfo = _G.GetSpellInfo,
        getTime = _G.GetTime,
    }
    local savedLatch = {
        Professions._leavingWorld, Professions._loggingOut,
        Professions._enteredWorldAt, Professions._live, Professions._lastSig,
        Professions._staticAt, Professions._nameMap,
    }

    local ok, err = pcall(function()
        Dataset.LoadCore()
        _G.GetTime = function() return 10000 end
        Professions._leavingWorld, Professions._loggingOut = false, false
        Professions._enteredWorldAt = 0
        Professions._live, Professions._staticAt = nil, nil
        Professions._nameMap = nil
        _G.GetSpellInfo = function() return nil end     -- English-fallback map

        local hIdx = Dataset.profIdx.herbalism
        local mIdx = Dataset.profIdx.mining
        local aIdx = Dataset.profIdx.alchemy
        local hName = Dataset.profs[hIdx].name
        local mName = Dataset.profs[mIdx].name
        local aName = Dataset.profs[aIdx].name

        local knownSpells = {}
        _G.IsSpellKnown = function(id) return knownSpells[id] == true end

        local function setPanel(rows)
            _G.GetNumSkillLines = function() return #rows end
            _G.GetSkillLineInfo = function(i)
                local r = rows[i]
                if not r or r.dead then return nil end
                if r.header then return r.name, true, true, 0, 0, 0, 0 end
                return r.name, false, true, r.rank, 0, 0, r.max
            end
        end

        -- The OLD probe, written out as the legacy control: presence solely
        -- from IsSpellKnown over the rank-tier spells. This is the shipped
        -- 1.1.x behavior that made Orn's herbalism invisible.
        local function legacyProbe()
            local out = {}
            for idx, prof in pairs(Dataset.profs) do
                local tiers = Dataset.ranks[idx]
                if tiers then
                    local best
                    for tier = 1, 4 do
                        local t = tiers[tier]
                        if t and _G.IsSpellKnown(t.spell) then best = tier end
                    end
                    if best then out[prof.key] = { t = best, s = {} } end
                end
            end
            return out
        end

        -- (1) RED CONTROL. A gathering-only character: herbalism 300 on the
        --     panel, zero book-known tier spells. Legacy: invisible. New:
        --     present, tier 4, and the LEVEL flows in through the full
        --     CaptureStatic path.
        knownSpells = {}
        setPanel({
            { name = "Class Skills", header = true },
            { name = hName, rank = 300, max = 300 },
            { name = "Riding", rank = 75, max = 75 },
        })
        local legacy = legacyProbe()
        local nLegacy = 0
        for _ in pairs(legacy) do nLegacy = nLegacy + 1 end
        ck(nLegacy == 0,
           "RED: the legacy spell-only probe saw a gathering-only character (fixture broken)")
        local probe, sound = Professions.ProbeProfessions()
        ck(probe and probe.herbalism and probe.herbalism.t == 4,
           "a panel-witnessed herbalism 300 did not probe as present at tier 4")
        ck(sound == true, "a fully-read panel did not report itself sound")
        Professions._live = nil
        ck(Professions.CaptureStatic(true) == true, "the static capture refused the fixture")
        local rec = Professions.Live().p.herbalism
        ck(rec and rec.l == 300 and rec.m == 300 and rec.t == 4,
           "herbalism's level did not flow through CaptureStatic ("
           .. tostring(rec and rec.l) .. "/" .. tostring(rec and rec.m) .. ")")
        local payload = Professions.BuildPayload()
        ck(payload and payload.p.herbalism and payload.p.herbalism.k == nil
           and payload.p.herbalism.a == nil,
           "a panel-witnessed profession invented a known-set")
        local st, lvl = Professions.KnownState(payload, "herbalism", 999)
        ck(st == "unknown" and lvl == 300,
           "a panel-witnessed never-scanned profession did not read unknown-with-level")

        -- (2) ORN'S EXACT SHAPE: alchemy book-known (tiers 1-2 only, so the
        --     spell answer is DISTINGUISHABLE from the panel's ceiling), plus
        --     panel-only herbalism. Both present; alchemy's tier from spells,
        --     never overridden by the panel's implied tier 4.
        knownSpells = {}
        knownSpells[Dataset.ranks[aIdx][1].spell] = true
        knownSpells[Dataset.ranks[aIdx][2].spell] = true
        setPanel({
            { name = "Class Skills", header = true },
            { name = aName, rank = 280, max = 300 },      -- panel would say tier 4
            { name = hName, rank = 300, max = 300 },
        })
        probe = Professions.ProbeProfessions()
        ck(probe and probe.alchemy and probe.alchemy.t == 2,
           "the panel overrode the spell probe's alchemy tier ("
           .. tostring(probe and probe.alchemy and probe.alchemy.t) .. ")")
        ck(probe and probe.herbalism and probe.herbalism.t == 4,
           "Orn's herbalism was missed beside a spell-probed alchemy")

        -- (3) UNEXPECTED CEILING (the §4.7 defect, inverted). A ceiling the
        --     strict map does not know still marks the profession PRESENT,
        --     with the floor tier the rank value proves — never apprentice.
        knownSpells = {}
        setPanel({ { name = hName, rank = 80, max = 90 } })
        probe = Professions.ProbeProfessions()
        ck(probe and probe.herbalism and probe.herbalism.t == 2,
           "an unexpected ceiling did not degrade to the rank-proven floor tier ("
           .. tostring(probe and probe.herbalism and probe.herbalism.t) .. ")")
        setPanel({ { name = hName, rank = 280, max = 290 } })
        probe = Professions.ProbeProfessions()
        ck(probe and probe.herbalism and probe.herbalism.t == 4,
           "rank 280 under a weird ceiling did not prove at least tier 4")
        ck(Professions.TierFloorFromRank(hIdx, 400) == 4,
           "a rank past every ceiling did not clamp to the top tier")

        -- (4) CLASS 6. An unwitnessed panel adds nothing and erases nothing.
        setPanel({})                                     -- zero rows: unwitnessed
        ck(Professions.ProbeProfessions() == nil,
           "a zero-row panel did not refuse the whole probe (witness gate)")
        -- Panel present but every row unreadable: the probe still answers from
        -- spells, but the panel is unsound — so ApplyProbe may not erase.
        _G.GetNumSkillLines = function() return 3 end
        _G.GetSkillLineInfo = function() return nil end
        ck(Professions.ProbePanelPresence() == nil,
           "a panel whose every row was unreadable was witnessed anyway")
        knownSpells = {}
        for tier = 1, 4 do knownSpells[Dataset.ranks[aIdx][tier].spell] = true end
        local probe2, sound2 = Professions.ProbeProfessions()
        ck(probe2 and probe2.alchemy and sound2 == false,
           "the spell probe did not answer past a dead panel")
        Professions._live = nil
        local L = Professions.Live()
        L.p.herbalism = { t = 4, l = 300, m = 300 }      -- last session's truth
        Professions.ApplyProbe(probe2, sound2)
        ck(L.p.herbalism ~= nil,
           "an UNSOUND panel erased a panel-only profession (class 6: nil reads never erase)")
        ck(L.p.alchemy ~= nil, "the spell-probed profession did not merge past a dead panel")
        -- ...and a SOUND panel that lacks the row IS proof: the unlearn drop.
        setPanel({ { name = aName, rank = 300, max = 300 } })
        local probe3, sound3 = Professions.ProbeProfessions()
        ck(sound3 == true, "a readable panel did not report sound")
        Professions.ApplyProbe(probe3, sound3)
        ck(L.p.herbalism == nil,
           "a sound panel plus silent spells did not drop an unlearned profession")

        -- (5) LOCALIZED NAMES. The panel speaks the client's language; the map
        --     is built from the client's own GetSpellInfo answers, so a
        --     non-English row resolves without one shipped string.
        Professions._nameMap = nil
        local hTierSpells = {}
        for tier = 1, 4 do hTierSpells[Dataset.ranks[hIdx][tier].spell] = true end
        _G.GetSpellInfo = function(id)
            if hTierSpells[id] then return "Kr\195\164uterkunde" end
            return nil
        end
        knownSpells = {}
        setPanel({ { name = "Kr\195\164uterkunde", rank = 150, max = 150 } })
        probe = Professions.ProbeProfessions()
        ck(probe and probe.herbalism and probe.herbalism.t == 2,
           "a localized panel row did not resolve through the client's own spell name")
        Professions._nameMap = nil
        _G.GetSpellInfo = function() return nil end

        -- (6) MINING, pinned. Its book spell is Smelting — which is NOT one of
        --     the dataset's mining rank tiers — so even a character whose book
        --     answers for Smelting is invisible to the legacy probe and needs
        --     the panel witness, exactly like herbalism.
        local SMELTING = 2656
        for tier = 1, 4 do
            ck(Dataset.ranks[mIdx][tier].spell ~= SMELTING,
               "fixture premise broken: a mining rank tier IS the Smelting spell")
        end
        knownSpells = { [SMELTING] = true }
        setPanel({ { name = mName, rank = 150, max = 150 } })
        legacy = legacyProbe()
        ck(legacy.mining == nil,
           "RED: the legacy probe saw mining without its tier spells (fixture broken)")
        probe = Professions.ProbeProfessions()
        ck(probe and probe.mining and probe.mining.t == 2,
           "a panel-witnessed mining 150 did not probe as present at tier 2")

        -- (6b) A panel-witnessed profession still hangs its SPECIALISATIONS off
        --      the spell probe — spec spells ARE book-known even when the tier
        --      spells are not.
        local lwIdx = Dataset.profIdx.leatherworking
        local lwSpec
        for i = 1, #Dataset.specs do
            if Dataset.specs[i].p == lwIdx then lwSpec = Dataset.specs[i].id break end
        end
        if lwSpec then
            knownSpells = { [lwSpec] = true }
            setPanel({ { name = Dataset.profs[lwIdx].name, rank = 250, max = 300 } })
            probe = Professions.ProbeProfessions()
            ck(probe and probe.leatherworking and probe.leatherworking.s
               and probe.leatherworking.s[1] == lwSpec,
               "a panel-witnessed profession did not pick up its book-known specialisation")
        end

        -- (7) WIRE ROUND-TRIP. A panel-witnessed profession rides the payload
        --     in the frozen shape — every field one an old reader already
        --     knows, t always 1..4 — and survives the mesh packer intact.
        knownSpells = {}
        for tier = 1, 4 do knownSpells[Dataset.ranks[aIdx][tier].spell] = true end
        setPanel({
            { name = aName, rank = 300, max = 300 },
            { name = hName, rank = 300, max = 300 },
        })
        Professions._live = nil
        ck(Professions.CaptureStatic(true) == true, "the round-trip fixture refused capture")
        payload = Professions.BuildPayload()
        ck(payload and payload.p.herbalism and payload.p.alchemy,
           "the round-trip payload lost a profession")
        local FROZEN = { l = true, m = true, t = true, s = true, k = true,
                         n = true, u = true, a = true }
        for k in pairs(payload.p.herbalism) do
            ck(FROZEN[k], "a panel-witnessed profession grew a field old readers"
               .. " have never seen: " .. tostring(k))
        end
        ck(payload.p.herbalism.t == 4 and payload.p.herbalism.l == 300,
           "the panel-witnessed record did not carry tier and level onto the wire")
        if ns.Mesh and ns.Mesh.Pack and ns.Mesh.Unpack then
            local packed = ns.Mesh.Pack(payload)
            ck(packed ~= nil, "the mesh packer refused a panel-witnessed payload")
            local back = packed and ns.Mesh.Unpack(packed)
            ck(type(back) == "table" and back.p and back.p.herbalism
               and back.p.herbalism.t == 4 and back.p.herbalism.l == 300
               and back.p.herbalism.k == nil,
               "a panel-witnessed profession did not survive the mesh round-trip")
            if type(back) == "table" then
                local stBack, lvlBack = Professions.KnownState(back, "herbalism", 999)
                ck(stBack == "unknown" and lvlBack == 300,
                   "the decoded payload did not read as unknown-with-level")
            end
        end
        -- The delta detector sees a panel-witnessed profession appear.
        local without = { v = 1, ds = payload.ds, ts = payload.ts,
                          p = { alchemy = payload.p.alchemy }, c = payload.c }
        ck(Professions.PayloadSignature(without) ~= Professions.PayloadSignature(payload),
           "gaining a panel-witnessed profession did not change the publish signature")
    end)

    _G.IsSpellKnown, _G.GetNumSkillLines = saved.known, saved.numSkill
    _G.GetSkillLineInfo, _G.GetSpellInfo = saved.skillInfo, saved.spellInfo
    _G.GetTime = saved.getTime
    Professions._leavingWorld, Professions._loggingOut = savedLatch[1], savedLatch[2]
    Professions._enteredWorldAt, Professions._live = savedLatch[3], savedLatch[4]
    Professions._lastSig, Professions._staticAt = savedLatch[5], savedLatch[6]
    Professions._nameMap = savedLatch[7]

    if not ok then fails[#fails + 1] = "error in panel-presence fixtures: " .. tostring(err) end
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

    local out, outComplete = Professions.HarvestReagents(scan, api)
    ck(out and out[bsList[1]], "a warm harvest produced nothing")
    ck(outComplete == true, "a fully-warm harvest did not report itself complete")
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
    local partial, partComplete = Professions.HarvestReagents(scan, api)
    ck(partial and partial[bsList[1]] == nil,
       "a recipe with one unresolved reagent was harvested anyway")
    ck(partial and partial[bsList[2]] ~= nil,
       "the cold row poisoned a sibling recipe that resolved fine")
    ck(partComplete == false,
       "a harvest that skipped a cold recipe still reported itself complete — "
       .. "the persistence stamp would freeze the hole in")
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
--
-- `dispatch` is HOW the client delivers a setter's echo, and "sync" is the
-- DEFAULT because it is what interface 11509 actually does (CLIENT_ASYNC_LESSONS
-- class 9, fix/filter-reentry):
--
--   "sync"   the update is dispatched INSIDE the setter call. Every handler in
--            the session runs to completion before the setter returns, so a
--            handler that touches the client re-enters the call that woke it.
--            This is the posture that took the owner's client down with a C
--            stack overflow while every headless suite stayed green.
--   "async"  the update arrives on a later frame, after the setter returned.
--            Retained as a VARIANT — some events really do land this way, and a
--            fix that only works when the stack is already unwound is not a fix.
--
-- Async needs a timer service; without one the sim falls back to sync rather
-- than silently dropping the echo, because a dropped echo is a kinder client
-- than any that exists.
local function newWindowSim(rows, landedAt, profile, dispatch)
    local W = {
        rows = rows, landedAt = landedAt, profile = profile or "echo",
        dispatch = dispatch or "sync",
        events = {}, echoes = 0, filters = { text = "", makeable = false, skillUps = false },
    }
    local saved = {}
    local G = _G

    local function landed() return (G.GetTime() + 1e-9) >= W.landedAt end

    -- Emit an event to BOTH modules in registration order — professions.lua
    -- creates its frame first, then hands off to professions_filters.lua, so
    -- that is the order the client would use. `W.onEcho`, when a fixture sets
    -- it, takes delivery instead: that is how a RED CONTROL replays a pre-fix
    -- handler against this same client.
    local function deliver(event)
        W.events[#W.events + 1] = { t = G.GetTime(), e = event }
        if W.onEcho then W.onEcho(event) return end
        if Professions._onEvent then Professions._onEvent(nil, event) end
        local F = ns.ProfessionFilters
        if F and F._onEvent then F._onEvent(nil, event) end
    end
    function W.emit(event) deliver(event) end

    -- The client's own echo: any filter setter rebuilds the list and tells the
    -- UI about it. This is what turns one clear into four capture attempts —
    -- and, in the sync posture, four RE-ENTRANT ones.
    local function echo()
        W.echoes = W.echoes + 1
        if W.dispatch == "async" and G.C_Timer and G.C_Timer.After then
            G.C_Timer.After(0, function() deliver("TRADE_SKILL_UPDATE") end)
        else
            deliver("TRADE_SKILL_UPDATE")
        end
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
            setUps = G.TradeSkillOnlyShowSkillUps, getUps = G.GetOnlyShowSkillUps,
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
        -- THE FIRST NATIVE CALL OF THE CLEAR SEQUENCE, and the frame the live
        -- 1.1.8 stack overflowed through (professions_filters.lua:803). Its
        -- absence from this fixture is precisely why the composed chain went on
        -- passing while the owner's window would not open: with no skill-ups
        -- setter to call, the sequence's first echo happened one call later,
        -- with the latch already up.
        G.TradeSkillOnlyShowSkillUps = function(v)
            W.filters.skillUps = v and true or false; echo()
        end
        G.GetOnlyShowSkillUps = function() return W.filters.skillUps end
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
        G.TradeSkillOnlyShowSkillUps, G.GetOnlyShowSkillUps = saved.setUps, saved.getUps
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
    local savedPerf = { Professions._settled, Professions._stale, Professions._harvestJob }
    local savedFilters = F and { F._state, F._prof, F._panels, F._hooked, F._activated }
    local savedGuards = Professions._viewGuards
    local savedStore = ns.Store and ns.Store.data and ns.Store.data.professions

    -- One run of the whole chain. `dispatch` selects the client's echo posture
    -- ("sync" — the live 11509 default — or "async"). Returns a report the rows
    -- below assert on, including the RE-ENTRANCY census: how deep the filter
    -- clear ever nested, how many of its own echoes the module swallowed, and
    -- whether the depth fuse ever had to fire.
    local function runChain(profile, dispatch)
        local clock = newClock(1000)
        local sim = newWindowSim(fixtureRows(), 1000.30, profile, dispatch)
        local opportunities = {}
        local realCapture = Professions.CaptureWindow
        local realClear = F and F.ClearNative
        local census = { calls = 0, depth = 0, deepest = 0 }

        clock:install()
        sim:install()
        if F then
            F.ClearNative = function(surface, g)
                census.calls = census.calls + 1
                census.depth = census.depth + 1
                if census.depth > census.deepest then census.deepest = census.depth end
                local a, b = realClear(surface, g)
                census.depth = census.depth - 1
                return a, b
            end
        end
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
        Professions._settled, Professions._stale, Professions._harvestJob = nil, nil, nil
        Professions._viewGuards = nil
        if F then
            F._state, F._prof, F._panels, F._hooked = nil, nil, nil, nil
            F._native, F._probing, F._reentries, F._echoes = nil, nil, nil, nil
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
            dispatch = sim.dispatch,
            clears = census.calls,
            deepestClear = census.deepest,
            swallowed = (F and F._echoes and F._echoes["tradeskill"]) or 0,
            fused = (F and F._reentries and F._reentries["tradeskill"]) or 0,
            err = (not ok) and err or nil,
        }

        Professions.CaptureWindow = realCapture
        if F and realClear then F.ClearNative = realClear end
        sim:restore()
        clock:restore()
        return report
    end

    local ok, err = pcall(function()
        -- ══ (1) THE ECHO PROFILE — the live shape, exactly ═══════════════════
        -- Run under the SYNCHRONOUS posture, which is now the default: the
        -- client dispatches each setter's update inside the setter call.
        local echoRun = runChain("echo", "sync")
        ck(echoRun.err == nil, "the echo chain errored: " .. tostring(echoRun.err))
        ck(echoRun.dispatch == "sync",
           "the composed chain no longer defaults to synchronous dispatch — the "
           .. "kinder posture must never be the one the suite runs by default")
        ck(echoRun.echoes > 0,
           "the sim never echoed a single filter clear back as an update; the fixture "
           .. "is kinder than the client and proves nothing")
        ck(echoRun.swallowed > 0,
           "not one of those echoes reached the filter module's handlers; under "
           .. "synchronous dispatch they land INSIDE the setter call and the latch "
           .. "is the only thing refusing them")

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

        -- ...and it did all of that WITHOUT re-entering its own clear once
        -- (fix/filter-reentry). This is the live defect's green row.
        ck(echoRun.deepestClear == 1,
           "the filter clear re-entered itself " .. tostring(echoRun.deepestClear)
           .. " deep under synchronous dispatch — that is the 1.1.8 cycle, and on "
           .. "the owner's client it ran to a C stack overflow")
        ck(echoRun.fused == 0,
           "the depth fuse had to refuse " .. tostring(echoRun.fused) .. " sequence(s); "
           .. "the fuse is belt-and-braces and a fuse that fires means the latch above "
           .. "it did not hold")

        -- ══ (1b) THE ASYNC VARIANT — the same chain, the kinder posture ══════
        -- Retained, never default: some events really do arrive a frame later,
        -- and a latch that only holds because the stack is already unwound is
        -- not a latch. Every property above must survive the change of posture.
        local asyncRun = runChain("echo", "async")
        ck(asyncRun.err == nil, "the async chain errored: " .. tostring(asyncRun.err))
        ck(asyncRun.captured == true,
           "the composed chain did not capture under asynchronous dispatch")
        ck(asyncRun.known == 4,
           "the async chain captured " .. tostring(asyncRun.known) .. " recipes, expected 4")
        ck(asyncRun.deepestClear == 1,
           "the filter clear nested " .. tostring(asyncRun.deepestClear)
           .. " deep under asynchronous dispatch")
        ck(asyncRun.fused == 0, "the depth fuse fired under asynchronous dispatch")

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
        local silentRun = runChain("silent", "sync")
        ck(silentRun.err == nil, "the silent chain errored: " .. tostring(silentRun.err))
        ck(silentRun.deepestClear == 1,
           "the silent chain re-entered its own clear " .. tostring(silentRun.deepestClear)
           .. " deep")
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
        local silentAsync = runChain("silent", "async")
        ck(silentAsync.captured == true,
           "the silent chain did not capture under asynchronous dispatch")
        ck(silentAsync.deepestClear == 1,
           "the async silent chain re-entered its own clear")

        -- ══ (3) THE LADDER IS BOUNDED AND DIES WITH THE WINDOW ═══════════════
        do
            local clock = newClock(2000)
            local sim = newWindowSim(fixtureRows(), 1e9, "silent")   -- rows never arrive
            clock:install()
            sim:install()
            Professions._live, Professions._scanAt = nil, nil
            Professions._windowOpen, Professions._retry = nil, nil
            Professions._stats, Professions._trace = nil, nil
            Professions._settled, Professions._stale = nil, nil
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
            Professions._settled, Professions._stale = nil, nil
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

        -- ══ (5) SYNCHRONOUS IN-CALL DISPATCH: THE RE-ENTRY CYCLE ═════════════
        --     (fix/filter-reentry — CLIENT_ASYNC_LESSONS class 9)
        --
        -- The live 1.1.8 defect, in one leg. The owner's BugSack caught a C
        -- stack overflow 65 frames deep every time a profession window opened
        -- on Shalk, and the stack named the cycle exactly:
        --
        --   professions_filters.lua:803 ClearNative      (the skill-ups clear)
        --     -> [C] the client dispatches TRADE_SKILL_UPDATE INSIDE the call
        --       -> :1253 onEvent -> :1194 Settle -> :1210 ClearNative -> :803 ...
        --
        -- The latch existed. It was armed at ApplyNative, ONE CLIENT CALL LATE,
        -- and the setter that dispatched the update ran before it.
        do
            local clock = newClock(4000)
            local sim = newWindowSim(fixtureRows(), 4000, "echo", "sync")
            clock:install()
            sim:install()

            -- RED CONTROL: 1.1.8's clear sequence, written out. `redLatched` is
            -- the probing latch and it is armed exactly where 1.1.8 armed it —
            -- after the first native call, not before it. The recursion is
            -- BOUNDED here (a real client bounds it with its C stack); the
            -- assertion is that the cycle exists at all.
            local RED_CAP = 8
            local red = { entries = 0, depth = 0, deepest = 0, cycled = false }
            local redLatched = false
            local redClear
            local function redOnUpdate()          -- 1.1.8 onEvent -> OnWindowUpdate -> Settle
                if redLatched then return end     -- the check that was looking the wrong way
                redClear()
            end
            redClear = function()
                red.entries = red.entries + 1
                red.depth = red.depth + 1
                if red.depth > red.deepest then red.deepest = red.depth end
                if red.depth >= RED_CAP then
                    red.cycled = true             -- stand-in for the client's overflow
                    red.depth = red.depth - 1
                    return
                end
                -- professions_filters.lua:803 as it shipped: naked.
                if _G.TradeSkillOnlyShowSkillUps then
                    pcall(_G.TradeSkillOnlyShowSkillUps, false)
                end
                redLatched = true                 -- ...and the latch, one call too late
                pcall(_G.SetTradeSkillItemNameFilter, "")
                redLatched = false
                red.depth = red.depth - 1
            end

            sim.onEcho = redOnUpdate              -- the fixture delivers to the pre-fix handler
            redClear()
            sim.onEcho = nil

            ck(red.cycled == true,
               "RED CONTROL DID NOT REPRODUCE: the 1.1.8 clear sequence did not "
               .. "re-enter itself under synchronous dispatch, so this fixture is "
               .. "not modelling the defect that took the owner's window down")
            ck(red.deepest >= 3,
               "the red control only reached depth " .. tostring(red.deepest)
               .. "; the live stack repeated the cycle to exhaustion")
            ck(red.entries >= 3, "the red control re-entered the clear only "
               .. tostring(red.entries) .. " time(s)")

            -- GREEN: the SHIPPED code, same client, same synchronous dispatch,
            -- the whole window-open sequence — open, clear, probe, scan, settle.
            local realClear = F.ClearNative
            local g = { calls = 0, depth = 0, deepest = 0 }
            F.ClearNative = function(surface, gg)
                g.calls = g.calls + 1
                g.depth = g.depth + 1
                if g.depth > g.deepest then g.deepest = g.depth end
                local a, b = realClear(surface, gg)
                g.depth = g.depth - 1
                return a, b
            end
            Professions._live, Professions._scanAt = nil, nil
            Professions._windowOpen, Professions._retry = nil, nil
            Professions._stats, Professions._trace = nil, nil
            Professions._settled, Professions._stale = nil, nil
            Professions._harvested, Professions._harvestJob = nil, nil
            Professions._viewGuards = nil
            F._state, F._prof, F._panels, F._hooked = nil, nil, nil, nil
            F._native, F._probing, F._reentries, F._echoes = nil, nil, nil, nil
            F._conv, F._activated = nil, false
            F.Activate()

            local okGreen = pcall(function()
                sim.emit("TRADE_SKILL_SHOW")      -- rows already landed at t=4000
                clock:pump(4000 + 3)
            end)
            F.ClearNative = realClear

            ck(okGreen, "the green window-open sequence errored under synchronous dispatch")
            ck(g.calls > 0, "the window open never cleared the client's filters at all")
            ck(g.deepest == 1,
               "ClearNative re-entered itself to depth " .. tostring(g.deepest)
               .. " under synchronous dispatch — the latch is armed too late again")
            ck((F._echoes and F._echoes["tradeskill"] or 0) > 0,
               "no echo was refused, so this leg proved nothing: the client's own "
               .. "updates must reach our handlers mid-sequence for the latch to matter")
            ck((F._reentries and F._reentries["tradeskill"] or 0) == 0,
               "the depth fuse fired during an ordinary window open")

            -- ...and everything the sequence exists to do still happened.
            local grec = Professions._live and Professions._live.p
                         and Professions._live.p.blacksmithing
            ck(grec and grec.n == 4,
               "the re-entrancy-safe open captured " .. tostring(grec and grec.n)
               .. " recipes, expected 4 — a latch that also stops the work is not a fix")
            ck(F.Conv("tradeskill").settled == true,
               "the convention probe never settled: the latch swallowed the "
               .. "measurement along with the echoes")
            ck(_G.GetOnlyShowSkillUps() == false,
               "the skill-ups leftover was never cleared — that call is the one the "
               .. "latch now has to cover, and covering it must not mean skipping it")

            -- The filters still FILTER after all that: the latch is a re-entrancy
            -- gate, not an off switch.
            F._state = { tradeskill = F.NewState() }
            F.SetState("tradeskill", function(st) st.text = "arcanite" end)
            ck(_G.GetTradeSkillItemNameFilter() == "arcanite",
               "the search filter no longer reaches the client")
            F.ClearNative("tradeskill")
            ck(_G.GetTradeSkillItemNameFilter() == "",
               "the clear no longer reaches the client")
            F._state = nil
            sim:restore()
            clock:restore()
        end

        -- ══ (6) THE PEER LATCH: OUR EXPAND IS OUR ECHO TOO ═══════════════════
        -- The collapse witness expands the window mid-scan, and on this client
        -- that expand dispatches its update inside the call as well. The filter
        -- sub-surface must read the professions module's latch, not only its
        -- own: a clear fired from inside our expand would move the client's
        -- filters in the middle of the scan that issued it.
        do
            local savedLatch2 = Professions._collapseLatch
            local savedDepth2 = Professions._collapseDepth
            local clears = 0
            local realClear = F.ClearNative
            F.ClearNative = function(...) clears = clears + 1 return realClear(...) end
            F._state = { tradeskill = F.NewState() }
            F._echoes = nil

            Professions._collapseLatch = { tradeskill = true }
            ck(F.SelfEcho("tradeskill") == true,
               "the filter module could not see the professions module's own roundtrip")
            F._onEvent(nil, "TRADE_SKILL_UPDATE")
            ck(clears == 0,
               "an expand-all echo made the filter panel clear the client in the "
               .. "middle of the scan that issued it")
            ck(Professions.CaptureWindow("tradeskill", true, "test") == false,
               "the capture re-entered its own collapse roundtrip")

            Professions._collapseLatch = nil
            ck(F.SelfEcho("tradeskill") == false, "the peer latch never came back down")

            -- The collapse latch itself is NEST-SAFE now: a restore nested
            -- inside an expand used to clear the outer latch on its way out,
            -- which reopened the very window the outer call was holding shut.
            local inner = nil
            Professions._withCollapseLatch("tradeskill", function()
                Professions._withCollapseLatch("tradeskill", function() end)
                inner = Professions.WindowEchoLatched("tradeskill")
            end)
            ck(inner == true,
               "a nested collapse roundtrip disarmed the outer one's latch on the "
               .. "way out — the outer call finished its client work unguarded")
            ck(Professions.WindowEchoLatched("tradeskill") == false,
               "the collapse latch outlived its roundtrip")

            -- ...and the depth fuse refuses a third level rather than recursing.
            local ranThird = false
            Professions._withCollapseLatch("tradeskill", function()
                Professions._withCollapseLatch("tradeskill", function()
                    Professions._withCollapseLatch("tradeskill", function() ranThird = true end)
                end)
            end)
            ck(ranThird == false,
               "the collapse depth fuse let a third nested roundtrip through")
            ck((Professions._collapseRefused or 0) > 0,
               "the refused roundtrip was not recorded")

            F.ClearNative = realClear
            F._state = nil
            Professions._collapseLatch = savedLatch2
            Professions._collapseDepth = savedDepth2
            Professions._collapseRefused = nil
        end
    end)

    Professions.CaptureWindow = Professions.CaptureWindow      -- (restored inside runChain)
    Professions._leavingWorld, Professions._loggingOut = savedLatch[1], savedLatch[2]
    Professions._enteredWorldAt, Professions._live = savedLatch[3], savedLatch[4]
    Professions._scanAt, Professions._harvested = savedLatch[5], savedLatch[6]
    Professions._windowOpen, Professions._retry = savedLatch[7], savedLatch[8]
    Professions._stats, Professions._trace = savedLatch[9], savedLatch[10]
    Professions._lastSig = savedLatch[11]
    Professions._settled, Professions._stale = savedPerf[1], savedPerf[2]
    Professions._harvestJob = savedPerf[3]
    Professions._viewGuards = savedGuards
    if F then
        F._state, F._prof, F._panels = savedFilters[1], savedFilters[2], savedFilters[3]
        F._hooked, F._activated = savedFilters[4], savedFilters[5]
    end
    if ns.Store and ns.Store.data then ns.Store.data.professions = savedStore end
    if not ok then fails[#fails + 1] = "error in composed-chain fixtures: " .. tostring(err) end
end

----------------------------------------------------------------------
-- THE RESOLUTION CHAIN — the suite that reproduces the LIVE 11509 miss
--
-- The measured fact this suite is built around: on the owner's client (build
-- 1.15.9 / interface 11509) the TRADESKILL surface's GetTradeSkillRecipeLink
-- exists and returns NIL for real recipe rows, while GetTradeSkillItemLink
-- returns the crafted product's ITEM link. The shipped resolver accepted only
-- "enchant:" recipe links, so a real blacksmithing window read rows=176
-- (11 headers + 165 recipes), ids=0, unresolved=165, refused "unresolved",
-- forever — the composed-chain suite above could not see it because its
-- simulator handed out the enchant links the live client does not.
--
-- The RED CONTROL is the pre-fix resolver written out below and replayed
-- against the same unkind simulator; the green rows then drive the chain, and
-- the mutation legs break each rung in turn to show the degradation stays
-- honest: missed counts up, the refusal stands, nothing partial is written.
----------------------------------------------------------------------

-- THE PRE-FIX RESOLVER, verbatim in behavior: recipe-link only, "enchant:"
-- only, and a nil-NAME row silently skipped rather than counted. Stated here
-- rather than derived from the current code, because the current code is the
-- fix.
local function legacyResolveTradeSkill()
    local n = GetNumTradeSkills()
    if type(n) ~= "number" or n <= 0 then return nil, "empty", { n = n or 0, ids = 0, missed = 0 } end
    local ids, missed = {}, 0
    for i = 1, n do
        local name, kind = GetTradeSkillInfo(i)
        if kind ~= "header" and name ~= nil then
            local link = GetTradeSkillRecipeLink(i)
            local spell = (type(link) == "string") and tonumber(link:match("enchant:(%d+)")) or nil
            if spell then ids[#ids + 1] = spell else missed = missed + 1 end
        end
    end
    local ev = { n = n, ids = #ids, missed = missed }
    if #ids == 0 then return nil, "unresolved", ev end
    if missed > 0 then return nil, "incomplete", ev end
    return { ids = ids, complete = true }, nil, ev
end

local function testResolutionChain(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    if not Dataset.LoadCore() then
        fails[#fails + 1] = "the dataset would not load"
        return
    end

    local G = _G
    local saved = {
        numTS = G.GetNumTradeSkills, tsInfo = G.GetTradeSkillInfo,
        tsRecipe = G.GetTradeSkillRecipeLink, tsItem = G.GetTradeSkillItemLink,
        tsLine = G.GetTradeSkillLine, tsCD = G.GetTradeSkillCooldown,
        tsNameF = G.GetTradeSkillItemNameFilter, tsMake = G.GetOnlyShowMakeable,
        tsSkillUps = G.GetOnlyShowSkillUps,
        numCraft = G.GetNumCrafts, craftInfo = G.GetCraftInfo,
        craftRecipe = G.GetCraftRecipeLink, craftItem = G.GetCraftItemLink,
        craftEnch = G.CraftIsEnchanting, craftLine = G.GetCraftDisplaySkillLine,
        spellInfo = G.GetSpellInfo, getTime = G.GetTime,
    }
    local savedState = {
        Professions._leavingWorld, Professions._loggingOut, Professions._enteredWorldAt,
        Professions._live, Professions._scanAt, Professions._harvested,
        Professions._windowOpen, Professions._retry, Professions._stats,
        Professions._trace, Professions._lastSig, Professions._nameMap,
        Professions._recipeNames, Professions._viewGuards,
    }
    local savedPerf = { Professions._settled, Professions._stale, Professions._harvestJob }
    local savedArea = ns.Store and ns.Store.data and ns.Store.data.professions

    local ok, err = pcall(function()
        G.GetTime = function() return 50000 end
        Professions._leavingWorld, Professions._loggingOut = false, false
        Professions._enteredWorldAt = 0
        Professions._live, Professions._scanAt, Professions._harvested = nil, nil, nil
        Professions._windowOpen, Professions._retry = nil, nil
        Professions._stats, Professions._trace = nil, nil
        Professions._nameMap, Professions._recipeNames = nil, nil
        Professions._settled, Professions._stale, Professions._harvestJob = nil, nil, nil
        Professions._viewGuards = nil
        -- No client filter narrows the unkind window; the guard has real
        -- getters to ask so its verdict is "clear", not luck.
        G.GetTradeSkillItemNameFilter = function() return "" end
        G.GetOnlyShowMakeable = function() return false end
        G.GetOnlyShowSkillUps = function() return false end
        G.GetTradeSkillCooldown = function() return nil end

        local bs = Dataset.profRecipes[Dataset.profIdx.blacksmithing]

        -- The client's own name for a teaching spell, unique per id. Installed
        -- as GetSpellInfo so the name map is built from the CLIENT's answers,
        -- exactly as live.
        local function clientName(spell) return "Recipe Of Trial " .. tostring(spell) end
        G.GetSpellInfo = function(id) return clientName(id) end

        -- THE UNKIND 11509 WINDOW: 176 rows — 11 headers interleaved among 165
        -- real recipes — recipe links NIL, item links answering with the
        -- crafted product. The exact shape the owner measured.
        local W = { rows = {}, linkMode = "nil" }
        do
            local ri = 0
            for i = 1, 176 do
                if i % 16 == 1 then
                    W.rows[i] = { kind = "header", name = "Header " .. i }
                else
                    ri = ri + 1
                    W.rows[i] = { kind = "recipe", spell = bs[ri],
                                  name = clientName(bs[ri]), item = 50000 + ri }
                end
            end
            ck(ri == 165, "the fixture built " .. ri .. " recipe rows, wanted 165")
        end
        G.GetNumTradeSkills = function() return #W.rows end
        G.GetTradeSkillInfo = function(i)
            local r = W.rows[i]
            if not r then return nil end
            if r.hidden then return nil end               -- a row the client has not filled in
            if r.kind == "header" then return r.name, "header", 0, false end
            return r.name, "optimal", 1, false
        end
        G.GetTradeSkillRecipeLink = function(i)
            local r = W.rows[i]
            if not r or r.kind == "header" or r.hidden then return nil end
            if W.linkMode == "nil" then return nil end
            local form = (W.linkMode == "spell") and "Hspell:" or "Henchant:"
            return "|cffffd000|" .. form .. tostring(r.spell) .. "|h[x]|h|r"
        end
        G.GetTradeSkillItemLink = function(i)
            local r = W.rows[i]
            if not r or r.kind == "header" or r.hidden or not r.item then return nil end
            return "|cffffffff|Hitem:" .. tostring(r.item) .. ":0|h[" .. tostring(r.name) .. "]|h|r"
        end
        G.GetTradeSkillLine = function() return "Blacksmithing", 275, 300 end

        -- ══ (1) RED CONTROL: the pre-fix resolver against the live shape ═════
        local lScan, lWhy, lEv = legacyResolveTradeSkill()
        ck(lScan == nil and lWhy == "unresolved",
           "RED CONTROL DID NOT REPRODUCE: the legacy resolver answered '"
           .. tostring(lWhy) .. "' against the measured 11509 window")
        ck(lEv.n == 176 and lEv.ids == 0 and lEv.missed == 165,
           string.format("RED: legacy evidence reads rows=%d ids=%d missed=%d, "
           .. "the live trace read rows=176 ids=0 unresolved=165",
           lEv.n or -1, lEv.ids or -1, lEv.missed or -1))

        -- ══ (2) GREEN: the chain resolves the same window by NAME ════════════
        local scan, why, ev = Professions.ScanTradeSkillWindow()
        ck(scan ~= nil, "the chain did not resolve the 11509 window (" .. tostring(why) .. ")")
        ck(scan and scan.profKey == "blacksmithing",
           "the chain resolved the wrong profession: " .. tostring(scan and scan.profKey))
        ck(scan and #scan.ids == 165, "the chain resolved " .. tostring(scan and #scan.ids)
           .. " of 165 rows")
        ck(scan and scan.ev.res == "name",
           "the resolving rung reads '" .. tostring(scan and scan.ev.res) .. "', expected 'name'")
        ck(scan and scan.unknown == 0, "name-resolved ids voted " .. tostring(scan and scan.unknown)
           .. " unknowns into the profession resolve")
        -- ...and the ids are the RIGHT ids, not merely 165 of something.
        if scan then
            local wantSet = {}
            for i = 1, 165 do wantSet[bs[i]] = true end
            local wrong = 0
            for i = 1, #scan.ids do if not wantSet[scan.ids[i]] then wrong = wrong + 1 end end
            ck(wrong == 0, wrong .. " name-resolved id(s) are not the fixture's spells")
        end

        -- ══ (3) The widened link parse: a client that answers "spell:" links
        --        resolves on rung 1 and the name rung never has to fire ═══════
        W.linkMode = "spell"
        local s2 = Professions.ScanTradeSkillWindow()
        ck(s2 and s2.ev.res == "recipe-link",
           "a 'spell:' recipe link did not resolve on the link rung ("
           .. tostring(s2 and s2.ev.res) .. ")")
        W.linkMode = "nil"

        -- ══ (4) MUTATION: kill the name rung too — the scan refuses, writes
        --        nothing, and the trace sample carries the raw evidence ═══════
        Professions._recipeNames = nil               -- no memoised map to coast on
        G.GetSpellInfo = function() return nil end   -- class-4 cold spell data
        local s3, why3, ev3 = Professions.ScanTradeSkillWindow()
        ck(s3 == nil and why3 == "unresolved",
           "with every rung dead the scan answered '" .. tostring(why3) .. "'")
        ck(ev3 and ev3.n == 176 and ev3.ids == 0 and ev3.missed == 165,
           "the dead-chain evidence is not rows=176 ids=0 missed=165")
        ck(ev3 and type(ev3.sample) == "table", "no raw-evidence sample was recorded")
        if ev3 and ev3.sample then
            ck(ev3.sample.rl == "nil", "the sample's recipe link reads '"
               .. tostring(ev3.sample.rl) .. "', expected the literal string 'nil'")
            ck(type(ev3.sample.il) == "string" and ev3.sample.il:find("!Hitem:", 1, true) ~= nil,
               "the sample's item link is not the defanged raw link: " .. tostring(ev3.sample.il))
            ck(ev3.sample.nm ~= nil and ev3.sample.nm ~= "nil", "the sample lost the row name")
        end
        -- The cold read did not stick (class 5): warm the client back up and
        -- the very next scan succeeds without any reset ceremony.
        G.GetSpellInfo = function(id) return clientName(id) end
        local s4 = Professions.ScanTradeSkillWindow()
        ck(s4 ~= nil and s4.ev.res == "name",
           "a cold name-map build poisoned the session: the warm rescan refused")

        -- ══ (5) MUTATION: one row the dataset does not carry — missed, the
        --        scan refuses INCOMPLETE, and no partial set is written ════════
        Professions._live = nil
        local kept = W.rows[2]
        W.rows[2] = { kind = "recipe", name = "Utterly Undatasetted Widget", item = 61111 }
        local s5, why5, ev5 = Professions.ScanTradeSkillWindow()
        ck(s5 == nil and why5 == "incomplete",
           "a window with one unknown row answered '" .. tostring(why5) .. "'")
        ck(ev5 and ev5.ids == 164 and ev5.missed == 1,
           string.format("the incomplete evidence reads ids=%s missed=%s, expected 164/1",
           tostring(ev5 and ev5.ids), tostring(ev5 and ev5.missed)))
        ck(ev5 and ev5.sample and ev5.sample.nm == "Utterly Undatasetted Widget",
           "the sample did not name the row that missed")
        ck(Professions._live == nil or (Professions._live.p and next(Professions._live.p) == nil),
           "a refused incomplete scan still wrote a known set")
        W.rows[2] = kept

        -- ══ (6) MUTATION: a row the client has not filled in AT ALL (nil name,
        --        nil kind). The legacy resolver silently completed AROUND it —
        --        a 164-recipe 'complete' scan, the silent partial this module
        --        exists to forbid — the chain counts it missed and refuses ═════
        W.linkMode = "enchant"                       -- links work; only row 5 is dark
        W.rows[5].hidden = true
        local lScan2, lWhy2, lEv2 = legacyResolveTradeSkill()
        ck(lScan2 ~= nil and lEv2.ids == 164 and lEv2.missed == 0,
           "RED: the legacy resolver was expected to complete around the dark row "
           .. "(got " .. tostring(lWhy2) .. " ids=" .. tostring(lEv2 and lEv2.ids) .. ")")
        local s6, why6, ev6 = Professions.ScanTradeSkillWindow()
        ck(s6 == nil and why6 == "incomplete" and ev6 and ev6.missed == 1,
           "a dark row did not count as missed (" .. tostring(why6) .. ")")
        W.rows[5].hidden = nil
        W.linkMode = "nil"

        -- ══ (7) COLLISION: two dataset spells share one client name. Neither
        --        may win by luck; the harvested product id is the only witness
        --        allowed to break the tie, and without it the rows miss ════════
        Professions._recipeNames = nil
        G.GetSpellInfo = function(id)
            if id == bs[1] or id == bs[2] then return "The Colliding Name" end
            return clientName(id)
        end
        local origRow2, origRow3 = W.rows[2], W.rows[3]
        W.rows[2] = { kind = "recipe", spell = bs[1], name = "The Colliding Name", item = 70001 }
        W.rows[3] = { kind = "recipe", spell = bs[2], name = "The Colliding Name", item = 70002 }
        local s7, why7, ev7 = Professions.ScanTradeSkillWindow()
        ck(s7 == nil and why7 == "incomplete" and ev7 and ev7.missed == 2,
           "an unwitnessed name collision resolved anyway (" .. tostring(why7)
           .. " missed=" .. tostring(ev7 and ev7.missed) .. ")")
        -- Seed the witness: the reagent harvest of an earlier complete scan
        -- measured what each teaching spell produces.
        local S = ns.Store
        local area = S and S.ProfessionsReagents and S.ProfessionsReagents(true)
        ck(area ~= nil, "the reagent area would not open; the tiebreak leg cannot run")
        if area then
            area[bs[1]] = { o = 70001, r = { [2840] = 1 } }
            area[bs[2]] = { o = 70002, r = { [2840] = 1 } }
            local s8 = Professions.ScanTradeSkillWindow()
            ck(s8 ~= nil, "the witnessed collision still refused")
            if s8 then
                local got = {}
                for i = 1, #s8.rows do got[s8.rows[i].i] = s8.rows[i].spell end
                ck(got[2] == bs[1] and got[3] == bs[2],
                   "the product tiebreak paired the colliding rows wrongly")
                ck(tostring(s8.ev.res):find("name%+product") ~= nil,
                   "the tiebreak rung is invisible in res= (" .. tostring(s8.ev.res) .. ")")
            end
        end
        G.GetSpellInfo = function(id) return clientName(id) end
        W.rows[2], W.rows[3] = origRow2, origRow3
        Professions._recipeNames = nil

        -- ══ (8) THE FORENSICS RIDE THE TRACE, both directions ════════════════
        do
            local r0 = W.rows[2]
            W.rows[2] = { kind = "recipe", name = "Utterly Undatasetted Widget", item = 61111 }
            Professions._trace = nil
            local okCap, whyCap = Professions.CaptureWindow("tradeskill", true, "test-chain")
            ck(okCap == false and whyCap == "incomplete",
               "the capture did not relay the refusal (" .. tostring(whyCap) .. ")")
            local rowsT = Professions.TraceRows()
            local last = rowsT[#rowsT]
            ck(last and last.r == "incomplete" and type(last.x) == "table"
               and last.x.nm == "Utterly Undatasetted Widget",
               "the refused trace row does not carry the miss sample")
            ck(last and Professions.FormatTraceRow(last):find("miss[nm=", 1, true) ~= nil,
               "the rendered trace row does not show the sample")
            W.rows[2] = r0
            Professions._scanAt = nil
            local okCap2 = Professions.CaptureWindow("tradeskill", true, "test-chain")
            ck(okCap2 == true, "the healed window did not capture")
            local rowsT2 = Professions.TraceRows()
            local last2 = rowsT2[#rowsT2]
            ck(last2 and last2.r == "ok" and last2.res == "name",
               "the successful trace row does not name its rung (res="
               .. tostring(last2 and last2.res) .. ")")
            ck(last2 and Professions.FormatTraceRow(last2):find("res=name", 1, true) ~= nil,
               "the rendered success row does not show res=name")
        end

        -- ══ (9) THE CRAFT SURFACE: the enchant link stays primary, and the
        --        name rung is its safety net, not its replacement ══════════════
        local en = Dataset.profRecipes[Dataset.profIdx.enchanting]
        G.CraftIsEnchanting = function() return true end
        G.GetNumCrafts = function() return 6 end
        G.GetCraftDisplaySkillLine = function() return "Enchanting", 290, 300 end
        G.GetCraftItemLink = function() return nil end       -- enchants make no item
        local craftLinks = true
        G.GetCraftInfo = function(i)
            if i == 1 then return "Enchantments", nil, "header" end
            return clientName(en[i]), nil, "optimal"
        end
        G.GetCraftRecipeLink = function(i)
            if not craftLinks or i == 1 then return nil end
            return "|cffffd000|Henchant:" .. tostring(en[i]) .. "|h[x]|h|r"
        end
        local c1 = Professions.ScanCraftWindow()
        ck(c1 and c1.profKey == "enchanting" and c1.ev.res == "recipe-link",
           "the craft surface's enchant link is no longer primary ("
           .. tostring(c1 and c1.ev.res) .. ")")
        craftLinks = false                                   -- the surface drifts like 11509 did
        Professions._recipeNames = nil
        local c2 = Professions.ScanCraftWindow()
        ck(c2 and c2.profKey == "enchanting" and c2.ev.res == "name",
           "the craft surface did not fall back to the name rung ("
           .. tostring(c2 and c2.ev.res) .. ")")
    end)

    _G.GetNumTradeSkills, _G.GetTradeSkillInfo = saved.numTS, saved.tsInfo
    _G.GetTradeSkillRecipeLink, _G.GetTradeSkillItemLink = saved.tsRecipe, saved.tsItem
    _G.GetTradeSkillLine, _G.GetTradeSkillCooldown = saved.tsLine, saved.tsCD
    _G.GetTradeSkillItemNameFilter = saved.tsNameF
    _G.GetOnlyShowMakeable, _G.GetOnlyShowSkillUps = saved.tsMake, saved.tsSkillUps
    _G.GetNumCrafts, _G.GetCraftInfo = saved.numCraft, saved.craftInfo
    _G.GetCraftRecipeLink, _G.GetCraftItemLink = saved.craftRecipe, saved.craftItem
    _G.CraftIsEnchanting, _G.GetCraftDisplaySkillLine = saved.craftEnch, saved.craftLine
    _G.GetSpellInfo, _G.GetTime = saved.spellInfo, saved.getTime
    Professions._leavingWorld, Professions._loggingOut = savedState[1], savedState[2]
    Professions._enteredWorldAt, Professions._live = savedState[3], savedState[4]
    Professions._scanAt, Professions._harvested = savedState[5], savedState[6]
    Professions._windowOpen, Professions._retry = savedState[7], savedState[8]
    Professions._stats, Professions._trace = savedState[9], savedState[10]
    Professions._lastSig, Professions._nameMap = savedState[11], savedState[12]
    Professions._recipeNames, Professions._viewGuards = savedState[13], savedState[14]
    Professions._settled, Professions._stale = savedPerf[1], savedPerf[2]
    Professions._harvestJob = savedPerf[3]
    if ns.Store and ns.Store.data then ns.Store.data.professions = savedArea end
    if not ok then fails[#fails + 1] = "error in resolution-chain fixtures: " .. tostring(err) end
end

----------------------------------------------------------------------
-- THE SETTLED-SIGNATURE BUDGET — the suite whose currency is API CALL COUNTS
--
-- The live problem this branch fixes was never a wrong answer; it was the same
-- right answer re-derived at full price on every window event. So this suite's
-- assertions are CEILINGS on an instrumented client: a warm reopen of a settled
-- profession may read the cheap half of the window (GetNum*, the line, one info
-- per row) and NOTHING else — zero recipe links, zero GetSpellInfo, zero
-- reagent reads. A crafting spree performs zero full resolves. And the moments
-- that MUST re-pay full price — a learned recipe, a rank-up, a staleness
-- signal, a manual rescan — are each asserted to actually pay it, exactly once.
--
-- The RED CONTROL is the pre-fix cost model run against the same instrumented
-- window: one full resolve per non-coalesced event, which is what CaptureWindow
-- did before the signature existed. Crafts land seconds apart, so the throttle
-- never coalesced them — ten crafts really were ten full resolves.
----------------------------------------------------------------------

local function testSettledBudget(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    if not Dataset.LoadCore() then
        fails[#fails + 1] = "the dataset would not load"
        return
    end

    local G = _G
    local saved = {
        numTS = G.GetNumTradeSkills, tsInfo = G.GetTradeSkillInfo,
        tsRecipe = G.GetTradeSkillRecipeLink, tsItem = G.GetTradeSkillItemLink,
        tsLine = G.GetTradeSkillLine, tsCD = G.GetTradeSkillCooldown,
        rgN = G.GetTradeSkillNumReagents, rgI = G.GetTradeSkillReagentInfo,
        rgL = G.GetTradeSkillReagentItemLink, rgM = G.GetTradeSkillNumMade,
        spellInfo = G.GetSpellInfo,
        unitName = G.UnitName, realm = G.GetRealmName, fullName = G.UnitFullName,
        daseeki = G.Daseeki,
        nameF = G.GetTradeSkillItemNameFilter, makeF = G.GetOnlyShowMakeable,
        upsF = G.GetOnlyShowSkillUps,
    }
    local savedState = {
        Professions._leavingWorld, Professions._loggingOut, Professions._enteredWorldAt,
        Professions._live, Professions._scanAt, Professions._harvested,
        Professions._windowOpen, Professions._retry, Professions._stats,
        Professions._trace, Professions._lastSig, Professions._nameMap,
        Professions._recipeNames, Professions._viewGuards,
        Professions._settled, Professions._stale, Professions._harvestJob,
    }
    local savedArea = ns.Store and ns.Store.data and ns.Store.data.professions
    local F = ns.ProfessionFilters
    local savedConvSession = F and F._conv

    local clock = newClock(100000)

    local ok, err = pcall(function()
        clock:install()
        G.UnitName = function() return "BudgetTester" end
        G.GetRealmName = function() return "TestRealm" end
        G.UnitFullName = nil
        G.Daseeki = nil                              -- no mesh: Publish stays inert
        Professions._leavingWorld, Professions._loggingOut = false, false
        Professions._enteredWorldAt = 0
        Professions._live, Professions._scanAt, Professions._harvested = nil, nil, nil
        Professions._windowOpen, Professions._retry = nil, nil
        Professions._stats, Professions._trace = nil, nil
        Professions._nameMap, Professions._recipeNames = nil, nil
        Professions._settled, Professions._stale, Professions._harvestJob = nil, nil, nil
        Professions._viewGuards = nil
        Professions._lastSig = nil
        if F then F._conv = nil end
        if ns.Store and ns.Store.data then ns.Store.data.professions = nil end

        -- ══ THE INSTRUMENTED WINDOW ══════════════════════════════════════════
        -- 33 rows: 3 headers, 30 real blacksmithing recipes, enchant links (the
        -- kind client), reagents warm, every read COUNTED.
        local bs = Dataset.profRecipes[Dataset.profIdx.blacksmithing]
        local count = { num = 0, info = 0, link = 0, item = 0, line = 0,
                        cd = 0, spell = 0, rgN = 0, rgI = 0, rgL = 0 }
        local function zero() for k in pairs(count) do count[k] = 0 end end

        local W = { rows = {}, cds = {}, rank = 275 }
        local function rebuild(nRecipes)
            W.rows = {}
            local ri = 0
            for i = 1, nRecipes + 3 do
                if i == 1 or i == 12 or i == 23 then
                    W.rows[i] = { kind = "header", name = "Header " .. i }
                else
                    ri = ri + 1
                    W.rows[i] = { kind = "recipe", spell = bs[ri], name = "Recipe " .. bs[ri] }
                end
            end
            return ri
        end
        ck(rebuild(30) == 30, "the fixture did not build 30 recipe rows")

        G.GetNumTradeSkills = function() count.num = count.num + 1 return #W.rows end
        G.GetTradeSkillInfo = function(i)
            count.info = count.info + 1
            local r = W.rows[i]
            if not r then return nil end
            if r.kind == "header" then return r.name, "header", 0, false end
            return r.name, "optimal", 1, false
        end
        G.GetTradeSkillRecipeLink = function(i)
            count.link = count.link + 1
            local r = W.rows[i]
            if not r or r.kind == "header" then return nil end
            return "|cffffd000|Henchant:" .. tostring(r.spell) .. "|h[x]|h|r"
        end
        G.GetTradeSkillItemLink = function(i)
            count.item = count.item + 1
            local r = W.rows[i]
            if not r or r.kind == "header" then return nil end
            return "|cffffffff|Hitem:" .. tostring(60000 + i) .. ":0|h[o]|h|r"
        end
        G.GetTradeSkillLine = function()
            count.line = count.line + 1
            return "Blacksmithing", W.rank, 300
        end
        G.GetTradeSkillCooldown = function(i)
            count.cd = count.cd + 1
            return W.cds[i]
        end
        G.GetSpellInfo = function(id)
            count.spell = count.spell + 1
            return "Spell " .. tostring(id)
        end
        G.GetTradeSkillNumReagents = function() count.rgN = count.rgN + 1 return 2 end
        G.GetTradeSkillReagentInfo = function(i, j)
            count.rgI = count.rgI + 1
            return "reagent", nil, j
        end
        G.GetTradeSkillReagentItemLink = function(i, j)
            count.rgL = count.rgL + 1
            return "|cffffffff|Hitem:" .. tostring(1000 + i * 10 + j) .. ":0|h[r]|h|r"
        end
        G.GetTradeSkillNumMade = function() return 1, 1 end
        -- The view guard's readable witnesses all answer "clear", so the suite
        -- measures the capture rather than a refusal.
        G.GetTradeSkillItemNameFilter = function() return "" end
        G.GetOnlyShowMakeable = function() return false end
        G.GetOnlyShowSkillUps = function() return false end

        local nRows = #W.rows
        Professions.OpenWindow("tradeskill", true)

        -- ══ RED CONTROL: the pre-fix cost of a ten-craft spree ═══════════════
        -- Before the signature, every craft's update re-ran the FULL resolve
        -- (crafts land seconds apart; the one-second throttle never coalesced
        -- them). Ten crafts: ten full walks of every link.
        zero()
        for i = 1, 10 do
            local s = Professions.ScanTradeSkillWindow()
            ck(s ~= nil, "the red-control scan refused")
        end
        local legacyLink, legacyInfo = count.link, count.info
        ck(legacyLink >= 10 * 30,
           "RED CONTROL DID NOT REPRODUCE: ten pre-fix scans cost only "
           .. legacyLink .. " recipe-link reads")

        -- ══ (1) THE GENUINELY-FIRST CAPTURE pays full price ONCE ═════════════
        zero()
        Professions._live, Professions._scanAt = nil, nil
        ck(Professions.CaptureWindow("tradeskill", true, "TRADE_SKILL_SHOW") == true,
           "the first capture did not land")
        clock:pump(clock.now + 1)              -- run the time-sliced harvest out
        local firstLink, firstRgL = count.link, count.rgL
        ck(firstLink >= 30, "the first capture did not walk the links (" .. firstLink .. ")")
        ck(firstRgL >= 60, "the harvest did not read the reagent links (" .. firstRgL .. ")")
        ck(Professions.HarvestStamped("blacksmithing"),
           "a complete harvest did not stamp the store")
        ck(Professions.SettledGet("blacksmithing") ~= nil,
           "the accepted scan left no settled record")
        local mineStore = Professions.SettledArea(false)
        ck(mineStore ~= nil and mineStore.blacksmithing ~= nil,
           "the settled record was not persisted in the store")

        -- ══ (2) WARM REOPEN: the signature pass and NOTHING else ═════════════
        zero()
        ck(Professions.CaptureWindow("tradeskill", true, "TRADE_SKILL_SHOW") == true,
           "the warm reopen was refused")
        ck(count.link == 0, "a settled reopen read " .. count.link .. " recipe links; the ceiling is 0")
        ck(count.spell == 0, "a settled reopen called GetSpellInfo " .. count.spell .. " times; the ceiling is 0")
        ck(count.item == 0, "a settled reopen read " .. count.item .. " item links; the ceiling is 0")
        ck(count.rgL == 0, "a settled reopen re-read the reagent harvest")
        ck(count.info <= nRows,
           "a settled reopen read " .. count.info .. " rows of info; the ceiling is " .. nRows)
        local ring = Professions.TraceRows()
        ck(ring[#ring] and ring[#ring].r == "settled",
           "the warm reopen's verdict was '" .. tostring(ring[#ring] and ring[#ring].r)
           .. "', expected 'settled'")
        Professions._measuredWarmReopen = { info = count.info, num = count.num,
                                            line = count.line, cd = count.cd }

        -- ══ (3) A TEN-CRAFT SPREE performs ZERO full resolves ════════════════
        zero()
        for i = 1, 10 do
            clock:pump(clock.now + 1.5)        -- crafts land outside the throttle
            ck(Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE") == true,
               "a spree update was refused")
        end
        ck(count.link == 0 and count.spell == 0,
           "the spree performed a full resolve (links=" .. count.link
           .. " spellinfo=" .. count.spell .. "); the pre-fix cost of the same spree was "
           .. legacyLink .. " link reads")
        local st = Professions.Stats("blacksmithing")
        ck(st and st.ok == 1, "the spree re-ran the full capture "
           .. tostring(st and st.ok) .. " time(s); only the first open may")
        ck(st and (st.settled or 0) >= 11, "the settled tally reads "
           .. tostring(st and st.settled) .. ", expected the reopen plus ten crafts")

        -- ══ (4) A CONSUMED COOLDOWN publishes off the settled pass ═══════════
        -- (f): crafting a cooldown recipe mid-spree must be noticed WITHOUT a
        -- full resolve and without a manual rescan.
        W.cds[2] = 3600                        -- row 2's recipe went on cooldown
        zero()
        clock:pump(clock.now + 1.5)
        ck(Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE") == true,
           "the cooldown-carrying update was refused")
        local cdKey = tostring(W.rows[2].spell)
        ck(Professions.Live().c[cdKey] ~= nil,
           "the consumed cooldown did not reach the live record off a settled pass")
        ck(count.link == 0, "noticing the cooldown cost a full resolve")
        ck(count.cd >= 30, "the settled pass did not actually read the cooldowns ("
           .. count.cd .. ")")
        W.cds[2] = nil
        clock:pump(clock.now + 1.5)
        Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE")
        ck(Professions.Live().c[cdKey] == nil,
           "the proven-ready cooldown was not cleared by the settled pass")

        -- ══ (5) LEARNING A RECIPE: drift => exactly ONE full rescan ══════════
        rebuild(31)                            -- the sim adds a row
        nRows = #W.rows
        zero()
        clock:pump(clock.now + 1.5)
        ck(Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE") == true,
           "the drifted window was refused")
        ck(count.link >= 31, "the learned recipe did not force a full rescan ("
           .. count.link .. " links)")
        ck(Professions._live.p.blacksmithing.n == 31,
           "the rescan did not pick up the new recipe ("
           .. tostring(Professions._live.p.blacksmithing.n) .. ")")
        zero()
        clock:pump(clock.now + 1.5)
        ck(Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE") == true,
           "the re-settled window was refused")
        ck(count.link == 0, "the window did not re-settle after the rescan")

        -- ══ (6) RANK-UP => full rescan, both through the signature and the
        --        staleness mark ══════════════════════════════════════════════
        W.rank = 276                           -- the signature's own rank component
        zero()
        clock:pump(clock.now + 1.5)
        Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE")
        ck(count.link >= 31, "a rank-up did not drift the signature")
        Professions._onEvent(nil, "CHAT_MSG_SKILL")     -- the event mark, unattributed
        ck(Professions.IsStale("blacksmithing"),
           "CHAT_MSG_SKILL did not mark the settled profession stale")
        zero()
        clock:pump(clock.now + 1.5)
        Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE")
        ck(count.link >= 31, "a stale profession settled instead of re-scanning")
        ck(not Professions.IsStale("blacksmithing"),
           "the full rescan did not clear the staleness mark")

        -- ...and an ATTRIBUTED learn marks only its own profession.
        local alSpell = Dataset.profRecipes[Dataset.profIdx.alchemy][1]
        Professions._onEvent(nil, "LEARNED_SPELL_IN_SKILL_LINE", alSpell)
        ck(Professions.IsStale("alchemy") == true,
           "an attributed learn did not mark its profession")
        ck(Professions.IsStale("blacksmithing") == false,
           "an attributed alchemy learn marked blacksmithing stale")
        Professions._stale = nil

        -- ══ (7) MANUAL RESCAN: signature ignored, full capture, re-harvest,
        --        probe re-measure allowed ═════════════════════════════════════
        if F and F.RememberForm then
            F.RememberForm("tradeskill", "subAll", { n = 1 })
            F.Conv("tradeskill")               -- seed the session mirror too
        end
        zero()
        ck(Professions.ForceRescan("tradeskill") == true, "the manual rescan did not capture")
        ck(count.link >= 31, "the manual rescan honored the signature it must ignore")
        clock:pump(clock.now + 1)              -- the re-harvest slices
        ck(count.rgL >= 62, "the manual rescan did not re-harvest (" .. count.rgL .. ")")
        ck(Professions.HarvestStamped("blacksmithing"),
           "the re-harvest did not re-stamp")
        if F and F.ConvStoreArea then
            local area = F.ConvStoreArea(false)
            ck(not (area and area.tradeskill and area.tradeskill.subAll),
               "the manual rescan kept the persisted filter conventions")
        end

        -- ══ (8) "RELOG": the store's settled record carries a warm first open —
        --        zero links, zero GetSpellInfo, on the session's very first look.
        Professions._settled = nil             -- session mirror gone
        Professions._nameMap, Professions._recipeNames = nil, nil
        Professions._stale = nil
        zero()
        ck(Professions.CaptureWindow("tradeskill", true, "TRADE_SKILL_SHOW") == true,
           "the post-relog open was refused")
        ck(count.link == 0 and count.spell == 0,
           "the post-relog open re-ran the full resolve (links=" .. count.link
           .. " spellinfo=" .. count.spell .. ") — the store record did not carry")

        -- ══ (9) A HARVEST ABORTED MID-SLICE heals off the settled pass ═══════
        Professions.ClearHarvestStamp("blacksmithing")
        Professions._scanAt = nil
        clock:pump(clock.now + 1.5)
        ck(Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE") == true,
           "the pre-abort update was refused")
        Professions.CloseWindow("tradeskill")  -- the player walks away mid-harvest
        clock:pump(clock.now + 1)
        ck(not Professions.HarvestStamped("blacksmithing"),
           "an aborted harvest still stamped the store")
        Professions.OpenWindow("tradeskill", true)
        ck(Professions.CaptureWindow("tradeskill", true, "TRADE_SKILL_SHOW") == true,
           "the post-abort reopen was refused")
        clock:pump(clock.now + 1)
        ck(Professions.HarvestStamped("blacksmithing"),
           "the settled pass did not heal the aborted harvest")

        Professions._measuredSpree = { legacyLink = legacyLink, legacyInfo = legacyInfo }
    end)

    clock:restore()
    G.GetNumTradeSkills, G.GetTradeSkillInfo = saved.numTS, saved.tsInfo
    G.GetTradeSkillRecipeLink, G.GetTradeSkillItemLink = saved.tsRecipe, saved.tsItem
    G.GetTradeSkillLine, G.GetTradeSkillCooldown = saved.tsLine, saved.tsCD
    G.GetTradeSkillNumReagents, G.GetTradeSkillReagentInfo = saved.rgN, saved.rgI
    G.GetTradeSkillReagentItemLink, G.GetTradeSkillNumMade = saved.rgL, saved.rgM
    G.GetSpellInfo = saved.spellInfo
    G.UnitName, G.GetRealmName, G.UnitFullName = saved.unitName, saved.realm, saved.fullName
    G.Daseeki = saved.daseeki
    G.GetTradeSkillItemNameFilter, G.GetOnlyShowMakeable = saved.nameF, saved.makeF
    G.GetOnlyShowSkillUps = saved.upsF
    Professions._leavingWorld, Professions._loggingOut = savedState[1], savedState[2]
    Professions._enteredWorldAt, Professions._live = savedState[3], savedState[4]
    Professions._scanAt, Professions._harvested = savedState[5], savedState[6]
    Professions._windowOpen, Professions._retry = savedState[7], savedState[8]
    Professions._stats, Professions._trace = savedState[9], savedState[10]
    Professions._lastSig, Professions._nameMap = savedState[11], savedState[12]
    Professions._recipeNames, Professions._viewGuards = savedState[13], savedState[14]
    Professions._settled, Professions._stale = savedState[15], savedState[16]
    Professions._harvestJob = savedState[17]
    if ns.Store and ns.Store.data then ns.Store.data.professions = savedArea end
    if F then F._conv = savedConvSession end
    if not ok then fails[#fails + 1] = "error in settled-budget fixtures: " .. tostring(err) end
end

----------------------------------------------------------------------
-- THE COLLAPSE HONESTY SUITE  (fix/professions-collapse)
--
-- The exposure: a window opened with collapsed category headers enumerates
-- fewer rows, every visible row resolves cleanly, and a full scan of it would
-- write the shortened set as the character's complete known-recipe list. The
-- RED CONTROL below reproduces exactly that with the pre-fix write path (scan
-- then apply, no collapse gate) against a 165-recipe window showing 30 rows.
--
-- The sim models collapse the way the client does: a collapsed category
-- enumerates only its header row, expand-all is the index-0 convention, and
-- every expand/collapse call ECHOES a window update synchronously — the
-- unkindest ordering, since it re-enters the module inside its own roundtrip.
-- Profiles: "witnessed" (boolean header state), "unreadable" (the pre-boolean
-- 1/nil convention), "noop-expand" (expand-all measured doing nothing), and
-- "close-on-expand" (the player closes the window inside the expand).
----------------------------------------------------------------------

local function newCollapseSim(cats, profile)
    local W = { cats = cats, profile = profile or "witnessed", cds = {},
                count = { num = 0, info = 0, link = 0, expandAll = 0,
                          expandOne = 0, collapse = 0 } }
    local G = _G
    local saved = {}

    function W.visible()
        local rows = {}
        for c = 1, #W.cats do
            local cat = W.cats[c]
            rows[#rows + 1] = { kind = "header", name = cat.name, cat = cat }
            if not cat.collapsed then
                for r = 1, #cat.spells do
                    rows[#rows + 1] = { kind = "recipe",
                                        name = "Recipe " .. tostring(cat.spells[r]),
                                        s = cat.spells[r] }
                end
            end
        end
        return rows
    end

    local function emit(event)
        if Professions._onEvent then Professions._onEvent(nil, event) end
    end
    W.emit = emit

    function W.zero()
        for k in pairs(W.count) do W.count[k] = 0 end
    end

    function W.collapsedSet()
        local out = {}
        for c = 1, #W.cats do
            if W.cats[c].collapsed then out[W.cats[c].name] = true end
        end
        return out
    end

    function W:install()
        saved = {
            num = G.GetNumTradeSkills, info = G.GetTradeSkillInfo,
            link = G.GetTradeSkillRecipeLink, item = G.GetTradeSkillItemLink,
            line = G.GetTradeSkillLine, cd = G.GetTradeSkillCooldown,
            exp = G.ExpandTradeSkillSubClass, col = G.CollapseTradeSkillSubClass,
            nameF = G.GetTradeSkillItemNameFilter, makeF = G.GetOnlyShowMakeable,
            upsF = G.GetOnlyShowSkillUps,
            rgN = G.GetTradeSkillNumReagents, rgI = G.GetTradeSkillReagentInfo,
            rgL = G.GetTradeSkillReagentItemLink, rgM = G.GetTradeSkillNumMade,
            unit = G.UnitName, realm = G.GetRealmName, full = G.UnitFullName,
            daseeki = G.Daseeki,
        }
        G.GetNumTradeSkills = function()
            W.count.num = W.count.num + 1
            return #W.visible()
        end
        G.GetTradeSkillInfo = function(i)
            W.count.info = W.count.info + 1
            local row = W.visible()[i]
            if not row then return nil end
            if row.kind == "header" then
                local x
                if W.profile == "unreadable" then
                    x = row.cat.collapsed and nil or 1        -- the 1/nil convention
                else
                    x = not row.cat.collapsed                 -- the boolean convention
                end
                return row.name, "header", 0, x
            end
            return row.name, "optimal", 1, true
        end
        G.GetTradeSkillRecipeLink = function(i)
            W.count.link = W.count.link + 1
            local row = W.visible()[i]
            if not row or row.kind == "header" then return nil end
            return "|cffffd000|Henchant:" .. tostring(row.s) .. "|h[x]|h|r"
        end
        G.GetTradeSkillItemLink = function() return nil end
        G.GetTradeSkillLine = function() return "Blacksmithing", 275, 300 end
        G.GetTradeSkillCooldown = function(i)
            local row = W.visible()[i]
            return (row and row.s) and W.cds[row.s] or nil
        end
        G.ExpandTradeSkillSubClass = function(idx)
            if idx == 0 then
                W.count.expandAll = W.count.expandAll + 1
                if W.profile ~= "noop-expand" then
                    for c = 1, #W.cats do W.cats[c].collapsed = nil end
                end
                -- The echo, synchronously, INSIDE the call — the unkindest
                -- ordering. close-on-expand models the player slamming the
                -- window shut at exactly that moment.
                if W.profile == "close-on-expand" then emit("TRADE_SKILL_CLOSE")
                else emit("TRADE_SKILL_UPDATE") end
            else
                W.count.expandOne = W.count.expandOne + 1
                local row = W.visible()[idx]
                if row and row.kind == "header" then row.cat.collapsed = nil end
                emit("TRADE_SKILL_UPDATE")
            end
        end
        G.CollapseTradeSkillSubClass = function(idx)
            W.count.collapse = W.count.collapse + 1
            local row = W.visible()[idx]
            if row and row.kind == "header" then row.cat.collapsed = true end
            emit("TRADE_SKILL_UPDATE")
        end
        G.GetTradeSkillItemNameFilter = function() return "" end
        G.GetOnlyShowMakeable = function() return false end
        G.GetOnlyShowSkillUps = function() return false end
        G.GetTradeSkillNumReagents = function() return 1 end
        G.GetTradeSkillReagentInfo = function() return "reagent", nil, 2 end
        G.GetTradeSkillReagentItemLink = function()
            return "|cffffffff|Hitem:2840:0|h[r]|h|r"
        end
        G.GetTradeSkillNumMade = function() return 1, 1 end
        G.UnitName = function() return "CollapseTester" end
        G.GetRealmName = function() return "TestRealm" end
        G.UnitFullName = nil
        G.Daseeki = nil                       -- no mesh: Publish stays inert
    end

    function W:restore()
        G.GetNumTradeSkills, G.GetTradeSkillInfo = saved.num, saved.info
        G.GetTradeSkillRecipeLink, G.GetTradeSkillItemLink = saved.link, saved.item
        G.GetTradeSkillLine, G.GetTradeSkillCooldown = saved.line, saved.cd
        G.ExpandTradeSkillSubClass, G.CollapseTradeSkillSubClass = saved.exp, saved.col
        G.GetTradeSkillItemNameFilter, G.GetOnlyShowMakeable = saved.nameF, saved.makeF
        G.GetOnlyShowSkillUps = saved.upsF
        G.GetTradeSkillNumReagents, G.GetTradeSkillReagentInfo = saved.rgN, saved.rgI
        G.GetTradeSkillReagentItemLink, G.GetTradeSkillNumMade = saved.rgL, saved.rgM
        G.UnitName, G.GetRealmName, G.UnitFullName = saved.unit, saved.realm, saved.full
        G.Daseeki = saved.daseeki
    end

    return W
end

local function testCollapseHonesty(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    if not Dataset.LoadCore() then
        fails[#fails + 1] = "the dataset would not load"
        return
    end

    local G = _G
    local savedState = {
        Professions._leavingWorld, Professions._loggingOut, Professions._enteredWorldAt,
        Professions._live, Professions._scanAt, Professions._harvested,
        Professions._windowOpen, Professions._retry, Professions._stats,
        Professions._trace, Professions._lastSig, Professions._nameMap,
        Professions._recipeNames, Professions._viewGuards,
        Professions._settled, Professions._stale, Professions._harvestJob,
        Professions._collapseLatch, Professions._collapseWorld,
    }
    local savedArea = ns.Store and ns.Store.data and ns.Store.data.professions
    -- The filter sub-surface is composedChain's territory; here it would only
    -- add its own re-captures to the call counts this suite asserts on.
    local savedFilters = ns.ProfessionFilters
    ns.ProfessionFilters = nil

    local clock = newClock(200000)
    local sim = nil

    local function resetModule()
        Professions._leavingWorld, Professions._loggingOut = false, false
        Professions._enteredWorldAt = 0
        Professions._live, Professions._scanAt, Professions._harvested = nil, nil, nil
        Professions._windowOpen, Professions._retry = nil, nil
        Professions._stats, Professions._trace = nil, nil
        Professions._nameMap, Professions._recipeNames = nil, nil
        Professions._settled, Professions._stale, Professions._harvestJob = nil, nil, nil
        Professions._viewGuards, Professions._lastSig = nil, nil
        Professions._collapseLatch, Professions._collapseWorld = nil, nil
        Professions._collapseDepth, Professions._collapseRefused = nil, nil
        if ns.Store and ns.Store.data then ns.Store.data.professions = nil end
    end

    -- 165 blacksmithing recipes across six categories; category 1 (24 recipes)
    -- expanded, categories 2-6 (141 recipes) collapsed. Visible: 6 headers +
    -- 24 recipes = 30 rows standing in for a 171-row truth.
    local bs = Dataset.profRecipes[Dataset.profIdx.blacksmithing]
    local function buildCats()
        local sizes = { 24, 29, 28, 28, 28, 28 }
        local cats, at = {}, 0
        for c = 1, #sizes do
            local spells = {}
            for r = 1, sizes[c] do
                at = at + 1
                spells[r] = bs[at]
            end
            cats[c] = { name = "Category " .. c, spells = spells,
                        collapsed = (c > 1) or nil }
        end
        return cats, at
    end

    local ok, err = pcall(function()
        clock:install()
        resetModule()
        local cats, total = buildCats()
        ck(total == 165, "the fixture built " .. total .. " recipes, wanted 165")
        sim = newCollapseSim(cats, "witnessed")
        sim:install()

        -- ══ (1) RED CONTROL: the pre-fix write path against the collapsed
        --        window. Scan-then-apply, no collapse gate — the shortened set
        --        goes down as the character's complete list. THE LIE. ═════════
        local scan = Professions.ScanTradeSkillWindow()
        ck(scan ~= nil and scan.complete == true and scan.profKey == "blacksmithing",
           "RED: the collapsed window's scan no longer presents itself as complete"
           .. " — the exposure vanished from the fixture")
        ck(scan and #scan.ids == 24,
           "RED: the collapsed window resolved " .. tostring(scan and #scan.ids)
           .. " rows, expected the 24 visible ones")
        Professions.ApplyScan(scan, 12345)
        ck(Professions._live.p.blacksmithing.n == 24,
           "RED CONTROL DID NOT REPRODUCE: the pre-fix path wrote "
           .. tostring(Professions._live.p.blacksmithing.n)
           .. " known recipes as the complete set; the character knows 165")
        -- ...and the witness that makes the green path possible was THERE, in
        -- the same read the scan already paid for.
        ck(scan and scan.ev.clp and #scan.ev.clp == 5,
           "the scan did not witness the 5 collapsed headers ("
           .. tostring(scan and scan.ev.clp and #scan.ev.clp) .. ")")

        -- ══ (2) GREEN: the same window through CaptureWindow — expand all,
        --        scan complete, restore the player's exact collapse set ═══════
        resetModule()
        sim.zero()
        Professions.OpenWindow("tradeskill", true)
        ck(Professions.CaptureWindow("tradeskill", true, "TRADE_SKILL_SHOW") == true,
           "the collapsed window's capture did not land")
        ck(Professions._live.p.blacksmithing.n == 165,
           "the roundtrip wrote " .. tostring(Professions._live.p.blacksmithing.n)
           .. " known recipes, expected the full 165")
        ck(sim.count.expandAll == 1,
           "the roundtrip issued " .. sim.count.expandAll .. " expand-all call(s), expected 1")
        ck(sim.count.collapse == 5,
           "the restore issued " .. sim.count.collapse .. " collapse call(s), expected 5")
        local set = sim.collapsedSet()
        local restoredExactly = not set["Category 1"]
        for c = 2, 6 do
            if not set["Category " .. c] then restoredExactly = false end
        end
        ck(restoredExactly, "the player's exact collapse set did not survive the roundtrip")
        local ring = Professions.TraceRows()
        local last = ring[#ring]
        ck(last and last.r == "ok"
           and tostring(last.w):find("roundtrip(5/5)", 1, true) ~= nil,
           "the trace does not record the roundtrip (r=" .. tostring(last and last.r)
           .. " collapse=" .. tostring(last and last.w) .. ")")
        local rec = Professions.SettledGet("blacksmithing")
        ck(rec ~= nil and rec.n == 171,
           "the settled record was not taken at full expansion (n="
           .. tostring(rec and rec.n) .. ", expected 171)")
        -- No harvest behind a restore: its row indexes would name hidden rows.
        clock:pump(clock.now + 1)
        ck(not Professions.HarvestStamped("blacksmithing"),
           "a roundtrip capture stamped a harvest whose indexes the restore invalidated")

        -- ══ (3) THE LOOP KILLER: a stream of update echoes on the restored
        --        (collapsed again) window — zero rescans, zero expand calls,
        --        the distinct settled-collapsed verdict, STAYS SETTLED ════════
        sim.zero()
        for i = 1, 10 do
            clock:pump(clock.now + 1.5)
            ck(Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE") == true,
               "a collapsed-window update was refused (event " .. i .. ")")
        end
        ck(sim.count.link == 0,
           "the collapsed settled window paid a full resolve (" .. sim.count.link .. " links)")
        ck(sim.count.expandAll == 0 and sim.count.collapse == 0,
           "the loop killer failed: expand=" .. sim.count.expandAll
           .. " collapse=" .. sim.count.collapse .. " — the flicker cycle is alive")
        local ring3 = Professions.TraceRows()
        local last3 = ring3[#ring3]
        ck(last3 and last3.r == "settled-collapsed",
           "the declined verify is not trace-recorded distinctly (r="
           .. tostring(last3 and last3.r) .. ")")
        ck(last3 and last3.c == 10,
           "ten settled-collapsed verdicts did not coalesce onto one ring row (c="
           .. tostring(last3 and last3.c) .. ")")
        local st = Professions.Stats("blacksmithing")
        ck(st and (st.settledc or 0) == 10,
           "the settled-collapsed tally reads " .. tostring(st and st.settledc)
           .. ", expected 10")
        ck(st and st.ok == 1,
           "the echo stream re-ran the full capture " .. tostring(st and st.ok)
           .. " time(s); only the roundtrip may")

        -- ══ (4) COOLDOWNS still publish off the VISIBLE rows of a collapsed
        --        settled window — proof-gated, hidden rows left alone ═════════
        local cdSpell = cats[1].spells[1]              -- visible: category 1 is expanded
        local cdRec = Dataset.recipe[cdSpell]
        local cdKey = (cdRec.cd and cdRec.cd > 0) and ("g" .. cdRec.cd) or tostring(cdSpell)
        sim.cds[cdSpell] = 3600
        sim.zero()
        clock:pump(clock.now + 1.5)
        ck(Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE") == true,
           "the cooldown-carrying collapsed update was refused")
        ck(Professions.Live().c[cdKey] ~= nil,
           "a consumed cooldown on a visible row did not publish off the settled-collapsed pass")
        ck(sim.count.link == 0, "noticing the cooldown cost a full resolve")
        sim.cds[cdSpell] = nil
        clock:pump(clock.now + 1.5)
        Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE")
        ck(Professions.Live().c[cdKey] == nil,
           "the proven-ready cooldown was not cleared by the settled-collapsed pass")

        -- ══ (5) STALENESS BYPASSES the loop killer: a learning signal on the
        --        collapsed window still forces the honest expand-scan-restore ═
        Professions._onEvent(nil, "CHAT_MSG_SKILL")
        sim.zero()
        clock:pump(clock.now + 1.5)
        ck(Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE") == true,
           "the stale collapsed window was refused")
        ck(sim.count.expandAll == 1 and sim.count.link >= 165,
           "a stale collapsed window did not run the full expand-scan cycle (expand="
           .. sim.count.expandAll .. " links=" .. sim.count.link .. ")")
        ck(sim.count.collapse == 5, "the stale-forced roundtrip did not restore")
        ck(not Professions.IsStale("blacksmithing"),
           "the roundtrip did not clear the staleness mark")

        -- ══ (6) MID-EXPAND WINDOW CLOSE: clean abort — nothing written, no
        --        dangling restore, no ladder against a closed window ══════════
        sim:restore()
        resetModule()
        local cats6 = buildCats()
        sim = newCollapseSim(cats6, "close-on-expand")
        sim:install()
        Professions.OpenWindow("tradeskill", true)
        local ok6, why6 = Professions.CaptureWindow("tradeskill", true, "TRADE_SKILL_SHOW")
        ck(ok6 == false and why6 == "window-closed",
           "the mid-expand close was answered '" .. tostring(why6)
           .. "', expected the clean window-closed abort")
        ck(sim.count.collapse == 0, "a dangling restore ran against a closed window")
        ck(not (Professions._live and Professions._live.p
                and Professions._live.p.blacksmithing),
           "the aborted capture still wrote a known set")
        ck(not (Professions._retry and Professions._retry.tradeskill),
           "a retry ladder was armed against a closed window")

        -- ══ (7) THE WITNESS-UNREADABLE CLIENT: expand-all before every full
        --        scan, leave expanded, recorded — honest scan, no restore ═════
        sim:restore()
        resetModule()
        local cats7 = buildCats()
        sim = newCollapseSim(cats7, "unreadable")
        sim:install()
        sim.zero()
        Professions.OpenWindow("tradeskill", true)
        ck(Professions.CaptureWindow("tradeskill", true, "TRADE_SKILL_SHOW") == true,
           "the blind-world capture did not land")
        ck(Professions._live.p.blacksmithing.n == 165,
           "the blind world wrote " .. tostring(Professions._live.p.blacksmithing.n)
           .. " known recipes, expected 165")
        ck(sim.count.expandAll == 1,
           "the blind world issued " .. sim.count.expandAll .. " expand-all call(s)")
        ck(sim.count.collapse == 0, "the blind world restored without a witness")
        local anyCollapsed = false
        for c = 1, #cats7 do if cats7[c].collapsed then anyCollapsed = true end end
        ck(not anyCollapsed, "the blind world did not leave the window expanded")
        local ring7 = Professions.TraceRows()
        local last7 = ring7[#ring7]
        ck(last7 and last7.r == "ok"
           and tostring(last7.w):find("blind", 1, true) ~= nil,
           "the blind world is not named in the trace (collapse="
           .. tostring(last7 and last7.w) .. ")")
        ck(Professions._collapseWorld and Professions._collapseWorld.tradeskill
           and tostring(Professions._collapseWorld.tradeskill):find("blind", 1, true) ~= nil,
           "the debug readout does not know which world the client is")
        -- The settled path in this world runs as today: an unchanged expanded
        -- window settles on the strict walk, no witness required...
        sim.zero()
        clock:pump(clock.now + 1.5)
        ck(Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE") == true,
           "the blind-world settled reopen was refused")
        ck(sim.count.link == 0, "the blind-world settled pass paid a full resolve")
        -- ...and a player re-collapsing LOOKS like drift, which forces a full
        -- scan, which expands again. Accepted: full scans are rare and manual.
        for c = 2, #cats7 do cats7[c].collapsed = true end
        sim.zero()
        clock:pump(clock.now + 1.5)
        ck(Professions.CaptureWindow("tradeskill", false, "TRADE_SKILL_UPDATE") == true,
           "the blind-world shrink was refused instead of full-scanned")
        ck(sim.count.expandAll == 1 and sim.count.link >= 165,
           "the blind-world shrink was not answered by an expanding full scan (expand="
           .. sim.count.expandAll .. " links=" .. sim.count.link .. ")")

        -- ══ (8) THE EXPAND CONVENTION MEASURED WRONG (index-0 no-op): the
        --        refusal "collapsed", no shortened write, a ladder that ends ══
        sim:restore()
        resetModule()
        local cats8 = buildCats()
        sim = newCollapseSim(cats8, "noop-expand")
        sim:install()
        sim.zero()
        Professions.OpenWindow("tradeskill", true)
        local ok8, why8 = Professions.CaptureWindow("tradeskill", true, "TRADE_SKILL_SHOW")
        ck(ok8 == false and why8 == "collapsed",
           "the measured no-op was answered '" .. tostring(why8)
           .. "', expected the refusal 'collapsed'")
        ck(not (Professions._live and Professions._live.p
                and Professions._live.p.blacksmithing),
           "the unexpandable collapsed window still wrote a shortened set")
        ck(sim.count.collapse == 0,
           "the no-op refusal re-collapsed headers that never moved")
        local ring8 = Professions.TraceRows()
        local last8 = ring8[#ring8]
        ck(last8 and last8.r == "collapsed" and last8.w == "expand-noop",
           "the refusal is not recorded with its measured reason (r="
           .. tostring(last8 and last8.r) .. " collapse=" .. tostring(last8 and last8.w) .. ")")
        -- The ladder retries the retryable refusal and TERMINATES.
        local before = sim.count.expandAll
        clock:pump(clock.now + 30)
        local rungs = sim.count.expandAll - before
        ck(rungs >= 1, "the ladder never retried the collapsed refusal")
        ck(rungs <= #Professions.RETRY_LADDER,
           "the ladder ran " .. rungs .. " retries against " .. #Professions.RETRY_LADDER
           .. " rungs — it is polling")
        local at = sim.count.expandAll
        clock:pump(clock.now + 30)
        ck(sim.count.expandAll == at, "the spent ladder kept polling")
        ck(not (Professions._live and Professions._live.p
                and Professions._live.p.blacksmithing),
           "the retry ladder eventually wrote the shortened set")

        -- ══ (9) THE CRAFT SURFACE: same witness one return further along,
        --        same roundtrip, through the Craft expand/collapse pair ═══════
        sim:restore()
        sim = nil
        resetModule()
        local en = Dataset.profRecipes[Dataset.profIdx.enchanting]
        local ccats = {
            { name = "Enchants A", spells = { en[1], en[2], en[3] }, collapsed = true },
            { name = "Enchants B", spells = { en[4], en[5], en[6] } },
        }
        local ccount = { expandAll = 0, collapse = 0, link = 0 }
        local function cvisible()
            local rows = {}
            for c = 1, #ccats do
                local cat = ccats[c]
                rows[#rows + 1] = { kind = "header", name = cat.name, cat = cat }
                if not cat.collapsed then
                    for r = 1, #cat.spells do
                        rows[#rows + 1] = { kind = "recipe",
                                            name = "Ench " .. tostring(cat.spells[r]),
                                            s = cat.spells[r] }
                    end
                end
            end
            return rows
        end
        local csaved = {
            ench = G.CraftIsEnchanting, num = G.GetNumCrafts, info = G.GetCraftInfo,
            link = G.GetCraftRecipeLink, item = G.GetCraftItemLink,
            line = G.GetCraftDisplaySkillLine, cd = G.GetCraftCooldown,
            exp = G.ExpandCraftSkillLine, col = G.CollapseCraftSkillLine,
            unit = G.UnitName, realm = G.GetRealmName, full = G.UnitFullName,
            daseeki = G.Daseeki,
            makeF = G.GetOnlyShowMakeable, upsF = G.GetOnlyShowSkillUps,
        }
        G.GetOnlyShowMakeable = function() return false end
        G.GetOnlyShowSkillUps = function() return false end
        G.CraftIsEnchanting = function() return true end
        G.GetNumCrafts = function() return #cvisible() end
        G.GetCraftInfo = function(i)
            local row = cvisible()[i]
            if not row then return nil end
            if row.kind == "header" then
                -- (name, subSpell, type, numAvailable, isExpanded)
                return row.name, nil, "header", 0, (not row.cat.collapsed)
            end
            return row.name, nil, "optimal", 1, true
        end
        G.GetCraftRecipeLink = function(i)
            ccount.link = ccount.link + 1
            local row = cvisible()[i]
            if not row or row.kind == "header" then return nil end
            return "|cffffd000|Henchant:" .. tostring(row.s) .. "|h[x]|h|r"
        end
        G.GetCraftItemLink = function() return nil end
        G.GetCraftDisplaySkillLine = function() return "Enchanting", 290, 300 end
        G.GetCraftCooldown = function() return nil end
        G.ExpandCraftSkillLine = function(idx)
            if idx == 0 then
                ccount.expandAll = ccount.expandAll + 1
                for c = 1, #ccats do ccats[c].collapsed = nil end
                if Professions._onEvent then Professions._onEvent(nil, "CRAFT_UPDATE") end
            end
        end
        G.CollapseCraftSkillLine = function(idx)
            ccount.collapse = ccount.collapse + 1
            local row = cvisible()[idx]
            if row and row.kind == "header" then row.cat.collapsed = true end
            if Professions._onEvent then Professions._onEvent(nil, "CRAFT_UPDATE") end
        end
        G.UnitName = function() return "CollapseTester" end
        G.GetRealmName = function() return "TestRealm" end
        G.UnitFullName = nil
        G.Daseeki = nil
        Professions.OpenWindow("craft", true)
        ck(Professions.CaptureWindow("craft", true, "CRAFT_SHOW") == true,
           "the collapsed craft window's capture did not land")
        ck(Professions._live and Professions._live.p.enchanting
           and Professions._live.p.enchanting.n == 6,
           "the craft roundtrip wrote "
           .. tostring(Professions._live and Professions._live.p.enchanting
                       and Professions._live.p.enchanting.n)
           .. " known enchants, expected 6")
        ck(ccount.expandAll == 1 and ccount.collapse == 1,
           "the craft roundtrip's calls read expand=" .. ccount.expandAll
           .. " collapse=" .. ccount.collapse .. ", expected 1/1")
        ck(ccats[1].collapsed == true and not ccats[2].collapsed,
           "the craft window's collapse set did not restore exactly")
        G.CraftIsEnchanting, G.GetNumCrafts, G.GetCraftInfo = csaved.ench, csaved.num, csaved.info
        G.GetCraftRecipeLink, G.GetCraftItemLink = csaved.link, csaved.item
        G.GetCraftDisplaySkillLine, G.GetCraftCooldown = csaved.line, csaved.cd
        G.ExpandCraftSkillLine, G.CollapseCraftSkillLine = csaved.exp, csaved.col
        G.UnitName, G.GetRealmName, G.UnitFullName = csaved.unit, csaved.realm, csaved.full
        G.Daseeki = csaved.daseeki
        G.GetOnlyShowMakeable, G.GetOnlyShowSkillUps = csaved.makeF, csaved.upsF
    end)

    if sim then sim:restore() end
    clock:restore()
    ns.ProfessionFilters = savedFilters
    Professions._leavingWorld, Professions._loggingOut = savedState[1], savedState[2]
    Professions._enteredWorldAt, Professions._live = savedState[3], savedState[4]
    Professions._scanAt, Professions._harvested = savedState[5], savedState[6]
    Professions._windowOpen, Professions._retry = savedState[7], savedState[8]
    Professions._stats, Professions._trace = savedState[9], savedState[10]
    Professions._lastSig, Professions._nameMap = savedState[11], savedState[12]
    Professions._recipeNames, Professions._viewGuards = savedState[13], savedState[14]
    Professions._settled, Professions._stale = savedState[15], savedState[16]
    Professions._harvestJob = savedState[17]
    Professions._collapseLatch, Professions._collapseWorld = savedState[18], savedState[19]
    if ns.Store and ns.Store.data then ns.Store.data.professions = savedArea end
    if not ok then fails[#fails + 1] = "error in collapse-honesty fixtures: " .. tostring(err) end
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

----------------------------------------------------------------------
-- SELF-TEST: the registration seam (fix/phantom-event).
--
-- The live defect: `Frame:RegisterEvent(): Attempt to register unknown event
-- "LEARNED_SPELL_IN_TAB"`, 32 occurrences in the owner's BugSack. The name was
-- never in the 11509 registry, and the pcall around it was not the shield its
-- comment claimed. Three things are asserted here, and a fourth (that no name
-- in the list is a phantom AT ALL) is asserted statically by the harness gate
-- eventcheck.lua, which is the only place that can see the catalog.
----------------------------------------------------------------------

local function testEventRegistration(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end

    -- A frame that COUNTS, and can be told to refuse a name the way the client
    -- refuses one. Deliberately not the harness's chainable mock: the point of
    -- this suite is the call count, which the mock cannot report.
    local function fakeFrame(bad)
        local f = { calls = 0, unitCalls = 0, seen = {}, units = {} }
        function f:RegisterEvent(ev)
            self.calls = self.calls + 1
            if bad and bad[ev] then
                error("Frame:RegisterEvent(): Attempt to register unknown event \"" .. ev .. "\"", 0)
            end
            self.seen[ev] = (self.seen[ev] or 0) + 1
        end
        function f:RegisterUnitEvent(ev, unit)
            self.unitCalls = self.unitCalls + 1
            if bad and bad[ev] then
                error("Frame:RegisterUnitEvent(): Attempt to register unknown event \"" .. ev .. "\"", 0)
            end
            self.seen[ev] = (self.seen[ev] or 0) + 1
            self.units[ev] = unit
        end
        return f
    end

    ----------------------------------------------------------------
    -- (a) THE PHANTOM IS GONE, and the signals it shared a line with stayed.
    ----------------------------------------------------------------
    local listed = {}
    for i = 1, #Professions.EVENTS do listed[Professions.EVENTS[i]] = true end
    ck(not listed["LEARNED_SPELL_IN_TAB"],
       "LEARNED_SPELL_IN_TAB is back in Professions.EVENTS - it is not an event on "
       .. "this client and registering it throws into the player's error frame")
    ck(listed["CHAT_MSG_SKILL"] and listed["LEARNED_SPELL_IN_SKILL_LINE"]
       and listed["UNIT_SPELLCAST_SUCCEEDED"],
       "a staleness signal went missing from Professions.EVENTS")

    ----------------------------------------------------------------
    -- (b) ONCE. Two passes over the same list cost exactly one round of calls.
    ----------------------------------------------------------------
    local f = fakeFrame(nil)
    local reg1, already1, refused1 = Professions.RegisterEventList(f, Professions.EVENTS)
    local firstCalls = f.calls + f.unitCalls
    ck(reg1 == #Professions.EVENTS and already1 == 0 and refused1 == 0,
       "the first registration pass did not register the whole list exactly once "
       .. "(got " .. reg1 .. "/" .. already1 .. "/" .. refused1 .. ")")
    ck(firstCalls == #Professions.EVENTS,
       "the first pass made " .. firstCalls .. " client calls for "
       .. #Professions.EVENTS .. " events")
    ck(f.units["UNIT_SPELLCAST_SUCCEEDED"] == "player",
       "the craft-landed hook is no longer unit-filtered to the player")

    local reg2, already2 = Professions.RegisterEventList(f, Professions.EVENTS)
    ck(reg2 == 0 and already2 == #Professions.EVENTS,
       "a second registration pass re-registered " .. reg2 .. " event(s) - "
       .. "registration must happen once per frame, not once per pass")
    ck(f.calls + f.unitCalls == firstCalls,
       "a second pass reached the client " .. (f.calls + f.unitCalls - firstCalls)
       .. " extra time(s); repeated registration is exactly how one bad name "
       .. "became 32 bug reports")
    for ev in pairs(f.seen) do
        ck(f.seen[ev] == 1, "event " .. ev .. " was registered " .. f.seen[ev] .. " times")
    end

    ----------------------------------------------------------------
    -- (c) A REFUSAL IS RECORDED ONCE AND NEVER RE-THROWN. The red control is
    -- the shipped defect itself: a client that refuses a name.
    ----------------------------------------------------------------
    local savedRefused = Professions._refusedEvents
    Professions._refusedEvents = nil
    local ok, err = pcall(function()
        local list = { "CHAT_MSG_SKILL", "LEARNED_SPELL_IN_TAB", "SPELLS_CHANGED" }
        local g = fakeFrame({ LEARNED_SPELL_IN_TAB = true })
        local r, a, x = Professions.RegisterEventList(g, list)
        ck(r == 2 and a == 0 and x == 1,
           "a refused name did not survive its list (got " .. r .. "/" .. a .. "/" .. x .. ")")
        ck(g.seen["CHAT_MSG_SKILL"] == 1 and g.seen["SPELLS_CHANGED"] == 1,
           "a refused name took its neighbours down with it")
        local callsAfterFirst = g.calls
        local r2, a2, x2 = Professions.RegisterEventList(g, list)
        ck(r2 == 0 and a2 == 2 and x2 == 1,
           "the second pass over a list with a refused name did not report "
           .. "2 already-held + 1 refused (got " .. r2 .. "/" .. a2 .. "/" .. x2 .. ")")
        ck(g.calls == callsAfterFirst,
           "the refused name was ATTEMPTED AGAIN on the same frame - that is the "
           .. "32-occurrences bug, restated")
        ck(type(Professions._refusedEvents) == "table"
           and Professions._refusedEvents["LEARNED_SPELL_IN_TAB"] == 1,
           "the refusal ledger did not record the refused name exactly once")
        ck(Professions._refusedEvents["CHAT_MSG_SKILL"] == nil,
           "the refusal ledger blamed an event the client accepted")
    end)
    Professions._refusedEvents = savedRefused
    if not ok then fails[#fails + 1] = "error in refusal fixtures: " .. tostring(err) end

    ----------------------------------------------------------------
    -- (d) STALENESS STILL MARKS on the two signals that remain.
    ----------------------------------------------------------------
    local savedStale, savedSettled = Professions._stale, Professions._settled
    local savedWindow = Professions._windowOpen
    local ok2, err2 = pcall(function()
        Professions._windowOpen = nil

        -- CHAT_MSG_SKILL is unattributable: every SETTLED profession is marked.
        Professions._stale = nil
        Professions._settled = { tailoring = { sig = "x" } }
        Professions._onEvent(nil, "CHAT_MSG_SKILL")
        ck(Professions.IsStale("tailoring") == true,
           "CHAT_MSG_SKILL no longer marks a settled profession stale")

        -- LEARNED_SPELL_IN_SKILL_LINE carries the spell id, so the mark is
        -- surgical: the recipe's OWN profession and nothing else.
        Professions._stale = nil
        Professions._settled = { tailoring = { sig = "x" }, mining = { sig = "y" } }
        if Dataset.LoadCore() then
            local tlIdx = Dataset.profIdx.tailoring
            local spellID = Dataset.profRecipes[tlIdx][1]
            Professions._onEvent(nil, "LEARNED_SPELL_IN_SKILL_LINE", spellID)
            ck(Professions.IsStale("tailoring") == true,
               "LEARNED_SPELL_IN_SKILL_LINE no longer marks the learned recipe's profession")
            ck(Professions.IsStale("mining") == false,
               "LEARNED_SPELL_IN_SKILL_LINE marked a profession the spell id does not name")
        end

        -- An id we do not carry is unattributable, so it marks everything.
        Professions._stale = nil
        Professions._onEvent(nil, "LEARNED_SPELL_IN_SKILL_LINE", 987654321)
        ck(Professions.IsStale("tailoring") and Professions.IsStale("mining"),
           "an unrecognised learn id stopped marking conservatively")
    end)
    Professions._stale, Professions._settled = savedStale, savedSettled
    Professions._windowOpen = savedWindow
    if not ok2 then fails[#fails + 1] = "error in staleness fixtures: " .. tostring(err2) end
end

----------------------------------------------------------------------
-- SELF-TEST: delegate lanes (profession-delegates phase 1) — the resolution
-- walk, and the "delegates" namespace round-trip against the real Sync/Store.
----------------------------------------------------------------------

local function testDelegateLanes(fails)
    local function ck(cond, msg) if not cond then fails[#fails + 1] = msg end end

    -- (a) THE LANE CHAIN, pure: most specific first, "general" always last,
    -- cycles bounded.
    local parentOf = function(id)
        return ({ [17041] = 9787, [17039] = 9787, [17040] = 9787 })[id]
    end
    local function chainStr(c) return table.concat(c, ">") end
    ck(chainStr(Professions.LaneChainFrom(17041, parentOf)) == "17041>9787>general",
       "the Master Axesmith chain does not walk through Weaponsmith")
    ck(chainStr(Professions.LaneChainFrom(9787, parentOf)) == "9787>general",
       "the Weaponsmith chain is wrong")
    ck(chainStr(Professions.LaneChainFrom(nil, parentOf)) == "general",
       "a spec-free recipe's chain is not general-only")
    ck(chainStr(Professions.LaneChainFrom(1, function() return 1 end)) == "1>general",
       "a parent cycle was not bounded")
    -- ...and live, against the shipped FIX-4 edges.
    if Professions.IsEnabled() and Dataset.LoadCore() then
        ck(chainStr(Professions.LaneChain(17041)) == "17041>9787>general",
           "the live Axesmith chain does not match FIX-4")
        ck(chainStr(Professions.LaneChain(9788)) == "9788>general",
           "the live Armorsmith chain grew a parent it does not have")
    end

    -- (b) THE RESOLUTION WALK. Fixture: Poonyx is Armorsmith primary AND
    -- general primary; Puunyx is the (planned) Axesmith primary. One
    -- profession, several primaries — each lane resolves to its own.
    local ARMOR, AXE, WEAPON = "9788", "17041", "9787"
    local cfg = { Horde = { profs = { blacksmithing = { lanes = {
        general = { p = "Poonyx-R", s = "Sec-R" },
        [ARMOR] = { p = "Poonyx-R" },
        [AXE]   = { p = "Puunyx-R" },
    } } } } }
    local R = Professions.ResolveDelegate
    local chainAxe    = { AXE, WEAPON, "general" }
    local chainWeapon = { WEAPON, "general" }
    local chainArmor  = { ARMOR, "general" }
    local chainGen    = { "general" }

    -- a lane with a primary short-circuits (never walks past it)...
    local who, lane = R(cfg, "Horde", "blacksmithing", chainArmor, "p")
    ck(who == "Poonyx-R" and lane == ARMOR, "the armorsmith lane did not short-circuit")
    -- ...the PLANNED axesmith lane resolves to Puunyx (intent, not state)...
    who, lane = R(cfg, "Horde", "blacksmithing", chainAxe, "p")
    ck(who == "Puunyx-R" and lane == AXE, "the planned axesmith primary did not resolve")
    -- ...an EMPTY weaponsmith lane walks up: axe chain minus its own lane
    -- lands on general THROUGH the empty weaponsmith lane...
    local cfg2 = { Horde = { profs = { blacksmithing = { lanes = {
        general = { p = "Poonyx-R" },
    } } } } }
    who, lane = R(cfg2, "Horde", "blacksmithing", chainAxe, "p")
    ck(who == "Poonyx-R" and lane == "general",
       "an axesmith recipe with no lane primaries did not walk to general")
    -- ...a weaponsmith primary catches the axe walk before general...
    local cfg3 = { Horde = { profs = { blacksmithing = { lanes = {
        general  = { p = "Poonyx-R" },
        [WEAPON] = { p = "Weap-R" },
    } } } } }
    who, lane = R(cfg3, "Horde", "blacksmithing", chainAxe, "p")
    ck(who == "Weap-R" and lane == WEAPON,
       "the axe walk did not stop at the weaponsmith primary")
    -- ...and a GENERAL recipe never walks down into spec lanes.
    who, lane = R(cfg3, "Horde", "blacksmithing", chainGen, "p")
    ck(who == "Poonyx-R" and lane == "general", "a general recipe left the general lane")
    who = R({ Horde = { profs = { blacksmithing = { lanes = {
        [WEAPON] = { p = "Weap-R" } } } } } }, "Horde", "blacksmithing", chainGen, "p")
    ck(who == nil, "a general recipe descended into a spec lane")

    -- roles are independent: the secondary resolves separately, and NEVER
    -- from the primary slot.
    who = R(cfg, "Horde", "blacksmithing", chainGen, "s")
    ck(who == "Sec-R", "the secondary role did not resolve")
    who = R(cfg, "Horde", "blacksmithing", chainArmor, "s")
    ck(who == "Sec-R", "the secondary walk did not pass an s-empty lane")

    -- FACTION ISOLATION: a Horde config answers nothing for an Alliance viewer.
    ck(R(cfg, "Alliance", "blacksmithing", chainArmor, "p") == nil,
       "a Horde primary fired for an Alliance viewer")

    -- READ-SIDE HEAL: a designation whose character record vanished is
    -- skipped and the walk CONTINUES; nothing is erased (the cfg keeps it).
    local exists = function(k) return k ~= "Puunyx-R" end
    who, lane = R(cfg, "Horde", "blacksmithing", chainAxe, "p", exists)
    ck(who == "Poonyx-R" and lane == "general",
       "a vanished record did not heal to the next lane")
    ck(cfg.Horde.profs.blacksmithing.lanes[AXE].p == "Puunyx-R",
       "the read-side heal MUTATED the stored designation")

    -- junk shapes answer nil, never error.
    ck(R(nil, "Horde", "x", chainGen, "p") == nil
       and R("junk", "Horde", "x", chainGen, "p") == nil
       and R({ Horde = { profs = 9 } }, "Horde", "x", chainGen, "p") == nil,
       "a malformed config was not healed to nil")

    -- (c) THE NAMESPACE ROUND-TRIP, against the real Sync + Store. The
    -- unknown-namespace old-client leg is pinned in syncns.lua's attune
    -- self-test (ApplyInbound caches ANY key without error); this leg owns
    -- the delegates-specific facts: registration, advertisement, cross-owner
    -- LWW at read time, edit-on-top-of-the-winner, receive-side heal.
    local S = ns.Store
    local Sync = _G and _G.Daseeki and _G.Daseeki.Sync
    if not (S and S.SetDelegate and Sync and Sync.ApplyInbound and S.SyncNS) then
        return   -- headless world without the sync layer: the pure legs stand
    end
    ck(Professions.RegisterDelegatesNamespace() == true,
       "the delegates namespace did not register")
    ck(Sync.AllNamespaceHashes()[DELEGATES_NS_KEY] ~= nil,
       "the delegates namespace is not advertised in the heartbeat hash bundle")

    local a0 = S.ProfessionsArea(false)
    local savedD  = a0 and a0.delegates
    local savedR  = a0 and a0.delegatesRev
    local savedAt = a0 and a0.delegatesAt
    local nsAll = S.SyncNS()
    local savedNS = nsAll[DELEGATES_NS_KEY]
    nsAll[DELEGATES_NS_KEY] = nil
    local a1 = S.ProfessionsArea(true)
    a1.delegates, a1.delegatesRev, a1.delegatesAt = nil, nil, nil

    local okAll, err = pcall(function()
        -- never edited: nothing to publish, nothing effective.
        ck(S.DelegatesSnapshot() == nil, "a never-edited config produced a snapshot")
        ck(S.DelegatesEffective() == nil, "a never-edited config resolved an effective view")

        -- a local edit at t=1000 becomes the effective view and the snapshot.
        ck(S.SetDelegate("Horde", "blacksmithing", "general", "p", "Poonyx-R", 1000) == true,
           "the local edit did not write")
        local eff = S.DelegatesEffective()
        ck(type(eff) == "table"
           and eff.Horde.profs.blacksmithing.lanes.general.p == "Poonyx-R",
           "the local edit is not the effective view")
        local snap = S.DelegatesSnapshot()
        ck(type(snap) == "table" and snap.at == 1000
           and snap.cfg.Horde.profs.blacksmithing.lanes.general.p == "Poonyx-R",
           "the snapshot does not carry the local edit")

        -- a peer's NEWER payload wins the effective view without any write.
        ck(Sync.ApplyInbound(DELEGATES_NS_KEY, "__delegates-peer", 1, {
            v = 1, at = 2000,
            cfg = { Horde = { profs = { blacksmithing = { lanes = {
                general = { p = "Puunyx-R" } } } } } },
        }, 2000) == "applied", "the peer payload did not apply")
        eff = S.DelegatesEffective()
        ck(eff.Horde.profs.blacksmithing.lanes.general.p == "Puunyx-R",
           "the newer peer config did not win the effective view")
        ck(S.Delegates(false).Horde.profs.blacksmithing.lanes.general.p == "Poonyx-R",
           "the peer win MUTATED the local copy outside an edit")

        -- per-owner rev gate: a stale rev is rejected (LWW discipline).
        ck(Sync.ApplyInbound(DELEGATES_NS_KEY, "__delegates-peer", 1, {
            v = 1, at = 9999, cfg = {} }, 2001) == "stale",
           "a stale peer rev was applied")

        -- EDIT-ON-TOP-OF-THE-WINNER: a local edit AFTER the peer win adopts
        -- the peer's config first, so nothing of theirs is reverted.
        ck(S.SetDelegate("Horde", "blacksmithing", "9788", "p", "Armor-R", 3000) == true,
           "the post-win local edit did not write")
        eff = S.DelegatesEffective()
        ck(eff.Horde.profs.blacksmithing.lanes.general.p == "Puunyx-R"
           and eff.Horde.profs.blacksmithing.lanes["9788"].p == "Armor-R",
           "the post-win edit reverted the peer's designations")

        -- receive-side heal: a malformed peer payload contributes nothing.
        ck(Sync.ApplyInbound(DELEGATES_NS_KEY, "__delegates-junk", 1,
            { v = 1, at = 9e9, cfg = "junk" }, 3001) == "applied",
           "a junk payload did not even cache (the transport must not care)")
        eff = S.DelegatesEffective()
        ck(type(eff) == "table"
           and eff.Horde.profs.blacksmithing.lanes["9788"].p == "Armor-R",
           "a malformed peer payload was not healed out of the effective view")

        -- an all-cleared config still publishes (rev survives the clears).
        ck(S.SetDelegate("Horde", "blacksmithing", "general", "p", nil, 4000) == true
           and S.SetDelegate("Horde", "blacksmithing", "9788", "p", nil, 4001) == true,
           "the clears did not write")
        local snap2 = S.DelegatesSnapshot()
        ck(type(snap2) == "table" and snap2.at == 4001,
           "an all-cleared config stopped publishing")
    end)

    S.SyncNSDrop(DELEGATES_NS_KEY, "__delegates-peer")
    S.SyncNSDrop(DELEGATES_NS_KEY, "__delegates-junk")
    nsAll[DELEGATES_NS_KEY] = savedNS
    local a2 = S.ProfessionsArea(true)
    a2.delegates, a2.delegatesRev, a2.delegatesAt = savedD, savedR, savedAt
    if not okAll then fails[#fails + 1] = "error in namespace round-trip: " .. tostring(err) end
end

----------------------------------------------------------------------
-- DATASET MIGRATION  (feat/dataset-migration)
--
-- THE OWNER'S EXACT INCIDENT as the red control: 2026-08-10, the spec-tree
-- addition moved the stamp p1-f84a5fa0 -> p1-4b17878e without touching one
-- recipe, and every character's record went "not checked" — a full re-scan
-- tour of the alts, twice in one day. The old whole-stamp gate is asserted
-- STILL DISCARDING that record (it must — old peers run it forever); the
-- set-hash layer is asserted rescuing the very same bytes.
----------------------------------------------------------------------

local function testDatasetMigration(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    Dataset.LoadCore()
    Dataset.LoadCompat()
    local S = ns.Store
    local INCIDENT_STAMP = "p1-f84a5fa0"

    -- The shipped compat facts: a set hash, and the incident pair recorded.
    ck(type(Dataset.SetHash()) == "string" and Dataset.SetHash():match("^s1%-%x+$") ~= nil,
       "the dataset ships no recipe-set hash")
    local stampSet = Dataset.stampSet or {}
    ck(stampSet[Dataset.Version()] == Dataset.SetHash(),
       "[stampset] does not name the current stamp's set hash")
    ck(stampSet[INCIDENT_STAMP] == Dataset.SetHash(),
       "the incident stamp " .. INCIDENT_STAMP .. " is not recorded as our set - "
       .. "the identity pair f84a5fa0<->4b17878e went missing")

    ----------------------------------------------------------------
    -- LEG 1 — the identity bump (set unchanged, stamp changed)
    ----------------------------------------------------------------
    local tlIdx = Dataset.profIdx.tailoring
    local tlList = Dataset.profRecipes[tlIdx]
    local bits, n = Professions.EncodeKnown("tailoring", { tlList[1], tlList[3] })
    local incident = { v = 1, ds = INCIDENT_STAMP, ts = 100,
        p = { tailoring = { l = 200, m = 300, k = bits, n = n, a = 100 } } }

    -- RED: the old gate discards exactly this record (and must keep doing so —
    -- it is what un-updated peers run against unknown stamps forever).
    ck(Professions.DecodeKnown("tailoring", bits, INCIDENT_STAMP) == nil,
       "RED CONTROL BROKE: the whole-stamp gate no longer refuses a foreign stamp - "
       .. "old peers would decode wrongly")

    -- GREEN: Layer 1 rescues the same bytes with zero migration.
    local st1, skill1 = Professions.KnownState(incident, "tailoring", tlList[1])
    ck(st1 == "known" and skill1 == 200,
       "the incident record's known recipe did not survive the metadata-only bump")
    ck((Professions.KnownState(incident, "tailoring", tlList[2])) == "missing",
       "the incident record's proven-missing recipe did not stay missing")
    local set1, state1, cov1 = Professions.KnownSetFor(incident, "tailoring")
    ck(state1 == "scanned" and set1 and set1[tlList[1]] and set1[tlList[3]] and cov1 == nil,
       "KnownSetFor did not rescue the incident record verbatim (full coverage)")
    local mp1, ch1, verdict1 = Professions.MigratePayload(incident)
    ck(verdict1 == "rescued" and ch1 == true
       and mp1.ds == Dataset.Version() and mp1.sh == Dataset.SetHash()
       and mp1.p.tailoring.k == bits and mp1.p.tailoring.n == n and mp1.p.tailoring.cv == nil,
       "MigratePayload did not rescue the incident record (bitmap must be verbatim)")
    ck(incident.ds == INCIDENT_STAMP and incident.sh == nil,
       "MigratePayload MUTATED its input - the sync store's relay bytes are not safe")

    -- An unknown coordinate system still refuses - never a wrong decode.
    local foreign = { v = 1, ds = "p1-00000000", ts = 100,
        p = { tailoring = { l = 5, m = 300, k = bits, n = n, a = 100 } } }
    ck((Professions.KnownState(foreign, "tailoring", tlList[1])) == "unknown",
       "an unknown stamp decoded instead of refusing")
    local _, chF, verdictF = Professions.MigratePayload(foreign)
    ck(verdictF == "unknown" and chF == false,
       "an unknown coordinate system was 'migrated'")

    ----------------------------------------------------------------
    -- LEG 2 — a genuine set change (simulated migration injected)
    --
    -- Old set: today's tailoring minus current ordinal 5 (so ordinal 5 is an
    -- ADDITION the old scan never saw) plus one phantom recipe at the end
    -- (REMOVED today). Survivors must keep their truth by spell id, the
    -- addition must read UNSCANNED everywhere, the phantom must drop silently.
    ----------------------------------------------------------------
    local nNew = #tlList
    local nOld = nNew
    local simMap = {}
    do
        local newOrd = 0
        for o = 1, nOld - 1 do
            newOrd = newOrd + 1
            if newOrd == 5 then newOrd = newOrd + 1 end
            simMap[o] = newOrd
        end
        simMap[nOld] = 0                          -- the removed phantom
    end
    local SIM_SH = "s1-simold"
    Dataset.migrations[SIM_SH] = { [tlIdx] = { n = nOld, map = simMap } }

    -- Old-coordinate record: knows old ordinals 1, 3 and the phantom.
    local oldBits = Professions.EncodeBits({ [1] = true, [3] = true, [nOld] = true }, nOld)
    local sim = { v = 1, ds = "p1-simstamp", sh = SIM_SH, ts = 100,
        p = { tailoring = { l = 150, m = 300, k = oldBits, n = 3, a = 100 } } }

    local mp2, ch2, verdict2 = Professions.MigratePayload(sim)
    ck(verdict2 == "migrated" and ch2 == true and mp2.ds == Dataset.Version(),
       "a genuine set change with a shipped migration was not translated")
    ck(mp2.p.tailoring.n == 2,
       "survivor count wrong after translation: the removed phantom must drop silently "
       .. "(got " .. tostring(mp2.p.tailoring.n) .. ")")
    ck(type(mp2.p.tailoring.cv) == "string",
       "a migrated record with an addition carries no coverage bitmap")
    do
        local cset, ccount = Professions.DecodeBits(mp2.p.tailoring.cv or "", nNew)
        ck(cset ~= nil and ccount == nNew - 1 and not cset[5],
           "the coverage bitmap does not name exactly the old set (all but ordinal 5)")
    end

    -- Survivors keep their truth by spell id; the addition is UNSCANNED.
    ck((Professions.KnownState(sim, "tailoring", tlList[1])) == "known",
       "a surviving known recipe lost its truth in translation")
    ck((Professions.KnownState(sim, "tailoring", tlList[2])) == "missing",
       "a surviving proven-missing recipe lost its truth in translation")
    ck((Professions.KnownState(sim, "tailoring", tlList[6])) == "missing",
       "a shifted survivor (old ordinal 5 -> new ordinal 6) misclassified")
    ck((Professions.KnownState(sim, "tailoring", tlList[5])) == "unknown",
       "HONESTY BROKE: a recipe the record's scan never saw reads 'missing' - "
       .. "the record predates it and must read unscanned")
    local set2, state2, cov2 = Professions.KnownSetFor(sim, "tailoring")
    ck(state2 == "scanned" and set2 and set2[tlList[1]] and not set2[tlList[5]],
       "KnownSetFor mis-decoded the migrated record")
    ck(type(cov2) == "table" and cov2[tlList[1]] == true and cov2[tlList[5]] == nil,
       "KnownSetFor's coverage does not exclude the addition")

    -- RED: strip the coverage and the addition reads "missing" - the exact lie
    -- the layer exists to prevent (proves the coverage is load-bearing).
    do
        local lie = Professions.CopyPayload(mp2)
        lie.p.tailoring.cv = nil
        ck((Professions.KnownState(lie, "tailoring", tlList[5])) == "missing",
           "RED CONTROL BROKE: without coverage the addition should read missing")
    end

    -- Determinism (class 8): the same translation twice is the same bytes.
    do
        local a1 = Professions.TranslateBits(oldBits, Dataset.migrations[SIM_SH][tlIdx], nNew)
        local a2 = Professions.TranslateBits(oldBits, Dataset.migrations[SIM_SH][tlIdx], nNew)
        ck(a1 == a2 and a1 == mp2.p.tailoring.k, "translation is not deterministic")
    end

    ----------------------------------------------------------------
    -- LEG 3 — wire-additive compatibility, both directions
    ----------------------------------------------------------------
    -- A frozen transcript of the PRE-MIGRATION reader (what un-updated peers
    -- run): gates on the whole stamp, ignores sh/cv entirely.
    local function oldReaderState(payload, profKey, spellID)
        if type(payload) ~= "table" then return "unknown" end
        local p = payload.p and payload.p[profKey]
        if not p then return "unknown" end
        if p.k == nil or p.a == nil then return "unknown" end
        local ids = Professions.DecodeKnown(profKey, p.k, payload.ds)
        if not ids then return "unknown" end
        for i = 1, #ids do if ids[i] == spellID then return "known" end end
        return "missing"
    end
    -- New payload, same dataset build: the old reader decodes it correctly -
    -- sh and cv are invisible to it and change nothing it relies on.
    ck(oldReaderState(mp1, "tailoring", tlList[1]) == "known",
       "an old reader mis-handles a new payload from its own build")
    -- New payload from a FUTURE build: the old reader refuses (renders
    -- unscanned), never decodes wrongly.
    local future = Professions.CopyPayload(mp1)
    future.ds, future.sh = "p1-future0", Dataset.SetHash()
    ck(oldReaderState(future, "tailoring", tlList[1]) == "unknown",
       "an old reader decoded a foreign-build payload instead of refusing")
    -- ...while the NEW reader rescues that same future payload through its sh.
    ck((Professions.KnownState(future, "tailoring", tlList[1])) == "known",
       "the new reader did not rescue a future same-set payload through sh")

    ----------------------------------------------------------------
    -- LEG 4 — mesh receive: migrate on projection, relay bytes untouched
    ----------------------------------------------------------------
    if S and S.ProfessionsGetData and S.ProfessionsDrop and Professions._onRemoteFn then
        Professions._onRemoteFn("__mig-peer", incident)
        local got = S.ProfessionsGetData("__mig-peer")
        ck(type(got) == "table" and got.ds == Dataset.Version()
           and got.sh == Dataset.SetHash() and got.p.tailoring.k == bits,
           "a rescueable peer payload was not migrated on receive")
        ck(incident.ds == INCIDENT_STAMP,
           "receive-time migration mutated the inbound payload table")
        Professions._onRemoteFn("__mig-junk", foreign)
        local got2 = S.ProfessionsGetData("__mig-junk")
        ck(type(got2) == "table" and got2.ds == "p1-00000000",
           "an unknown coordinate system was rewritten on receive instead of stored untouched")
        ck((Professions.KnownState(got2, "tailoring", tlList[1])) == "unknown",
           "the stored unknown-stamp record decodes - the refuse behavior was lost")
        S.ProfessionsDrop("__mig-peer")
        S.ProfessionsDrop("__mig-junk")
    end

    ----------------------------------------------------------------
    -- LEG 5 — SeedFromStore: rescue seeds, unknown strips (republish honesty)
    ----------------------------------------------------------------
    local selfKey = Professions.SelfKey()
    local area = S and S.ProfessionsArea and S.ProfessionsArea(true)
    if area and selfKey ~= "" then
        local savedLive = Professions._live
        local savedEntry = area.owners[selfKey]
        area.owners[selfKey] = { rev = 1, updatedAt = 1, data = incident }
        Professions._live = nil
        Professions.SeedFromStore()
        local L = Professions.Live()
        ck(L.p.tailoring and L.p.tailoring.k == bits and L.p.tailoring.l == 200,
           "a rescueable stored self-record was not seeded")
        area.owners[selfKey] = { rev = 1, updatedAt = 1, data = foreign }
        Professions._live = nil
        Professions.SeedFromStore()
        L = Professions.Live()
        ck(L.p.tailoring and L.p.tailoring.k == nil and L.p.tailoring.l == 5,
           "an unnameable bitmap was seeded into the live record - BuildPayload "
           .. "would republish it under OUR stamp, a wrong decode sent to every peer")
        area.owners[selfKey] = savedEntry
        Professions._live = savedLive
    end

    ----------------------------------------------------------------
    -- LEG 6 — the settled layer: incident stamp stays settled, unknown falls
    ----------------------------------------------------------------
    local settledArea = S and S.ProfessionsSettled and S.ProfessionsSettled(true)
    if settledArea and selfKey ~= "" then
        local savedMine = settledArea[selfKey]
        local savedSettled = Professions._settled
        local rec = { prof = "tailoring", surface = "tradeskill", line = "Tailoring",
            l = 200, m = 300, n = 3, known = 2, names = { "A", "B", "C" },
            rows = { [2] = tlList[1], [3] = tlList[2] }, at = 1,
            ds = INCIDENT_STAMP, build = Professions.ClientBuild() }
        settledArea[selfKey] = { tailoring = rec }
        Professions._settled = nil
        ck(Professions.SettledGet("tailoring") ~= nil,
           "a settled record from the incident stamp was discarded - "
           .. "that IS the re-scan tour, again")
        Professions._settled = nil
        rec.ds = "p1-00000000"
        ck(Professions.SettledGet("tailoring") == nil,
           "a settled record from an unknown stamp was honored")
        settledArea[selfKey] = savedMine
        Professions._settled = savedSettled
    end

    ----------------------------------------------------------------
    -- LEG 7 — the publish path stamps both coordinates, cv rides through
    ----------------------------------------------------------------
    do
        local savedLive = Professions._live
        Professions._live = { p = { tailoring = { l = 150, m = 300, k = mp2.p.tailoring.k,
                                                  n = 2, a = 100, cv = mp2.p.tailoring.cv } },
                              c = {} }
        if Professions.IsEnabled() then
            local pl = Professions.BuildPayload()
            ck(type(pl) == "table" and pl.ds == Dataset.Version() and pl.sh == Dataset.SetHash(),
               "BuildPayload does not stamp both coordinates")
            ck(pl and pl.p.tailoring.cv == mp2.p.tailoring.cv,
               "a migrated record's coverage was dropped on publish - peers would "
               .. "read the addition as missing")
            local withoutCv = Professions.CopyPayload(pl)
            withoutCv.p.tailoring.cv = nil
            ck(Professions.PayloadSignature(pl) ~= Professions.PayloadSignature(withoutCv),
               "the delta detector is blind to coverage")
        end
        Professions._live = savedLive
    end

    Dataset.migrations[SIM_SH] = nil
end

function Professions.RunSelfTests(verbose)
    local suites = {
        { name = "dataset integrity (census + referential + the fixed game facts)",
          fn = testDatasetIntegrity },
        { name = "wire encoding round-trip + payload budget", fn = testEncodingRoundTrip },
        { name = "dataset migration (set-hash validity + ordinal translation, "
              .. "the 2026-08-10 incident as red control)",
          fn = testDatasetMigration },
        { name = "capture honesty gates (class 4/6/7: cold, partial, polarity, cooldown proof)",
          fn = testCaptureHonesty },
        { name = "panel-witnessed presence (the Orn herbalism defect, with the red control)",
          fn = testPanelPresence },
        { name = "reagent harvest (class 4: partial lists are not lists)", fn = testReagentHarvest },
        { name = "composed chain (open -> clears -> deferral -> landing, with the red control)",
          fn = testComposedChain },
        { name = "resolution chain (the live 11509 nil-recipe-link window, with the red control)",
          fn = testResolutionChain },
        { name = "settled-signature budget (warm reopens and sprees by API call count, with the red control)",
          fn = testSettledBudget },
        { name = "collapse honesty (witness, expand-scan-restore, loop killer, blind + no-op worlds, with the red control)",
          fn = testCollapseHonesty },
        { name = "publish delta detector", fn = testPublishDelta },
        { name = "module inertness (off = no frame, no events, no dataset, no SV)",
          fn = testInertness },
        { name = "event registration seam (once per frame, phantom gone, refusal "
              .. "recorded once, staleness still marks)",
          fn = testEventRegistration },
        { name = "delegate lanes (FIX-4 chain walk, multi-primary resolution, "
              .. "faction isolation, read-side heal, namespace round-trip + "
              .. "cross-owner LWW)",
          fn = testDelegateLanes },
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
        local warm, spree = Professions._measuredWarmReopen, Professions._measuredSpree
        if warm and spree then
            ns:Print(string.format(
                "  professions: warm reopen costs %d info + %d num + %d line + %d cooldown"
                .. " reads and 0 links / 0 GetSpellInfo; the pre-fix ten-craft spree cost"
                .. " %d link + %d info reads",
                warm.info or -1, warm.num or -1, warm.line or -1, warm.cd or -1,
                spree.legacyLink or -1, spree.legacyInfo or -1))
        end
    end
    return allPass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("professions", Professions.RunSelfTests)
end
