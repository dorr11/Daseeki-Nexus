-- Daseeki Nexus — inventory.lua  (INVENTORY MODULE, wave W1)
--
-- Cross-account inventory / gold, owned by Nexus. Default ON, user-toggleable,
-- zero-setup for an existing Daseeki-Bags 1.x user.
--
-- Four jobs, in the order they matter:
--
--   CAPTURE   A self-contained per-character aggregate scan — item counts across
--             carried bags + bank + mail + equipped, money, and a mail summary —
--             on the same dirty signals Bags 1.x reacts to. NOTHING here reads
--             Daseeki-Bags: a Nexus-only account gets cross-account gold with
--             Nexus alone.
--
--   STORE     DaseekiNexusData.inventory (additive, schema-versioned) holds the
--             owners graph: ownerKey -> { rev, updatedAt, data }. It is the
--             system of record and the union of three inputs — our own capture,
--             every peer payload the mesh delivered into the namespace store,
--             and the one-time Bags 1.x import.
--
--   SYNC      The namespace key is "bags" and the payload is byte-shaped like
--             the one Daseeki-Bags/core/features/syncBridge.lua has been
--             publishing since the N5 cutover:
--
--               { key, class, race, sex, faction, level,
--                 money, itemCounts = {[itemID]=count}, currency, tracked, ts }
--
--             That is the WIRE CONTRACT and it is frozen here. An un-updated 1.x
--             account consumes our payload with no version gate, and we consume
--             theirs. We add exactly ONE optional field, `mail` (see MAIL
--             SUMMARY below); 1.x's ApplyRemote copies a fixed field list and
--             ignores anything it does not know, so the addition is inert there.
--
--   COEXIST   Two local publishers on one namespace would fight over one owner
--             key. If Daseeki-Bags is loaded AND still carries its SyncBridge
--             publisher module, this account goes CONSUME-ONLY: we import and
--             store, we do not capture and do not publish. Bags owns the wire;
--             we own the graph. Decided once, at login. See EvaluateMode.
--
-- MAIL SUMMARY: mail *attachments* are folded into itemCounts exactly as 1.x
-- does (its BuildSelfSnapshot aggregates player.mail into the same map), so the
-- item side of "mail" is already inside the frozen contract. The additive
-- `mail = { n = <inbox items>, money = <attached copper> }` field carries the
-- summary the contract has no room for. Optional by construction — every reader
-- must tolerate its absence, because a 1.x publisher never sends it.
--
-- TEARDOWN: C_Container / GetMoney / the mail API all read cold during logout
-- and behind a loading screen. tracker.lua learned this the hard way (its latch
-- header is the long version); this is the cheap mirror of the same discipline —
-- one latch, consulted by the single capture entry point, which returns nil
-- rather than letting a cold scan overwrite a warm record.
--
-- Clean-room: no third-party source was read. The wire contract and the legacy
-- cache layout were both taken from OUR OWN Daseeki-Bags repo.

local ADDON, ns = ...

local Inventory = {}
ns.Inventory = Inventory

----------------------------------------------------------------------
-- Constants
----------------------------------------------------------------------

-- The 1.x namespace key. Frozen: changing it forks the mesh.
local NS_KEY = "bags"
Inventory.NS_KEY = NS_KEY

-- The Bags addon folder name. WildAddon-1.1's Lib:NewAddon publishes the addon
-- table at _G[<folder name>], and NewModule stores each module at
-- Addon.<ModuleName> — that is what makes _G["Daseeki-Bags"].SyncBridge a
-- reliable, guarded probe rather than a guess.
local BAGS_ADDON = "Daseeki-Bags"
Inventory.BAGS_ADDON = BAGS_ADDON

local PUBLISH_DEBOUNCE  = 3     -- coalesce rapid local edits before publishing
local INITIAL_PUBLISH   = 6     -- seconds after activation: first capture+publish
local MODE_DELAY        = 2     -- seconds after LOGIN before deciding the mode
local REFRESH_INTERVAL  = 30    -- seconds between namespace -> owners projections
local ENTERING_WORLD_GRACE = 2  -- seconds after PLAYER_ENTERING_WORLD that a scan
                                -- is still treated as cold (mirrors tracker.lua)
local EQUIP_SLOTS       = 19    -- Classic Era paper-doll inventory slots

local EMPTY = {}

----------------------------------------------------------------------
-- Session state
----------------------------------------------------------------------

Inventory._mode        = nil     -- "publish" | "consume" (sticky per session)
Inventory._modeReason  = nil
Inventory._activated   = false
Inventory._dirtyTimer  = nil
Inventory._ticker      = nil
Inventory._bankOpen    = false

-- Teardown latch (see the header).
Inventory._leavingWorld   = false
Inventory._loggingOut     = false
Inventory._enteredWorldAt = nil

----------------------------------------------------------------------
-- Identity
----------------------------------------------------------------------

-- "Name-Realm", realm normalized with whitespace stripped. Byte-identical to
-- the key Bags' SelfKey() produces, or peers would never line up.
function Inventory.SelfNameRealm()
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
    return name or "", realm or ""
end

function Inventory.SelfKey()
    local n, r = Inventory.SelfNameRealm()
    if n == "" then return "" end
    return n .. "-" .. r
end

----------------------------------------------------------------------
-- Enablement
--
-- DEFAULT ON, and ABSENT ALSO MEANS ON. store.lua's defaultSettings() seeds the
-- key true and applyDefaults backfills it onto pre-existing saves, but the nil
-- check below is the belt: a save that somehow never got the default must not
-- read as "disabled".
----------------------------------------------------------------------

function Inventory.IsEnabled()
    local S = ns.Store
    local db = S and S.GetSettings and S.GetSettings()
    if not db then return true end
    if db.inventoryEnabled == nil then return true end
    return db.inventoryEnabled and true or false
end

----------------------------------------------------------------------
-- Teardown latch
----------------------------------------------------------------------

function Inventory.IsTeardown()
    return (Inventory._loggingOut or Inventory._leavingWorld) and true or false
end

function Inventory.SinceEnteringWorld()
    local at = Inventory._enteredWorldAt
    if not at then return math.huge end
    local now = (GetTime and GetTime()) or 0
    local d = now - at
    if d < 0 then return 0 end
    return d
end

-- The single gate every capture consults. False => the APIs are (or may be)
-- cold, so we produce nothing at all rather than an honest-looking empty scan.
function Inventory.CaptureAllowed()
    if Inventory.IsTeardown() then return false end
    if Inventory.SinceEnteringWorld() < ENTERING_WORLD_GRACE then return false end
    return true
end

----------------------------------------------------------------------
-- PURE aggregation core
--
-- Two input shapes, kept explicitly separate rather than sniffed:
--   a slot LIST   { { id = <itemID>, count = <n> }, ... }   (a live scan)
--   a counts MAP  { [itemID] = count, ... }                 (a stored component)
-- Sniffing would have to guess whether {[1]=3} is "3 of item 1" or "slot 1", and
-- guessing wrong silently corrupts a payload.
----------------------------------------------------------------------

function Inventory.FoldSlots(counts, slots)
    if type(slots) ~= "table" then return counts end
    for i = 1, #slots do
        local s = slots[i]
        if type(s) == "table" then
            local id = tonumber(s.id)
            local n  = tonumber(s.count) or 1
            if id and id > 0 and n > 0 then
                counts[id] = (counts[id] or 0) + n
            end
        end
    end
    return counts
end

function Inventory.FoldCounts(counts, map)
    if type(map) ~= "table" then return counts end
    for id, n in pairs(map) do
        id, n = tonumber(id), tonumber(n)
        if id and n and id > 0 and n > 0 then
            counts[id] = (counts[id] or 0) + n
        end
    end
    return counts
end

-- src = { slots = { <list>, ... }, counts = { <map>, ... } }
function Inventory.AggregateCounts(src)
    local out = {}
    if type(src) ~= "table" then return out end
    for _, list in ipairs(src.slots or EMPTY) do Inventory.FoldSlots(out, list) end
    for _, map  in ipairs(src.counts or EMPTY) do Inventory.FoldCounts(out, map) end
    return out
end

-- Drop zero/negative/non-numeric entries. Mutates and returns `t`.
function Inventory.SanitizeCounts(t)
    if type(t) ~= "table" then return {} end
    for id, n in pairs(t) do
        if type(id) ~= "number" or type(n) ~= "number" or n <= 0 then
            t[id] = nil
        end
    end
    return t
end

function Inventory.CopyCounts(src)
    local out = {}
    if type(src) ~= "table" then return out end
    for id, n in pairs(src) do
        id, n = tonumber(id), tonumber(n)
        if id and n and id > 0 and n > 0 then out[id] = n end
    end
    return out
end

----------------------------------------------------------------------
-- Live scanners (every API below is catalog-verified for Classic Era 1.15.9)
----------------------------------------------------------------------

local function numCarriedBags()  return tonumber(_G.NUM_BAG_SLOTS) or 4 end
local function numBankBags()     return tonumber(_G.NUM_BANKBAGSLOTS) or 6 end

local function bagIndex(name, fallback)
    local E = _G.Enum
    local B = E and E.BagIndex
    local v = B and B[name]
    if tonumber(v) then return tonumber(v) end
    return fallback
end

-- Append every occupied slot of one container to `out` as { id, count }.
function Inventory.ScanContainer(bag, out)
    out = out or {}
    if bag == nil then return out end
    local C = _G.C_Container
    if not (C and C.GetContainerNumSlots and C.GetContainerItemID) then return out end
    local okSize, size = pcall(C.GetContainerNumSlots, bag)
    size = (okSize and tonumber(size)) or 0
    for slot = 1, size do
        local okID, id = pcall(C.GetContainerItemID, bag, slot)
        id = okID and tonumber(id) or nil
        if id then
            local n = 1
            if C.GetContainerItemInfo then
                local okI, info = pcall(C.GetContainerItemInfo, bag, slot)
                if okI and type(info) == "table" and tonumber(info.stackCount) then
                    n = tonumber(info.stackCount)
                end
            end
            out[#out + 1] = { id = id, count = n }
        end
    end
    return out
end

-- Backpack + the four carried bags + the keyring.
function Inventory.ScanCarried()
    local out = {}
    local backpack = bagIndex("Backpack", tonumber(_G.BACKPACK_CONTAINER) or 0)
    for bag = backpack, backpack + numCarriedBags() do
        Inventory.ScanContainer(bag, out)
    end
    local keyring = bagIndex("Keyring", tonumber(_G.KEYRING_CONTAINER))
    if keyring then Inventory.ScanContainer(keyring, out) end
    return out
end

-- Only meaningful while the bank frame is open; the caller persists the result.
function Inventory.ScanBank()
    local out = {}
    Inventory.ScanContainer(bagIndex("Bank", tonumber(_G.BANK_CONTAINER) or -1), out)
    local first = numCarriedBags() + 1
    for bag = first, first + numBankBags() - 1 do
        Inventory.ScanContainer(bag, out)
    end
    return out
end

function Inventory.ScanEquipped()
    local out = {}
    if not GetInventoryItemLink then return out end
    for slot = 1, EQUIP_SLOTS do
        local ok, link = pcall(GetInventoryItemLink, "player", slot)
        if ok and link then
            local id = tonumber(tostring(link):match("item:(%d+)"))
            if id then
                local n = 1
                if GetInventoryItemCount then
                    local okC, c = pcall(GetInventoryItemCount, "player", slot)
                    if okC and tonumber(c) and tonumber(c) > 0 then n = tonumber(c) end
                end
                out[#out + 1] = { id = id, count = n }
            end
        end
    end
    return out
end

-- Returns a slot list plus { n = <inbox item rows>, money = <attached copper> }.
-- Only meaningful while the mailbox is open; the caller persists the result.
-- The count is read as GetInboxItem's 4th return, which is what our own Bags
-- Cacher:MAIL_INBOX_UPDATE has used against this client for two releases.
function Inventory.ScanMail()
    local out, summary = {}, { n = 0, money = 0 }
    if not (GetInboxNumItems and GetInboxItemLink) then return out, summary end
    local okN, num = pcall(GetInboxNumItems)
    num = (okN and tonumber(num)) or 0
    local maxAtt = tonumber(_G.ATTACHMENTS_MAX_RECEIVE) or 16
    for i = 1, num do
        if GetInboxHeaderInfo then
            local okH, _, _, _, _, money = pcall(GetInboxHeaderInfo, i)
            if okH and tonumber(money) then summary.money = summary.money + tonumber(money) end
        end
        for j = 1, maxAtt do
            local okL, link = pcall(GetInboxItemLink, i, j)
            if okL and link then
                local id = tonumber(tostring(link):match("item:(%d+)"))
                if id then
                    local n = 1
                    if GetInboxItem then
                        local okI, _, _, _, c = pcall(GetInboxItem, i, j)
                        if okI and tonumber(c) and tonumber(c) > 0 then n = tonumber(c) end
                    end
                    out[#out + 1] = { id = id, count = n }
                    summary.n = summary.n + 1
                end
            end
        end
    end
    return out, summary
end

-- Spendable copper, matching the live path Bags' Owners:GetMoney uses.
function Inventory.ScanMoney()
    if not GetMoney then return 0 end
    local ok, m = pcall(GetMoney)
    m = (ok and tonumber(m)) or 0
    if GetCursorMoney then
        local okC, c = pcall(GetCursorMoney)
        if okC and tonumber(c) then m = m - tonumber(c) end
    end
    if GetPlayerTradeMoney then
        local okT, t = pcall(GetPlayerTradeMoney)
        if okT and tonumber(t) then m = m - tonumber(t) end
    end
    if m < 0 then m = 0 end
    return m
end

----------------------------------------------------------------------
-- Cold components (bank + mail)
--
-- Bank and mail are only readable while their frame is open, so their counts are
-- persisted per character and merged into every payload. This is what makes our
-- itemCounts cover carried+bank the way the 1.x payload does — Bags gets it from
-- its own on-disk bag cache; we keep the aggregate instead of the slot layout,
-- because the aggregate is all the contract carries.
----------------------------------------------------------------------

function Inventory.Parts(create)
    local S = ns.Store
    if not (S and S.InventoryParts) then return nil end
    return S.InventoryParts(Inventory.SelfKey(), create)
end

function Inventory.RefreshBank()
    if not Inventory.IsEnabled() or Inventory._mode == "consume" then return false end
    if not Inventory.CaptureAllowed() then return false end
    local parts = Inventory.Parts(true)
    if not parts then return false end
    local slots = Inventory.ScanBank()
    -- A bank frame open with zero readable slots is a cold read, not an empty
    -- bank: keep the last honest snapshot rather than erasing it.
    if #slots == 0 and next(parts.bank or EMPTY) then return false end
    parts.bank   = Inventory.AggregateCounts({ slots = { slots } })
    parts.bankAt = (time and time()) or 0
    return true
end

function Inventory.RefreshMail()
    if not Inventory.IsEnabled() or Inventory._mode == "consume" then return false end
    if not Inventory.CaptureAllowed() then return false end
    local parts = Inventory.Parts(true)
    if not parts then return false end
    local slots, summary = Inventory.ScanMail()
    parts.mail      = Inventory.AggregateCounts({ slots = { slots } })
    parts.mailN     = summary.n
    parts.mailMoney = summary.money
    parts.mailAt    = (time and time()) or 0
    return true
end

----------------------------------------------------------------------
-- CAPTURE: build the wire payload
--
-- Returns nil — never a partial table — when the world is not safe to read.
-- Sync.MarkDirty treats a nil provide() as "nothing to publish" and leaves the
-- stored payload untouched, so a cold moment costs us one debounce cycle and
-- nothing else.
----------------------------------------------------------------------

function Inventory.BuildPayload(now)
    if not Inventory.IsEnabled() then return nil end
    if not Inventory.CaptureAllowed() then return nil end

    local name, realm = Inventory.SelfNameRealm()
    if name == "" then return nil end

    local parts = Inventory.Parts(true) or EMPTY

    local counts = Inventory.AggregateCounts({
        slots  = { Inventory.ScanCarried(), Inventory.ScanEquipped() },
        counts = { parts.bank, parts.mail },
    })
    Inventory.SanitizeCounts(counts)

    local _, classFile
    if UnitClass then
        local ok, _localized, file = pcall(UnitClass, "player")
        if ok then classFile = file end
    end
    local raceFile
    if UnitRace then
        local ok, _localized, file = pcall(UnitRace, "player")
        if ok then raceFile = file end
    end
    local sex, level, faction
    if UnitSex then local ok, v = pcall(UnitSex, "player"); sex = ok and tonumber(v) or nil end
    if UnitLevel then local ok, v = pcall(UnitLevel, "player"); level = ok and tonumber(v) or nil end
    if UnitFactionGroup then
        local ok, v = pcall(UnitFactionGroup, "player")
        if ok and type(v) == "string" then faction = v end
    end

    return {
        -- ---- the frozen 1.x contract ----
        key        = name .. "-" .. realm,
        class      = classFile,
        race       = raceFile,
        sex        = sex,
        faction    = faction,
        level      = level,
        money      = Inventory.ScanMoney(),
        itemCounts = counts,
        currency   = {},
        ts         = now or (time and time()) or 0,
        -- ---- additive, optional; absent on every 1.x payload ----
        mail       = { n = tonumber(parts.mailN) or 0, money = tonumber(parts.mailMoney) or 0 },
    }
end

----------------------------------------------------------------------
-- Revisions
--
-- Our next rev must clear BOTH stores. The 1.x import can seed the owners graph
-- with a large rev (Bags bumps per edit, so a long-played character arrives at
-- rev 4000), and a fresh capture that came back with a smaller rev would be
-- rejected as stale by our own gate. Taking the max of both and adding one means
-- live capture always wins over an import, which is the correct precedence.
----------------------------------------------------------------------

function Inventory.NextLocalRev(ownerKey)
    local S = ns.Store
    local mine = 0
    if S and S.InventoryGet then
        local e = S.InventoryGet(ownerKey)
        if e and tonumber(e.rev) then mine = tonumber(e.rev) end
    end
    local nsRev = 0
    if S and S.SyncNSGet then
        local e = S.SyncNSGet(NS_KEY, ownerKey)
        if e and tonumber(e.rev) then nsRev = tonumber(e.rev) end
    end
    return (mine > nsRev and mine or nsRev) + 1
end

----------------------------------------------------------------------
-- COEXISTENCE
----------------------------------------------------------------------

-- PURE. probe = {
--   bagsLoaded = bool,          -- C_AddOns.IsAddOnLoaded("Daseeki-Bags")
--   bagsTable  = table|nil,     -- _G["Daseeki-Bags"] (WildAddon publishes it there)
--   nsProvider = bool,          -- a `bags` PROVIDER is registered that is not ours
-- }
-- Returns mode ("consume"|"publish"), reason.
--
-- The decisive marker is the PRESENCE of Bags' SyncBridge module, not whether it
-- reports itself active. An inactive SyncBridge means Bags fell back to its own
-- legacy DBAG mesh — it is still the account's inventory publisher, and Bags
-- 2.0 retires the module outright, which is precisely when we take over. Testing
-- `active` instead would hand us the wire while Bags is still on it.
--
-- AMBIGUITY RESOLVES TO CONSUME-ONLY. The two failure directions are not
-- symmetric: wrongly consuming costs this account nothing (Bags is publishing
-- our character anyway and we still store everything), while wrongly publishing
-- puts two local writers on one owner key and makes each other's revisions
-- stale. So "the addon is loaded but we cannot read its table" is treated as a
-- publisher being present, not absent.
function Inventory.EvaluateMode(probe)
    probe = probe or {}
    if probe.nsProvider then
        return "consume", "a `bags` provider is already registered locally"
    end
    local B = probe.bagsTable
    if type(B) == "table" then
        local SB = rawget(B, "SyncBridge")
        if type(SB) == "table" then
            if SB.active == true then
                return "consume", "Daseeki-Bags SyncBridge is publishing"
            end
            return "consume", "Daseeki-Bags carries its SyncBridge publisher"
        end
        -- The addon table is readable and holds no publisher module: Bags 2.0
        -- has retired it, so the wire is ours.
        return "publish", "Daseeki-Bags is loaded but has no publisher module"
    end
    if probe.bagsLoaded then
        -- Loaded, but its table is unreadable — assume it publishes.
        return "consume", "Daseeki-Bags is loaded but could not be inspected"
    end
    return "publish", "no local inventory publisher"
end

function Inventory.ProbeEnvironment()
    local G = _G or getfenv(0)

    local loaded = false
    local CA = G.C_AddOns
    if CA and CA.IsAddOnLoaded then
        local ok, res = pcall(CA.IsAddOnLoaded, BAGS_ADDON)
        loaded = (ok and res) and true or false
    elseif G.IsAddOnLoaded then
        local ok, res = pcall(G.IsAddOnLoaded, BAGS_ADDON)
        loaded = (ok and res) and true or false
    end

    local B = rawget(G, BAGS_ADDON)

    -- Belt for the braces: if anything already registered a `bags` PROVIDER and
    -- it is not our own provide function, someone else owns the wire.
    local nsProvider = false
    local D = G.Daseeki
    local S = D and D.Sync
    if S and type(S._namespaces) == "table" then
        local spec = S._namespaces[NS_KEY]
        if spec and spec.provide and spec.provide ~= Inventory._provideFn then
            nsProvider = true
        end
    end

    return {
        bagsLoaded = loaded,
        bagsTable  = (type(B) == "table") and B or nil,
        nsProvider = nsProvider,
    }
end

function Inventory.IsConsumeOnly() return Inventory._mode == "consume" end
function Inventory.Mode()          return Inventory._mode, Inventory._modeReason end

----------------------------------------------------------------------
-- PROJECTION: namespace store -> owners graph
--
-- Deliberately NOT dependent on onRemote. In consume-only mode we must not call
-- RegisterNamespace at all — the registry replaces the whole spec, so
-- registering would tear out Bags' provide/onRemote and break the very publisher
-- we just decided to defer to. Scraping the store instead works identically in
-- both modes and needs nothing from anybody.
----------------------------------------------------------------------

function Inventory.ProjectOwner(ownerKey)
    local S = ns.Store
    if not (S and S.SyncNSGet and S.InventoryPut) then return false end
    if type(ownerKey) ~= "string" or ownerKey == "" then return false end
    local e = S.SyncNSGet(NS_KEY, ownerKey)
    if not (e and type(e.data) == "table") then return false end
    return S.InventoryPut(ownerKey, e.rev, e.data, e.updatedAt) == "applied"
end

function Inventory.ProjectAll()
    local S = ns.Store
    if not (S and S.SyncNSAll and S.InventoryPut) then return 0 end
    local n = 0
    for ownerKey, e in pairs(S.SyncNSAll(NS_KEY)) do
        if type(e) == "table" and type(e.data) == "table" then
            if S.InventoryPut(ownerKey, e.rev, e.data, e.updatedAt) == "applied" then
                n = n + 1
            end
        end
    end
    return n
end

-- The gated public entry point (inert when the module is off).
function Inventory.Refresh()
    if not Inventory.IsEnabled() then return 0 end
    return Inventory.ProjectAll()
end

----------------------------------------------------------------------
-- MIGRATION: Daseeki-Bags 1.x -> the owners graph
--
-- READ-ONLY on the Bags globals; they are never written. One-time (sticky flag),
-- and idempotent regardless of the flag because every write goes through the
-- rev gate.
--
-- Source is DaseekiBagsAccount — Bags' OWN-characters store, shaped
--   { account = <account-bank domain>, [realm] = { [charID] = cache } }
-- The literal "account" key is a bank domain, not a realm, and a charID ending
-- in "*" is a guild bank; both are skipped.
--
-- DaseekiBagsSets is NOT read. It holds frame profiles, colors, glow settings and
-- the mesh token — Bags SETTINGS, no owner gold and no counts — and Nexus
-- consumes no Bags settings at all. At most its existence is a presence signal
-- that Bags was once installed; the owners graph is imported from
-- DaseekiBagsAccount alone.
--
-- THE MARKER IS SET ONLY ON A SUCCESSFUL, NON-EMPTY IMPORT. Order matters and
-- the failure is silent: a user who enables Inventory before installing Bags
-- (or on a fresh account whose Bags SavedVariables have not been written yet)
-- would otherwise latch the flag against an absent source and never import
-- anything when the data DOES show up. So an absent or empty source returns
-- BEFORE the marker write and we simply try again next login. Mirrors the house
-- pattern in Daseeki-Conduit's migrate.lua (Migrate.Apply returns early when the
-- source table is absent, leaving the marker clear for a later install).
--
-- Imported alts are NOT written into the namespace store. Only the character we
-- are logged into may publish under its own key; seeding the wire with a stale
-- alt snapshot would masquerade as fresh peer data. Each alt republishes itself
-- the next time it is played, which is exactly the 1.x post-cutover behaviour.
----------------------------------------------------------------------

-- PURE. Fold a Bags 1.x owner cache's RAW slot data into { [itemID] = count }.
-- Slot data is either a NUMBER (a bare itemID, stack of 1) or a STRING
-- "<itemstring>;<count>" (count omitted => 1). Bag containers live under the
-- cache's NUMERIC keys as { items = {...} }; mail and equip are flat slot
-- tables; vault nests its slots under `items`.
function Inventory.AggregateLegacyCache(cache)
    local counts = {}
    if type(cache) ~= "table" then return counts end

    local function fold(bag)
        if type(bag) ~= "table" then return end
        local t = (type(bag.items) == "table") and bag.items or bag
        for slot, data in pairs(t) do
            if tonumber(slot) then
                local id, n
                if type(data) == "number" then
                    id, n = data, 1
                elseif type(data) == "string" then
                    id = tonumber(data:match("%d+"))
                    n  = tonumber(data:match(";(%d+)$")) or 1
                end
                if id and n and id > 0 and n > 0 then
                    counts[id] = (counts[id] or 0) + n
                end
            end
        end
    end

    for k, v in pairs(cache) do
        if tonumber(k) then fold(v) end
    end
    fold(cache.mail)
    fold(cache.equip)
    fold(cache.vault)
    return counts
end

-- PURE. Build { ownerKey -> { rev, updatedAt, data } } from a DaseekiBagsAccount
-- shaped table, plus a stats table for reporting.
function Inventory.BuildMigrationSeed(account, now)
    now = tonumber(now) or 0
    local seed = {}
    local stats = { owners = 0, realms = 0, withCounts = 0, withMoney = 0,
                    skippedGuild = 0, fromMeshMap = 0 }
    if type(account) ~= "table" then return seed, stats end

    for realm, byChar in pairs(account) do
        if type(realm) == "string" and realm ~= "account" and type(byChar) == "table" then
            stats.realms = stats.realms + 1
            for id, cache in pairs(byChar) do
                if type(id) == "string" and id ~= "" and type(cache) == "table" then
                    if id:sub(-1) == "*" then
                        stats.skippedGuild = stats.skippedGuild + 1
                    else
                        local ownerKey = id .. "-" .. realm
                        local mesh = (type(cache.mesh) == "table") and cache.mesh or nil

                        -- Prefer the map 1.x already aggregated; fall back to
                        -- re-folding the raw slots for a character that never
                        -- got a mesh backfill.
                        local counts
                        if mesh and type(mesh.itemCounts) == "table" and next(mesh.itemCounts) then
                            counts = Inventory.CopyCounts(mesh.itemCounts)
                            stats.fromMeshMap = stats.fromMeshMap + 1
                        else
                            counts = Inventory.AggregateLegacyCache(cache)
                        end

                        local currency = {}
                        if type(cache.currency) == "table" then
                            currency = Inventory.CopyCounts(cache.currency)
                        end

                        local ts = tonumber(cache.ts) or (mesh and tonumber(mesh.ts)) or now
                        local payload = {
                            key        = ownerKey,
                            class      = cache.class,
                            race       = cache.race,
                            sex        = tonumber(cache.sex),
                            faction    = cache.faction,
                            level      = tonumber(cache.level),
                            money      = tonumber(cache.money) or 0,
                            itemCounts = counts,
                            currency   = currency,
                            ts         = ts,
                        }
                        seed[ownerKey] = {
                            rev       = (mesh and tonumber(mesh.rev)) or 1,
                            updatedAt = ts,
                            data      = payload,
                        }
                        stats.owners = stats.owners + 1
                        if next(counts) then stats.withCounts = stats.withCounts + 1 end
                        if payload.money > 0 then stats.withMoney = stats.withMoney + 1 end
                    end
                end
            end
        end
    end
    return seed, stats
end

-- Live wrapper. Returns the stats table, or nil when there was nothing to do.
function Inventory.MigrateFromBags(now)
    local S = ns.Store
    if not (S and S.InventoryArea and S.InventoryPut) then return nil end
    local area = S.InventoryArea()
    if not area or area.migrated then return nil end

    now = tonumber(now) or (time and time()) or 0
    local G = _G or getfenv(0)
    local account = (type(G.DaseekiBagsAccount) == "table") and G.DaseekiBagsAccount or nil

    -- Source absent: Bags is not installed (yet). Return WITHOUT setting the
    -- marker so a later Bags install still migrates. Re-checking costs one table
    -- type test per login.
    if not account then return nil end

    local seed, stats = Inventory.BuildMigrationSeed(account, now)

    -- Source present but empty: Bags is installed and has written nothing we can
    -- use. Same reasoning — leave the marker clear and try again next login.
    if stats.owners == 0 then return stats end

    local applied = 0
    for ownerKey, e in pairs(seed) do
        if S.InventoryPut(ownerKey, e.rev, e.data, e.updatedAt) == "applied" then
            applied = applied + 1
        end
    end
    stats.applied = applied

    -- Non-empty source seen and processed: latch. `applied` may be 0 on a re-run
    -- after the flag was cleared — the rev gate rejected everything as stale,
    -- which is still a successful import of data we already hold.
    area.migrated = true

    if applied > 0 and ns.Print then
        ns:Print(string.format(
            "inventory: imported %d character(s) from Daseeki Bags (%d with gold, %d with item counts).",
            applied, stats.withMoney, stats.withCounts))
    end
    return stats
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

-- provide() for the namespace. Held in a local so ProbeEnvironment can tell our
-- own registration apart from a foreign one.
local function provideSelf()
    return Inventory.BuildPayload()
end
Inventory._provideFn = provideSelf

local function onRemoteOwner(ownerKey, data)
    local S = ns.Store
    if not (S and S.InventoryPut) then return end
    if type(ownerKey) ~= "string" or ownerKey == "" or type(data) ~= "table" then return end
    local e = S.SyncNSGet and S.SyncNSGet(NS_KEY, ownerKey)
    local rev = (e and tonumber(e.rev)) or 0
    local at  = (e and tonumber(e.updatedAt)) or (time and time()) or 0
    S.InventoryPut(ownerKey, rev, data, at)
end

function Inventory.RegisterNamespace()
    local S = suiteSync()
    if not S then return false end
    S.RegisterNamespace(NS_KEY, {
        ownerKey = function() return Inventory.SelfKey() end,
        provide  = provideSelf,
        rev      = function() return Inventory.NextLocalRev(Inventory.SelfKey()) end,
        onRemote = onRemoteOwner,
    })
    return true
end

-- Capture + publish + mirror into the owners graph. Returns true when a fresh
-- payload was stored.
function Inventory.Publish()
    if not Inventory.IsEnabled() then return false end
    if Inventory._mode == "consume" then return false end
    if not Inventory.CaptureAllowed() then return false end
    local S = suiteSync()
    if not S then return false end
    if S.MarkDirty(NS_KEY) ~= true then return false end
    Inventory.ProjectOwner(Inventory.SelfKey())
    return true
end

-- Debounced publish, driven by the dirty signals.
function Inventory.MarkDirty()
    if not Inventory.IsEnabled() then return false end
    if Inventory._mode == "consume" then return false end
    if not C_Timer or not C_Timer.NewTimer then return false end
    if Inventory._dirtyTimer then
        pcall(function() Inventory._dirtyTimer:Cancel() end)
        Inventory._dirtyTimer = nil
    end
    Inventory._dirtyTimer = C_Timer.NewTimer(PUBLISH_DEBOUNCE, function()
        Inventory._dirtyTimer = nil
        if not Inventory.Publish() then
            -- A cold or teardown moment: try once more after the grace expires
            -- rather than dropping the edit on the floor.
            if not Inventory.IsTeardown() and Inventory.IsEnabled()
               and Inventory._mode ~= "consume" then
                Inventory.MarkDirty()
            end
        end
    end)
    return true
end

----------------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------------

local function stopTimers()
    if Inventory._dirtyTimer then
        pcall(function() Inventory._dirtyTimer:Cancel() end)
        Inventory._dirtyTimer = nil
    end
    if Inventory._ticker then
        pcall(function() Inventory._ticker:Cancel() end)
        Inventory._ticker = nil
    end
end

local function startTicker()
    if Inventory._ticker then return end
    if not (C_Timer and C_Timer.NewTicker) then return end
    Inventory._ticker = C_Timer.NewTicker(REFRESH_INTERVAL, function()
        if not Inventory.IsEnabled() then return end
        Inventory.ProjectAll()
    end)
end

-- Decide the mode, run the one-time import, wire the namespace, project, and
-- schedule the first publish. Runs once per session.
function Inventory.Activate()
    if Inventory._activated then return end
    if not Inventory.IsEnabled() then return end
    Inventory._activated = true

    local mode, reason = Inventory.EvaluateMode(Inventory.ProbeEnvironment())
    Inventory._mode, Inventory._modeReason = mode, reason

    -- First-enable import, in BOTH modes: the graph is ours either way.
    Inventory.MigrateFromBags()

    if mode == "publish" then
        Inventory.RegisterNamespace()
    end

    Inventory.ProjectAll()
    startTicker()

    if mode == "publish" and C_Timer and C_Timer.After then
        C_Timer.After(INITIAL_PUBLISH, function()
            if Inventory.IsEnabled() and Inventory._mode == "publish" then
                Inventory.Publish()
            end
        end)
    end
end

-- The settings toggle. Disabling makes the module fully inert: timers and the
-- ticker are cancelled, and every entry point short-circuits on IsEnabled().
function Inventory.SetEnabled(on)
    local S = ns.Store
    local db = S and S.GetSettings and S.GetSettings()
    if db then db.inventoryEnabled = on and true or false end
    if on then
        if Inventory._activated then
            startTicker()
            Inventory.ProjectAll()
            Inventory.MarkDirty()
        elseif ns.state and ns.state.loggedIn then
            Inventory.Activate()
        end
    else
        stopTimers()
    end
    return Inventory.IsEnabled()
end

----------------------------------------------------------------------
-- Event wiring
--
-- Handlers are registered once at load (ns:RegisterEvent has no unregister) and
-- every one of them opens with the enablement gate, so a disabled module costs a
-- single boolean test per event and does nothing else.
----------------------------------------------------------------------

ns:RegisterEvent("PLAYER_ENTERING_WORLD", function()
    Inventory._leavingWorld   = false
    Inventory._enteredWorldAt = (GetTime and GetTime()) or 0
end)

ns:RegisterEvent("PLAYER_LEAVING_WORLD", function()
    Inventory._leavingWorld = true
end)

ns:RegisterEvent("PLAYER_LOGOUT", function()
    Inventory._loggingOut = true
    stopTimers()
end)

-- Dirty signals — the same set the 1.x publisher reacts to.
local function dirty()
    if not Inventory.IsEnabled() then return end
    Inventory.MarkDirty()
end

ns:RegisterEvent("BAG_UPDATE_DELAYED", function()
    if not Inventory.IsEnabled() then return end
    if Inventory._bankOpen then Inventory.RefreshBank() end
    Inventory.MarkDirty()
end)
ns:RegisterEvent("PLAYER_MONEY", dirty)
ns:RegisterEvent("PLAYER_EQUIPMENT_CHANGED", dirty)

ns:RegisterEvent("BANKFRAME_OPENED", function()
    Inventory._bankOpen = true
    if not Inventory.IsEnabled() then return end
    Inventory.RefreshBank()
    Inventory.MarkDirty()
end)
ns:RegisterEvent("PLAYERBANKSLOTS_CHANGED", function()
    if not Inventory.IsEnabled() or not Inventory._bankOpen then return end
    Inventory.RefreshBank()
    Inventory.MarkDirty()
end)
ns:RegisterEvent("BANKFRAME_CLOSED", function()
    if Inventory.IsEnabled() then
        Inventory.RefreshBank()   -- the slots are still warm on the close frame
        Inventory.MarkDirty()
    end
    Inventory._bankOpen = false
end)

ns:RegisterEvent("MAIL_INBOX_UPDATE", function()
    if not Inventory.IsEnabled() then return end
    Inventory.RefreshMail()
    Inventory.MarkDirty()
end)
ns:RegisterEvent("MAIL_CLOSED", function()
    if not Inventory.IsEnabled() then return end
    Inventory.RefreshMail()
    Inventory.MarkDirty()
end)

-- Mode is decided once, a short beat after login: Bags' modules load on
-- PLAYER_LOGIN (WildAddon defers OnLoad to that event), so probing inside our
-- own PLAYER_LOGIN handler could read the registry before Bags has touched it.
ns:On("LOGIN", function()
    if not Inventory.IsEnabled() then return end
    if C_Timer and C_Timer.After then
        C_Timer.After(MODE_DELAY, function() Inventory.Activate() end)
    else
        Inventory.Activate()
    end
end)

----------------------------------------------------------------------
-- Diagnostics
----------------------------------------------------------------------

ns:RegisterDebugCommand("inventory", function()
    local S = ns.Store
    local area = S and S.InventoryArea and S.InventoryArea()
    local owners, withMoney, gold = 0, 0, 0
    if area then
        for _, e in pairs(area.owners or EMPTY) do
            owners = owners + 1
            local m = e.data and tonumber(e.data.money) or 0
            if m > 0 then withMoney = withMoney + 1; gold = gold + m end
        end
    end
    ns:Print(string.format("inventory: %s | mode=%s (%s) | owners=%d | with gold=%d | total=%dg",
        Inventory.IsEnabled() and "enabled" or "disabled",
        tostring(Inventory._mode or "not yet decided"),
        tostring(Inventory._modeReason or "-"),
        owners, withMoney, math.floor(gold / 10000)))
    ns:Print(string.format("  migrated=%s activated=%s ticker=%s",
        tostring(area and area.migrated), tostring(Inventory._activated),
        Inventory._ticker and "running" or "stopped"))
end)

----------------------------------------------------------------------
-- Self-tests
----------------------------------------------------------------------

local function selfTest(verbose)
    local pass = true
    local function ck(name, cond)
        if not cond then
            pass = false
            if verbose and ns.Print then ns:Print("  FAIL inventory/" .. name) end
        end
    end

    local S = ns.Store
    if not (S and S.InventoryArea and S.SyncNSPut) then
        if verbose and ns.Print then ns:Print("  inventory selftest SKIP (store unavailable)") end
        return true
    end

    -- Isolate: run against a scratch owners graph and a scratch namespace, and
    -- put the real ones back at the end.
    local area = S.InventoryArea()
    local savedOwners, savedMigrated = area.owners, area.migrated
    local savedMode, savedActivated  = Inventory._mode, Inventory._activated
    local savedEntered, savedLeaving = Inventory._enteredWorldAt, Inventory._leavingWorld
    local savedNS = S.SyncNS()[NS_KEY]
    local db = S.GetSettings and S.GetSettings()
    local savedEnabled = db and db.inventoryEnabled

    area.owners   = {}
    area.migrated = false
    S.SyncNS()[NS_KEY] = {}
    Inventory._mode, Inventory._activated = nil, false
    Inventory._leavingWorld, Inventory._loggingOut = false, false
    Inventory._enteredWorldAt = nil    -- math.huge since EW => not in grace
    if db then db.inventoryEnabled = true end

    ------------------------------------------------------------------
    -- 1) CAPTURE AGGREGATE FIXTURE
    --    Carried + equipped slot lists and stored bank + mail counts fold into
    --    one flat map; duplicates across sources sum, junk is dropped.
    ------------------------------------------------------------------
    local agg = Inventory.AggregateCounts({
        slots = {
            { { id = 6948, count = 1 }, { id = 4306, count = 20 }, { id = 4306, count = 12 } },
            { { id = 7005, count = 1 } },                       -- equipped
        },
        counts = {
            { [4306] = 200, [12811] = 4 },                      -- bank
            { [4306] = 5,   [6948]  = 1 },                      -- mail
        },
    })
    ck("aggregate sums one item across all four sources", agg[4306] == 237)
    ck("aggregate sums a duplicate within one source",    agg[6948] == 2)
    ck("aggregate keeps a bank-only item",                agg[12811] == 4)
    ck("aggregate keeps an equipped item",                agg[7005] == 1)

    local junk = Inventory.AggregateCounts({
        slots  = { { { id = 100, count = 0 }, { id = 0, count = 5 }, { count = 3 }, "nope" } },
        counts = { { [200] = -1, ["x"] = 5, [201] = 2 } },
    })
    ck("aggregate drops zero counts",       junk[100] == nil)
    ck("aggregate drops itemID 0",          junk[0] == nil)
    ck("aggregate drops idless slots",      junk[nil] == nil)
    ck("aggregate drops negative counts",   junk[200] == nil)
    ck("aggregate drops non-numeric keys",  junk["x"] == nil)
    ck("aggregate keeps the one good entry", junk[201] == 2)
    ck("aggregate survives a nil source",   type(Inventory.AggregateCounts(nil)) == "table")

    ------------------------------------------------------------------
    -- 2) 1.x PAYLOAD ROUND-TRIP
    --    A byte-shaped payload from an un-updated 1.x publisher — exactly the
    --    field set Bags' BuildSelfSnapshot ships, no more — arrives over the
    --    mesh and lands in our owners graph with every field intact.
    ------------------------------------------------------------------
    local legacyPayload = {
        key        = "Legacy-Whitemane",
        class      = "WARLOCK",
        race       = "Scourge",
        sex        = 2,
        faction    = "Horde",
        level      = 60,
        money      = 123456789,
        itemCounts = { [6948] = 1, [4306] = 240, [12811] = 4 },
        currency   = {},
        tracked    = nil,
        ts         = 1700000123,
    }
    local Sync = _G.Daseeki and _G.Daseeki.Sync
    ck("Daseeki.Sync present for the round-trip", type(Sync) == "table")
    if Sync then
        ck("1.x payload applies inbound",
            Sync.ApplyInbound(NS_KEY, "Legacy-Whitemane", 7, legacyPayload, 1700000123) == "applied")
    end
    ck("round-trip projected into the owners graph", Inventory.ProjectAll() >= 1)

    local got = S.InventoryGet("Legacy-Whitemane")
    ck("round-trip owner present", got ~= nil and type(got.data) == "table")
    if got then
        local d = got.data
        ck("round-trip rev preserved",     got.rev == 7)
        ck("round-trip key preserved",     d.key == "Legacy-Whitemane")
        ck("round-trip class preserved",   d.class == "WARLOCK")
        ck("round-trip race preserved",    d.race == "Scourge")
        ck("round-trip sex preserved",     d.sex == 2)
        ck("round-trip faction preserved", d.faction == "Horde")
        ck("round-trip level preserved",   d.level == 60)
        ck("round-trip money preserved",   d.money == 123456789)
        ck("round-trip ts preserved",      d.ts == 1700000123)
        ck("round-trip counts preserved",
            d.itemCounts[6948] == 1 and d.itemCounts[4306] == 240 and d.itemCounts[12811] == 4)
        ck("round-trip tolerates the absent additive mail field", d.mail == nil)
    end

    -- A second projection of unchanged data is a no-op (rev gate holds).
    ck("re-projection of unchanged data applies nothing", Inventory.ProjectAll() == 0)

    -- Our own payload keeps the same field names the 1.x consumer reads.
    Inventory._enteredWorldAt = nil
    local mine = Inventory.BuildPayload(1700000500)
    ck("BuildPayload produced a payload", type(mine) == "table")
    if type(mine) == "table" then
        ck("payload carries key",        type(mine.key) == "string" and mine.key ~= "")
        ck("payload carries itemCounts", type(mine.itemCounts) == "table")
        ck("payload carries currency",   type(mine.currency) == "table")
        ck("payload carries money",      type(mine.money) == "number")
        ck("payload carries ts",         mine.ts == 1700000500)
        ck("payload carries the additive mail summary",
            type(mine.mail) == "table" and type(mine.mail.n) == "number"
            and type(mine.mail.money) == "number")
    end

    ------------------------------------------------------------------
    -- 3) COEXISTENCE MATRIX
    ------------------------------------------------------------------
    local m, why = Inventory.EvaluateMode({ bagsLoaded = false })
    ck("no Bags -> publish", m == "publish")
    ck("no Bags -> reason given", type(why) == "string" and why ~= "")

    m = Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = { SyncBridge = { active = true } } })
    ck("Bags publisher ACTIVE -> consume-only", m == "consume")

    m = Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = { SyncBridge = { active = false } } })
    ck("Bags publisher present but on its legacy mesh -> still consume-only", m == "consume")

    m = Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = { SyncBridge = {} } })
    ck("Bags publisher present, state unknown -> consume-only", m == "consume")

    m = Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = { Owners = {} } })
    ck("Bags 2.0 (publisher retired) -> we publish", m == "publish")

    -- Ambiguity resolves to the safe direction.
    m = Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = nil })
    ck("Bags loaded but its table is unreadable -> consume-only (safe default)", m == "consume")

    m = Inventory.EvaluateMode({ bagsLoaded = false, bagsTable = { SyncBridge = { active = true } } })
    ck("publisher table present even without the loaded flag -> consume-only", m == "consume")

    m = Inventory.EvaluateMode({ bagsLoaded = false, nsProvider = true })
    ck("a foreign `bags` provider -> consume-only regardless of Bags", m == "consume")

    ck("EvaluateMode survives a nil probe", Inventory.EvaluateMode(nil) == "publish")

    -- Consume-only really does not publish, and never registers (which would
    -- replace the other publisher's spec).
    Inventory._mode = "consume"
    ck("consume-only refuses to publish", Inventory.Publish() == false)
    ck("consume-only refuses to mark dirty", Inventory.MarkDirty() == false)
    ck("consume-only still projects", type(Inventory.Refresh()) == "number")
    Inventory._mode = "publish"

    ------------------------------------------------------------------
    -- 4) MIGRATION — idempotence + rev-awareness, on the owner's real shape
    --    (multi-realm DaseekiBagsAccount, an "account" bank domain, a guild
    --    bank owner, mesh-backfilled alts and raw-slot-only alts).
    ------------------------------------------------------------------
    local legacyAccount = {
        account = { [1] = { items = { "99999;5" } } },     -- bank domain, not a realm
        Whitemane = {
            ["Guildy*"] = { money = 999, [1] = { items = { "12345;3" } } },  -- guild bank
            Rich = {
                money = 500000, class = "MAGE", race = "Gnome", sex = 2,
                faction = "Alliance", level = 60,
                mesh = { rev = 42, itemCounts = { [6948] = 1, [4306] = 100 }, ts = 1700000000 },
            },
            Raw = {
                money = 250, class = "ROGUE", race = "Human", sex = 3,
                faction = "Alliance", level = 34,
                [0] = { items = { [1] = "6948", [2] = "4306;20" } },
                [1] = { items = { [1] = "4306;20" } },
                mail = { [1] = "12811;2" },
                equip = { [16] = "7005" },
                vault = { items = { [1] = 6948 } },
            },
        },
        Faerlina = {
            Alt = { money = 77, class = "PRIEST", level = 12,
                    mesh = { rev = 3, itemCounts = { [159] = 6 }, ts = 1699999999 } },
        },
    }

    local seed, mstats = Inventory.BuildMigrationSeed(legacyAccount, 1700000900)
    ck("migration skipped the account bank domain", seed["1-account"] == nil)
    ck("migration skipped the guild bank",          mstats.skippedGuild == 1)
    ck("migration found both realms",               mstats.realms == 2)
    ck("migration produced 3 character owners",     mstats.owners == 3)
    ck("migration keyed owners Name-Realm",         seed["Rich-Whitemane"] ~= nil
                                                    and seed["Alt-Faerlina"] ~= nil)
    ck("migration carried gold",                    seed["Rich-Whitemane"].data.money == 500000)
    ck("migration carried identity",                seed["Rich-Whitemane"].data.class == "MAGE"
                                                    and seed["Rich-Whitemane"].data.faction == "Alliance")
    ck("migration took the 1.x aggregated map when present",
        seed["Rich-Whitemane"].data.itemCounts[4306] == 100 and mstats.fromMeshMap == 2)
    ck("migration carried the legacy rev",          seed["Rich-Whitemane"].rev == 42)

    -- The raw-slot character has no mesh map, so its counts come from re-folding
    -- bags + mail + equip + vault.
    local rawCounts = seed["Raw-Whitemane"].data.itemCounts
    ck("raw fold summed a stacked item across two bags", rawCounts[4306] == 40)
    ck("raw fold counted a bare itemID string as 1",     rawCounts[6948] == 2)  -- bag + vault
    ck("raw fold picked up mail attachments",            rawCounts[12811] == 2)
    ck("raw fold picked up equipped items",              rawCounts[7005] == 1)
    ck("raw-slot character defaults to rev 1",           seed["Raw-Whitemane"].rev == 1)

    -- Apply, then re-apply: idempotent.
    local firstApplied = 0
    for k, e in pairs(seed) do
        if S.InventoryPut(k, e.rev, e.data, e.updatedAt) == "applied" then
            firstApplied = firstApplied + 1
        end
    end
    ck("first import applied all 3 owners", firstApplied == 3)

    local secondApplied = 0
    for k, e in pairs(seed) do
        if S.InventoryPut(k, e.rev, e.data, e.updatedAt) == "applied" then
            secondApplied = secondApplied + 1
        end
    end
    ck("re-import is idempotent (nothing re-applied)", secondApplied == 0)

    -- Rev-awareness: a STALE import must never clobber fresher live data.
    ck("live rev 99 applies over the imported rev 42",
        S.InventoryPut("Rich-Whitemane", 99, { key = "Rich-Whitemane", money = 987654 }, 1700001000) == "applied")
    ck("stale rev 42 import is rejected",
        S.InventoryPut("Rich-Whitemane", 42, { key = "Rich-Whitemane", money = 1 }, 1700001100) == "stale")
    ck("the fresher live money survived the stale import",
        S.InventoryGet("Rich-Whitemane").data.money == 987654)
    ck("equal rev with an older stamp is rejected",
        S.InventoryPut("Rich-Whitemane", 99, { money = 2 }, 1700000999) == "stale")
    ck("equal rev with a newer stamp wins",
        S.InventoryPut("Rich-Whitemane", 99, { key = "Rich-Whitemane", money = 3 }, 1700001200) == "applied")

    -- Our next local rev clears BOTH stores, so a live capture always beats a
    -- large imported rev.
    S.SyncNSPut(NS_KEY, "Rich-Whitemane", 5, { money = 0 }, 1700001000)
    ck("NextLocalRev clears the higher of the two stores",
        Inventory.NextLocalRev("Rich-Whitemane") == 100)

    -- The sticky flag stops a second scan.
    area.migrated = true
    ck("sticky flag short-circuits a re-run", Inventory.MigrateFromBags(1700002000) == nil)

    ------------------------------------------------------------------
    -- 4b) DEFERRED INSTALL — the marker must NOT latch against an absent or
    --     empty source, or a user who enables Inventory before installing Bags
    --     never imports anything.
    --
    --     Doubles as the E-18 coverage for this path (ROLLOUT_CONTINUITY_AUDIT
    --     rule 18: no "uninstall the old addon" message before a non-zero
    --     applied count). Here the whole chat line is gated on applied > 0, so
    --     the assertion is that a no-op migration is SILENT — a user who has
    --     not yet installed Bags must not be told their bags "imported", and
    --     nothing on any branch may nudge them toward removing the source.
    ------------------------------------------------------------------
    local G = _G
    local savedAccount = G.DaseekiBagsAccount
    area.owners, area.migrated = {}, false

    local REMOVAL_TOKENS = {
        "uninstall", "disable it", "can disable", "safe to remove",
        "no longer need", "turn it off", "delete the addon", "remove it",
    }
    local function hintsRemoval(lines)
        for i = 1, #lines do
            local low = tostring(lines[i]):lower()
            for j = 1, #REMOVAL_TOKENS do
                if low:find(REMOVAL_TOKENS[j], 1, true) then return true end
            end
        end
        return false
    end
    ck("E-18 detector sees a removal hint when one is present",
        hintsRemoval({ "inventory: done -- you can disable it now." }))
    ck("E-18 detector does not fire on the real import line",
        not hintsRemoval({ "inventory: imported 3 character(s) from Daseeki Bags (3 with gold, 3 with item counts)." }))

    -- Capture chat, but let this suite's own failure lines through so a
    -- regression is still visible in the harness output.
    local savedPrint = ns.Print
    local said = {}
    ns.Print = function(self, msg)
        local s = tostring(msg)
        if s:find("FAIL inventory/", 1, true) then return savedPrint(self, msg) end
        said[#said + 1] = s
    end

    -- (a) Enabled with no Bags data present at all.
    G.DaseekiBagsAccount = nil
    said = {}
    ck("absent source imports nothing", Inventory.MigrateFromBags(1700003000) == nil)
    ck("absent source leaves the marker CLEAR", area.migrated == false)
    ck("E-18: an absent source says NOTHING in chat", #said == 0)

    -- (b) Bags installed but its SavedVariables carry no owners yet.
    G.DaseekiBagsAccount = { account = {} }
    said = {}
    local emptyStats = Inventory.MigrateFromBags(1700003100)
    ck("empty source found no owners", emptyStats ~= nil and emptyStats.owners == 0)
    ck("empty source leaves the marker CLEAR", area.migrated == false)
    ck("empty source imported nothing", next(area.owners) == nil)
    ck("E-18: an empty source says NOTHING in chat", #said == 0)

    -- (c) Bags installed later / its data finally appears — the import still
    --     runs and lands, and only now does the marker latch.
    G.DaseekiBagsAccount = legacyAccount
    said = {}
    local lateStats = Inventory.MigrateFromBags(1700003200)
    ck("late install imported the owners", lateStats ~= nil and lateStats.applied == 3)
    ck("late install latched the marker", area.migrated == true)
    ck("late install landed real data in the graph",
        S.InventoryGet("Rich-Whitemane") ~= nil
        and S.InventoryGet("Rich-Whitemane").data.money == 500000)
    ck("late install skipped the guild bank", S.InventoryGet("Guildy*-Whitemane") == nil)
    -- E-18: only NOW, behind a non-zero applied count, is anything said at all.
    ck("E-18: a non-zero applied count DOES announce itself, once", #said == 1)
    ck("E-18: the announcement names the count it actually applied",
        said[1] ~= nil and said[1]:find("imported 3 character", 1, true) ~= nil)
    ck("E-18: even the earned announcement carries no uninstall language",
        not hintsRemoval(said))

    -- (d) ...and does not run twice.
    said = {}
    ck("latched marker blocks a re-run", Inventory.MigrateFromBags(1700003300) == nil)
    ck("E-18: the blocked re-run says NOTHING in chat", #said == 0)

    -- (e) The E-18 gate proper: a source that is present and NON-EMPTY but
    --     whose every record is stale against what we already hold. This is the
    --     re-scan-after-a-cleared-flag case the migrator documents. It latches
    --     the marker (the source WAS processed) with applied = 0 -- and a run
    --     that moved nothing must not tell the user it imported anything.
    --     Its owner carries a fixed mesh rev+ts, so the second pass is stale by
    --     construction rather than by clock luck.
    local frozenSource = {
        Whitemane = {
            Frozen = { money = 4242, class = "DRUID", level = 60,
                       mesh = { rev = 7, itemCounts = { [858] = 5 }, ts = 1700004000 } },
        },
    }
    G.DaseekiBagsAccount = frozenSource
    area.migrated = false
    said = {}
    local frozenFirst = Inventory.MigrateFromBags(1700004100)
    ck("unchanged-source fixture lands on its first pass",
        frozenFirst ~= nil and frozenFirst.applied == 1)
    ck("E-18: that first, real import DOES announce itself", #said == 1)

    area.migrated = false           -- as if the flag were cleared / reset
    said = {}
    local frozenAgain = Inventory.MigrateFromBags(1700004200)
    ck("re-scan of an unchanged source applies nothing",
        frozenAgain ~= nil and frozenAgain.owners == 1 and frozenAgain.applied == 0)
    ck("E-18: a ZERO-applied re-scan says NOTHING in chat", #said == 0)
    ck("re-scan still latches the marker on a non-empty source", area.migrated == true)

    ns.Print = savedPrint
    G.DaseekiBagsAccount = savedAccount

    -- Malformed sources are inert.
    local s2, st2 = Inventory.BuildMigrationSeed(nil, 1)
    ck("nil account yields an empty seed", next(s2) == nil and st2.owners == 0)
    local s3, st3 = Inventory.BuildMigrationSeed({ Realm = { Char = "not a table" } }, 1)
    ck("non-table cache is skipped", next(s3) == nil and st3.owners == 0)

    ------------------------------------------------------------------
    -- 5) TOGGLE INERTNESS
    ------------------------------------------------------------------
    ck("enabled by default", Inventory.IsEnabled() == true)
    if db then
        db.inventoryEnabled = nil
        ck("absent setting reads as ON", Inventory.IsEnabled() == true)
    end

    Inventory.SetEnabled(false)
    ck("SetEnabled(false) disables",           Inventory.IsEnabled() == false)
    ck("disabled: no debounce timer",          Inventory._dirtyTimer == nil)
    ck("disabled: no refresh ticker",          Inventory._ticker == nil)
    ck("disabled: MarkDirty is inert",         Inventory.MarkDirty() == false)
    ck("disabled: Publish is inert",           Inventory.Publish() == false)
    ck("disabled: Refresh is inert",           Inventory.Refresh() == 0)
    ck("disabled: BuildPayload captures nothing", Inventory.BuildPayload() == nil)
    ck("disabled: Activate does not run",
        (function() Inventory._activated = false; Inventory.Activate(); return Inventory._activated end)() == false)

    Inventory.SetEnabled(true)
    ck("SetEnabled(true) re-enables", Inventory.IsEnabled() == true)

    ------------------------------------------------------------------
    -- 6) TEARDOWN LATCH — a cold scan never overwrites a warm record.
    ------------------------------------------------------------------
    Inventory._leavingWorld = true
    ck("teardown blocks capture",        Inventory.CaptureAllowed() == false)
    ck("teardown yields no payload",     Inventory.BuildPayload() == nil)
    ck("teardown blocks publish",        Inventory.Publish() == false)
    ck("teardown blocks the bank refresh", Inventory.RefreshBank() == false)
    ck("teardown blocks the mail refresh", Inventory.RefreshMail() == false)
    Inventory._leavingWorld = false
    ck("latch re-arms after entering the world", Inventory.CaptureAllowed() == true)

    ------------------------------------------------------------------
    -- Restore
    ------------------------------------------------------------------
    area.owners   = savedOwners
    area.migrated = savedMigrated
    S.SyncNS()[NS_KEY] = savedNS
    Inventory._mode, Inventory._activated = savedMode, savedActivated
    Inventory._enteredWorldAt, Inventory._leavingWorld = savedEntered, savedLeaving
    if db then db.inventoryEnabled = savedEnabled end
    stopTimers()

    if verbose and ns.Print then
        ns:Print(pass and "  inventory selftest: PASS" or "  inventory selftest: FAIL")
    end
    return pass
end

Inventory._SelfTest = selfTest

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("inventory", selfTest)
end
