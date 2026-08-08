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
--             key. If a LIVE Daseeki-Bags 1.x PUBLISHER MODULE is present, this
--             account goes CONSUME-ONLY: we import and store, we do not capture
--             and do not publish. Bags owns the wire; we own the graph. Decided
--             once, at login. See EvaluateMode.
--
--             THE PROBE TESTS FOR A PUBLISHER, NEVER FOR THE FOLDER. Bags 2.0
--             ships under the SAME folder name (Daseeki-Bags) as 1.x — that was
--             a deliberate identity decision at the cutover — so
--             IsAddOnLoaded("Daseeki-Bags") is true on a 2.0 install that has no
--             publisher at all. Generation 1 of this probe treated "loaded but
--             its table is unreadable" as "a publisher is present", and 2.0
--             creates no addon-table global whatsoever: every account went
--             consume-only, nobody published, and every peer's counts froze at
--             the cutover. See PROBE_GEN and NeedsPublishHeal.
--
-- MAIL SUMMARY: mail *attachments* are folded into itemCounts exactly as 1.x
-- does (its BuildSelfSnapshot aggregates player.mail into the same map), so the
-- item side of "mail" is already inside the frozen contract. The additive
-- `mail = { n = <inbox items>, money = <attached copper> }` field carries the
-- summary the contract has no room for. Optional by construction — every reader
-- must tolerate its absence, because a 1.x publisher never sends it.
--
-- DELTA DETECTOR (restored from the 1.x design): a dirty signal is a HINT that
-- something MAY have moved, never a statement that it did. 1.x split the job in
-- two and both halves detected a delta before they spent a frame on the wire:
--
--   * money        Bags/core/features/meshSync.lua registered PLAYER_MONEY and
--                  debounced 4s into PushGold() — money had its OWN tiny
--                  253-byte push, independent of the item machinery, so a
--                  gold-only change (a mailbox pickup, a vendor sale, a trade)
--                  always propagated on its own.
--   * items/currency
--                  Bags/core/features/meshInventory.lua debounced its dirty
--                  signals 3s into Recompute(), which Diff()ed the new maps
--                  against the stored ones and RETURNED EARLY when nothing
--                  changed — no rev bump, no broadcast.
--
-- Nexus folds money INTO the one `bags` payload, so both halves collapse into a
-- single question that must be asked before every publish: DID THE PAYLOAD
-- CONTENT CHANGE? Inventory.PayloadSignature answers it, and MONEY IS A
-- FIRST-CLASS TERM in that signature — a mail-gold pickup moves nothing but
-- `money`, and a signature that skipped it would swallow the very case this
-- detector exists for. `ts` is deliberately NOT in the signature: it moves on
-- every capture, and including it is identical to having no detector at all.
--
-- Both directions matter and each fixes a real failure:
--   changed   -> rev bumps, the payload reaches the wire, peers see the gold.
--   unchanged -> NO rev bump and NO push. Without this, every incidental dirty
--                signal re-revved us, which churned the namespace rev hash the
--                mesh heartbeat advertises; a churning hash makes every peer
--                pull the WHOLE namespace on every heartbeat, and those bulk
--                answers are what a genuinely fresh payload then queues behind.
--
-- THROTTLE: unchanged — PUBLISH_DEBOUNCE (3s), restartable, so a burst of money
-- events coalesces into one publish. That is 1.x's DIRTY_DEBOUNCE exactly, and
-- one second tighter than the 4s its gold push used. No per-copper spam.
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
--
-- IT IS NOT AN IDENTITY TEST. The folder name survived the 1.x -> 2.0 cutover
-- unchanged, so it says nothing about whether a publisher exists; only the
-- module names below do. This constant exists to reach the WildAddon global and
-- to fill the diagnostic line, and for nothing else.
local BAGS_ADDON = "Daseeki-Bags"
Inventory.BAGS_ADDON = BAGS_ADDON

-- The 1.x publisher modules, and the whole of the evidence the mode decision is
-- allowed to rest on. Every one of these was created by `Addon:NewModule(...)`
-- in the tree Bags deleted at the 2.0 cutover (commit "THE CUTOVER"):
--   SyncBridge     — the `bags` namespace publisher (the N5 cutover module)
--   MeshInventory  \
--   MeshSync        > its predecessor, Bags' bespoke DBAG mesh
--   MeshTransport  /
-- Bags 2.0 is not a WildAddon addon and publishes NO addon-table global, so a
-- 2.0 install matches none of them. A 1.x install matches at least one from the
-- moment WildAddon builds the addon table, before any of them decides whether
-- it is "active" — which is the point: an inactive SyncBridge means Bags fell
-- back to its own DBAG mesh and is still the account's publisher.
local LEGACY_PUBLISHERS = { "SyncBridge", "MeshInventory", "MeshSync", "MeshTransport" }
Inventory.LEGACY_PUBLISHERS = LEGACY_PUBLISHERS

-- Generation of the coexistence probe that last wrote this save, persisted on
-- the inventory area. Bumped whenever the probe's SEMANTICS change, so a save
-- written by an older generation is recognisable and can be healed.
--   gen 1  the pre-cutover probe: "the Daseeki-Bags FOLDER is loaded" counted as
--          "a publisher is present", which is exactly what Bags 2.0 satisfies.
--   gen 2  publisher-module evidence only.
local PROBE_GEN = 2
Inventory.PROBE_GEN = PROBE_GEN

local PUBLISH_DEBOUNCE  = 3     -- coalesce rapid local edits before publishing
                                -- (1.x meshInventory's DIRTY_DEBOUNCE exactly)
local INITIAL_PUBLISH   = 6     -- seconds after activation: first capture+publish
local MODE_DELAY        = 2     -- seconds after LOGIN before deciding the mode
local REFRESH_INTERVAL  = 30    -- seconds between namespace -> owners projections
local ENTERING_WORLD_GRACE = 2  -- seconds after PLAYER_ENTERING_WORLD that a scan
                                -- is still treated as cold (mirrors tracker.lua)
local EQUIP_SLOTS       = 19    -- Classic Era paper-doll inventory slots

local EMPTY = {}

-- Exposed so the diagnostic line and the self-tests can state the throttle
-- rather than restating the number.
Inventory.PUBLISH_DEBOUNCE = PUBLISH_DEBOUNCE

----------------------------------------------------------------------
-- The dirty-signal set, AS DATA
--
-- The wiring at the bottom of this file registers PLAIN_DIRTY_EVENTS in a loop,
-- so "is PLAYER_MONEY a dirty signal?" is a question about a table a self-test
-- can read and mutate — not a claim about a closure buried in an event
-- handler. That matters here specifically: 1.x carried the money signal in a
-- DIFFERENT module (meshSync's own PLAYER_MONEY -> PushGold), so folding money
-- into the one `bags` payload silently made this list load-bearing for gold.
-- Drop PLAYER_MONEY from it and a mailbox gold pickup never publishes.
--
-- PLAIN   nothing to re-read first; the live scan in BuildPayload already sees
--         the change, so the handler is just "coalesce and publish".
-- REFRESH a cold component (bank / mail) has to be re-scanned into the stored
--         parts WHILE its frame is open, so these keep bespoke handlers. They
--         are listed here so the two sets together are the whole registration.
----------------------------------------------------------------------

Inventory.MONEY_EVENT = "PLAYER_MONEY"

Inventory.PLAIN_DIRTY_EVENTS = {
    "PLAYER_MONEY",              -- gold: mail pickup, vendor, trade, quest, AH
    "PLAYER_EQUIPMENT_CHANGED",
}

Inventory.REFRESH_DIRTY_EVENTS = {
    "BAG_UPDATE_DELAYED",
    "BANKFRAME_OPENED", "PLAYERBANKSLOTS_CHANGED", "BANKFRAME_CLOSED",
    -- MAIL_SHOW is the mail twin of BANKFRAME_OPENED and was missing entirely
    -- (honesty audit NX-5): without it there was no window flag, so nothing
    -- could tell a readable inbox from an unreadable one.
    "MAIL_SHOW", "MAIL_INBOX_UPDATE", "MAIL_CLOSED",
}

-- PURE. Is `event` one of the signals that marks the publisher dirty? Both
-- lists may be overridden by the caller, which is what lets a mutation test ask
-- "what would happen if PLAYER_MONEY were not in the set?".
function Inventory.IsDirtyEvent(event, plain, refresh)
    if type(event) ~= "string" or event == "" then return false end
    plain   = plain   or Inventory.PLAIN_DIRTY_EVENTS
    refresh = refresh or Inventory.REFRESH_DIRTY_EVENTS
    for i = 1, #plain   do if plain[i]   == event then return true end end
    for i = 1, #refresh do if refresh[i] == event then return true end end
    return false
end

----------------------------------------------------------------------
-- Session state
----------------------------------------------------------------------

Inventory._mode        = nil     -- "publish" | "consume" (sticky per session)
Inventory._modeReason  = nil
Inventory._activated   = false
Inventory._healed      = false   -- this session unlatched a gen-1 consume-only save
Inventory._dirtyTimer  = nil
Inventory._ticker      = nil
Inventory._bankOpen    = false
-- NX-5: the mail twin of _bankOpen, plus its populate proof. _mailOpen is the
-- frame window (MAIL_SHOW .. MAIL_CLOSED); _mailAnswered records that a read
-- INSIDE that window actually came back with something, which is the only
-- positive evidence this API offers that the server has delivered the inbox.
-- Together they are Inventory.MailReadable, and only a readable inbox may erase.
Inventory._mailOpen     = false
Inventory._mailAnswered = false
Inventory._lastSig     = nil     -- signature of the payload we last PUBLISHED
Inventory._pending     = nil     -- payload handed straight to provide() (see Publish)

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

-- PURE over two facts. Is the inbox PROVABLY readable right now?
--
-- Both halves are required and they prove different things:
--   * `open`     — MAIL_SHOW has fired and MAIL_CLOSED has not yet finished. The
--                  inbox surface only exists while the mailbox frame is up;
--                  outside that window GetInboxNumItems answers 0 for a mailbox
--                  stuffed with mail. This is the READABILITY half (Class 4).
--   * `answered` — inside THIS window, a read actually came back with something:
--                  rows, a row count, or attached gold. That is the only positive
--                  evidence this API offers that the server has delivered the
--                  inbox, and it is what closes the Class 6 half — the first
--                  MAIL_INBOX_UPDATE of a visit can land before the list does,
--                  and a zero read taken then is dark, not empty.
--
-- This is the mesh-friends doctrine transplanted: MAIL_SHOW is the REQUEST, and
-- only an answer that arrives after it counts as confirmation, so an inbox event
-- fired for some other reason can never green-light a dark list.
--
-- Both are passable so the truth table can be asserted without touching session
-- state, exactly as Inventory.IsDirtyEvent takes its own tables.
function Inventory.MailReadable(open, answered)
    if open     == nil then open     = Inventory._mailOpen end
    if answered == nil then answered = Inventory._mailAnswered end
    return (open and answered) and true or false
end

-- ── EVERY MAILBOX VISIT USED TO ERASE YOUR MAIL (honesty audit NX-5, Class 4+6)
--
-- This function wrote parts.mail / mailN / mailMoney UNCONDITIONALLY while its
-- sibling RefreshBank, fourteen lines above, already carried the guard it
-- needed. It is driven from MAIL_INBOX_UPDATE and MAIL_CLOSED, and BOTH of those
-- can deliver while the inbox is unreadable:
--
--   * MAIL_CLOSED is the mailbox going away. GetInboxNumItems then answers 0,
--     ScanMail returns `{}, {n=0, money=0}`, and the last honest mail snapshot
--     was overwritten with empty — then MarkDirty PUBLISHED the diminished item
--     counts to every peer. The mail half of your inventory was erased on every
--     single mailbox visit, and the erasure crossed the wire.
--   * the first MAIL_INBOX_UPDATE of a visit can land before the server has
--     delivered the inbox list — the Class 6 dark read of the same surface, with
--     the same result.
--
-- THE GUARD CANNOT BE A NON-EMPTINESS TEST. Taking everything out of your
-- mailbox is a real state and has to be recorded, so "zero rows" is not by
-- itself evidence of anything — which is why RefreshBank's shape is not enough
-- here and the rule has to be a READABILITY PROOF instead:
--
--   an empty read may only DELETE a stored mail snapshot when the emptiness is
--   provable — i.e. when Inventory.MailReadable() says the frame is open AND the
--   server has answered. Any other empty read keeps the last honest snapshot.
--
-- A read that FINDS rows is never refused: rows can only be read when the inbox
-- is readable, so their presence is its own proof and they land immediately,
-- open flag or not. The freeze is one-directional — it withholds deletions,
-- never updates.
--
-- `mayDelete` is the second half of the same rule and answers a different
-- question: WHO IS ENTITLED TO SAY THE INBOX IS EMPTY. Only MAIL_INBOX_UPDATE
-- is, because only it is a statement about inbox CONTENTS. MAIL_SHOW is a
-- statement about a frame, and MAIL_CLOSED is a statement about a frame going
-- away — neither one observed a mail leave, so neither may retire one. This is
-- where the mail twin deliberately parts company with BANKFRAME_CLOSED: the bank
-- close frame is refreshed because PLAYERBANKSLOTS_CHANGED does not fire for
-- every bank mutation, while MAIL_INBOX_UPDATE does fire for every inbox
-- mutation, so the close frame here carries no information and all of the risk.
-- It still refreshes (an update suppressed by the debounce can still land, and
-- MarkDirty still needs the signal) — it simply cannot subtract.
--
-- Residual, stated rather than hidden: mail that disappears without the owner
-- ever seeing it — expired back to sender while they were offline — leaves the
-- stored snapshot standing until a later visit reads rows again. That is the
-- same direction of error RefreshBank has always accepted (`#slots == 0` never
-- erases a stored bank), and it over-reports rather than deleting.
function Inventory.RefreshMail(mayDelete)
    if not Inventory.IsEnabled() or Inventory._mode == "consume" then return false end
    if not Inventory.CaptureAllowed() then return false end
    local parts = Inventory.Parts(true)
    if not parts then return false end
    local slots, summary = Inventory.ScanMail()

    -- The whole snapshot, not just the item map: a mail carrying only gold has
    -- no rows, so mailMoney/mailN are destroyed by the identical dark read.
    local readEmpty = (#slots == 0) and (summary.n == 0) and (summary.money == 0)

    -- Positive evidence that the inbox is answering in THIS window. Recorded
    -- before the write, because it is what licenses the NEXT read to subtract.
    if not readEmpty and Inventory._mailOpen then Inventory._mailAnswered = true end

    local heldAny = (next(parts.mail or EMPTY) ~= nil)
                    or ((tonumber(parts.mailN) or 0) > 0)
                    or ((tonumber(parts.mailMoney) or 0) > 0)
    if readEmpty and heldAny and not (mayDelete and Inventory.MailReadable()) then
        return false   -- unproven emptiness: keep the last honest snapshot
    end

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
-- DELTA DETECTOR: the payload's content signature
--
-- See the DELTA DETECTOR block in the file header for why this exists. Two
-- properties are load-bearing and both are asserted in the self-tests:
--
--   MONEY IS A TERM. The mail-gold case moves `money` and nothing else, so a
--   signature that skipped money would report "unchanged" for exactly the
--   change the owner reported missing. Same for the additive mail summary,
--   whose `money` field is the copper still sitting attached in the inbox.
--
--   `ts` IS NOT A TERM. BuildPayload stamps it from time() on every capture;
--   folding it in would make every signature unique, which is the same as
--   having no detector.
--
-- PURE, deterministic, and order-independent: the count maps are folded through
-- a sorted id list, because pairs() order is not stable across sessions and a
-- signature that depended on it would report a change that never happened.
----------------------------------------------------------------------

local function foldCountSig(out, tag, map)
    local ids = {}
    local byId = {}
    if type(map) == "table" then
        for id, n in pairs(map) do
            local ni, nn = tonumber(id), tonumber(n)
            if ni and nn and nn ~= 0 then
                ids[#ids + 1] = ni
                byId[ni] = nn
            end
        end
    end
    table.sort(ids)
    local buf = { tag }
    for i = 1, #ids do buf[#buf + 1] = ids[i] .. ":" .. byId[ids[i]] end
    out[#out + 1] = table.concat(buf, ",")
end

-- PURE.
function Inventory.PayloadSignature(p)
    if type(p) ~= "table" then return "" end
    local mail = (type(p.mail) == "table") and p.mail or EMPTY
    local out = {
        "money=" .. tostring(tonumber(p.money) or 0),
        "mailn=" .. tostring(tonumber(mail.n) or 0),
        "mailm=" .. tostring(tonumber(mail.money) or 0),
        "level=" .. tostring(tonumber(p.level) or 0),
        "sex="   .. tostring(tonumber(p.sex) or 0),
        "class=" .. tostring(p.class or ""),
        "race="  .. tostring(p.race or ""),
        "fac="   .. tostring(p.faction or ""),
    }
    foldCountSig(out, "ic", p.itemCounts)
    foldCountSig(out, "cur", p.currency)
    return table.concat(out, "|")
end

-- The signature of what we last put on the wire. Falls back to the payload the
-- namespace store ALREADY holds under our key, which is what makes a login with
-- no offline change a no-op instead of a gratuitous rev bump plus fan-out —
-- 1.x's `(cache.mesh.rev or 0) > 0` early return, expressed against our store.
-- nil means "we have never published this character", and nil never compares
-- equal to a real signature, so the first publish of a fresh character always
-- goes out.
function Inventory.LastPublishedSignature(ownerKey)
    if Inventory._lastSig ~= nil then return Inventory._lastSig end
    local S = ns.Store
    local e = S and S.SyncNSGet and S.SyncNSGet(NS_KEY, ownerKey)
    if e and type(e.data) == "table" then
        return Inventory.PayloadSignature(e.data)
    end
    return nil
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

-- PURE. Returns the name of the live 1.x publisher module hanging off a Bags
-- addon table, or nil. Guarded with rawget so a metatable cannot invent one.
function Inventory.LegacyPublisherIn(bagsTable)
    if type(bagsTable) ~= "table" then return nil end
    for i = 1, #LEGACY_PUBLISHERS do
        local name = LEGACY_PUBLISHERS[i]
        if type(rawget(bagsTable, name)) == "table" then return name end
    end
    return nil
end

-- PURE. probe = {
--   bagsLoaded = bool,          -- C_AddOns.IsAddOnLoaded("Daseeki-Bags") — DIAGNOSTIC ONLY
--   bagsTable  = table|nil,     -- _G["Daseeki-Bags"] (WildAddon 1.x publishes it there)
--   nsProvider = bool,          -- a `bags` PROVIDER is registered that is not ours
-- }
-- Returns mode ("consume"|"publish"), reason.
--
-- ONLY POSITIVE EVIDENCE OF A LIVE PUBLISHER YIELDS CONSUME-ONLY, and there are
-- exactly two kinds of it:
--   1. somebody else has already registered a `bags` PROVIDER with Daseeki.Sync
--      — whoever that is, they own the wire, and it is not us;
--   2. the 1.x addon table carries one of LEGACY_PUBLISHERS.
-- Anything else publishes. `bagsLoaded` DELIBERATELY DOES NOT PARTICIPATE: the
-- folder name is shared by 1.x and 2.0, so it carries no information about a
-- publisher, and gen 1's "loaded but its table is unreadable => assume it
-- publishes" was not a conservative default but a permanent false positive
-- against every Bags 2.0 install.
--
-- The decisive marker is the PRESENCE of a publisher module, not whether it
-- reports itself active. An inactive SyncBridge means Bags fell back to its own
-- legacy DBAG mesh — it is still the account's inventory publisher, and Bags
-- 2.0 retires all four modules outright, which is precisely when we take over.
-- Testing `active` instead would hand us the wire while Bags is still on it.
function Inventory.EvaluateMode(probe)
    probe = probe or {}
    if probe.nsProvider then
        return "consume", "a `bags` provider is already registered locally"
    end
    local publisher = Inventory.LegacyPublisherIn(probe.bagsTable)
    if publisher then
        local SB = rawget(probe.bagsTable, publisher)
        if SB.active == true then
            return "consume", "Daseeki-Bags 1.x " .. publisher .. " is publishing"
        end
        return "consume", "Daseeki-Bags 1.x carries its " .. publisher .. " publisher"
    end
    if type(probe.bagsTable) == "table" then
        return "publish", "Daseeki-Bags is loaded and carries no 1.x publisher module"
    end
    if probe.bagsLoaded then
        -- Bags 2.0: same folder, no WildAddon addon-table global, no publisher.
        return "publish", "Daseeki-Bags 2.0 is loaded and publishes nothing"
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
-- SELF-HEAL: the gen-1 consume-only latch
--
-- The house pattern (Conduit's migrate.lua, tracker's ledger repair): name an
-- IMPOSSIBLE state, detect it from the save, fix it once behind a marker, say
-- one line about it.
--
-- The impossible state here: this account is publishing (gen 2 found no 1.x
-- publisher) and yet its save was last written by gen 1, which — on a Bags 2.0
-- install, i.e. every install — could only ever have decided consume-only. So
-- this character captured nothing and published nothing for the whole gen-1
-- era, and every peer's copy of it is frozen at the last 1.x publish.
--
-- DETECTED FROM THE SAVE, NOT FROM A SESSION FLAG: gen 1 persisted no mode at
-- all, so there is no latch to read. `probeGen` is the marker, and its ABSENCE
-- is the signal. The third condition — a self record already in the owners
-- graph — is what keeps a genuinely new account quiet: a first-ever login has
-- no record under its own key yet, so it stamps the marker and says nothing.
--
-- Idempotent by construction: the heal stamps probeGen, and every later login
-- reads it back equal and returns false. Stamping happens on EVERY activation,
-- healed or not, so a fresh save can never drift into a late false heal.
----------------------------------------------------------------------

-- PURE.
function Inventory.NeedsPublishHeal(area, mode, selfKey)
    if mode ~= "publish" then return false end
    if type(area) ~= "table" then return false end
    if tonumber(area.probeGen) == PROBE_GEN then return false end
    if type(selfKey) ~= "string" or selfKey == "" then return false end
    local owners = area.owners
    if type(owners) ~= "table" then return false end
    return owners[selfKey] ~= nil
end

-- Stamp the marker. Returns true when it actually changed.
function Inventory.StampProbeGen(area)
    if type(area) ~= "table" then return false end
    if tonumber(area.probeGen) == PROBE_GEN then return false end
    area.probeGen = PROBE_GEN
    return true
end

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
--
-- Publish stashes the payload it already built in `_pending` and Sync.MarkDirty
-- calls us back SYNCHRONOUSLY, so the handoff hands over the exact bytes the
-- delta detector just judged — one container scan per publish, and no window in
-- which the stored payload could differ from the one we compared. Any other
-- caller (Sync.Get) finds `_pending` empty and gets a fresh capture.
local function provideSelf()
    local p = Inventory._pending
    if p ~= nil then
        Inventory._pending = nil
        return p
    end
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

-- Capture, run the delta detector, publish, mirror into the owners graph.
--
-- THREE outcomes, and the caller must tell the last two apart:
--   true          the payload CHANGED: rev bumped, stored, handed to the mesh.
--   "unchanged"   the payload is byte-for-byte what we already published. A
--                 SETTLED state, not a failure — retrying would only re-ask the
--                 same question and re-answer it the same way.
--   false         we could not answer: disabled, consume-only, a cold/teardown
--                 world, or no suite Sync. Worth retrying.
--
-- `force` skips the detector (the one caller is the diagnostic republish).
function Inventory.Publish(force)
    if not Inventory.IsEnabled() then return false end
    if Inventory._mode == "consume" then return false end
    if not Inventory.CaptureAllowed() then return false end
    local S = suiteSync()
    if not S then return false end

    local ownerKey = Inventory.SelfKey()
    local payload  = Inventory.BuildPayload()
    if payload == nil then return false end

    local sig = Inventory.PayloadSignature(payload)
    if not force and sig == Inventory.LastPublishedSignature(ownerKey) then
        Inventory._lastSig = sig
        return "unchanged"
    end

    Inventory._pending = payload
    local ok = S.MarkDirty(NS_KEY)
    Inventory._pending = nil          -- belt: MarkDirty consumes it synchronously
    if ok ~= true then return false end

    Inventory._lastSig = sig
    Inventory.ProjectOwner(ownerKey)
    return true
end

-- Debounced publish, driven by the dirty signals. Restartable, so a burst of
-- money events inside the window coalesces into exactly one publish.
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
        -- ONLY a hard `false` re-arms. "unchanged" is an answered question, and
        -- re-arming on it would spin the debounce forever on a quiet character.
        if Inventory.Publish() == false then
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

    -- Read the heal BEFORE anything writes to the area, then stamp the marker
    -- unconditionally so the question is asked exactly once per save.
    local S = ns.Store
    local area = S and S.InventoryArea and S.InventoryArea()
    Inventory._healed = Inventory.NeedsPublishHeal(area, mode, Inventory.SelfKey())
    Inventory.StampProbeGen(area)

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

    if Inventory._healed and ns.Print then
        ns:Print("inventory: cross-account publishing was stuck off after the Bags 2.0"
              .. " upgrade -- resuming. Each character's counts refresh the next time"
              .. " you play it.")
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

-- Dirty signals — the same set the 1.x publisher reacts to, plus PLAYER_MONEY,
-- which 1.x carried in its OTHER publisher (meshSync's PLAYER_MONEY -> 4s ->
-- PushGold). Folding money into the one `bags` payload moved that signal here.
local function dirty()
    if not Inventory.IsEnabled() then return end
    Inventory.MarkDirty()
end

-- Registered from the table, not one line per event, so the table IS the
-- wiring and Inventory.IsDirtyEvent can be trusted (and mutated) by a test.
for i = 1, #Inventory.PLAIN_DIRTY_EVENTS do
    ns:RegisterEvent(Inventory.PLAIN_DIRTY_EVENTS[i], dirty)
end

ns:RegisterEvent("BAG_UPDATE_DELAYED", function()
    if not Inventory.IsEnabled() then return end
    if Inventory._bankOpen then Inventory.RefreshBank() end
    Inventory.MarkDirty()
end)

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

-- NX-5: the mailbox window, wired exactly like the bank's. The three handlers
-- are NAMED rather than inlined so a suite can drive a whole mailbox visit —
-- open, update, close — through the real lifecycle instead of asserting on the
-- flags it set itself. The flags are set and cleared OUTSIDE the IsEnabled()
-- guard for the same reason BANKFRAME_OPENED sets _bankOpen outside it: a module
-- toggled on mid-visit must not inherit a window flag nothing will ever clear.

-- The mailbox frame is up. This is the REQUEST; nothing has been answered yet,
-- so the window opens with its proof cleared.
function Inventory.OnMailShow()
    Inventory._mailOpen     = true
    Inventory._mailAnswered = false
    if not Inventory.IsEnabled() then return end
    Inventory.RefreshMail(false)
    Inventory.MarkDirty()
end

-- The one event that is a statement about inbox CONTENTS, and therefore the only
-- one entitled to record that a mail is gone.
function Inventory.OnMailInboxUpdate()
    if not Inventory.IsEnabled() then return end
    Inventory.RefreshMail(true)
    Inventory.MarkDirty()
end

-- The frame is going away. Take the final reading while the window is still
-- open (BANKFRAME_CLOSED's shape), THEN close it. It can add and it can correct;
-- it cannot subtract, because it observed nothing leaving.
function Inventory.OnMailClosed()
    if Inventory.IsEnabled() then
        Inventory.RefreshMail(false)
        Inventory.MarkDirty()
    end
    Inventory._mailOpen     = false
    Inventory._mailAnswered = false
end

ns:RegisterEvent("MAIL_SHOW",         function() Inventory.OnMailShow() end)
ns:RegisterEvent("MAIL_INBOX_UPDATE", function() Inventory.OnMailInboxUpdate() end)
ns:RegisterEvent("MAIL_CLOSED",       function() Inventory.OnMailClosed() end)

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

ns:RegisterDebugCommand("inventory", function(args)
    local S = ns.Store

    -- `/nexus debug inventory push` — republish THIS character past the delta
    -- detector. The detector is deliberately hard to talk out of, so this is
    -- the supported way to prove the wire end of the money path by hand.
    if type(args) == "string" and args:match("^%s*push%s*$") then
        local res = Inventory.Publish(true)
        ns:Print("inventory: forced republish -> " .. tostring(res))
        return
    end

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
    local probe = Inventory.ProbeEnvironment()
    ns:Print(string.format("  probeGen=%s (current %d) | bagsLoaded=%s 1.x publisher=%s"
        .. " foreign provider=%s | healed=%s",
        tostring(area and area.probeGen), PROBE_GEN, tostring(probe.bagsLoaded),
        tostring(Inventory.LegacyPublisherIn(probe.bagsTable) or "none"),
        tostring(probe.nsProvider), tostring(Inventory._healed)))

    -- The money path, end to end, in one line: what our own record holds right
    -- now, what a fresh capture would hold, and whether the detector would call
    -- that a change. "would publish=false" with a gold delta is the bug this
    -- block exists to make visible.
    local selfKey = Inventory.SelfKey()
    local mineNS  = S and S.SyncNSGet and S.SyncNSGet(NS_KEY, selfKey)
    local live    = Inventory.BuildPayload()
    local liveSig = live and Inventory.PayloadSignature(live) or nil
    ns:Print(string.format("  self=%s | stored money=%s rev=%s | live money=%s"
        .. " | would publish=%s | dirty signals=%d, debounce=%ds",
        selfKey ~= "" and selfKey or "?",
        tostring(mineNS and mineNS.data and mineNS.data.money),
        tostring(mineNS and mineNS.rev),
        tostring(live and live.money),
        tostring(liveSig ~= nil and liveSig ~= Inventory.LastPublishedSignature(selfKey)),
        #Inventory.PLAIN_DIRTY_EVENTS + #Inventory.REFRESH_DIRTY_EVENTS,
        PUBLISH_DEBOUNCE))
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
    local savedSig     = Inventory._lastSig

    area.owners   = {}
    area.migrated = false
    S.SyncNS()[NS_KEY] = {}
    Inventory._mode, Inventory._activated = nil, false
    Inventory._leavingWorld, Inventory._loggingOut = false, false
    Inventory._enteredWorldAt = nil    -- math.huge since EW => not in grace
    Inventory._lastSig = nil
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
    -- 2b) THE MAIL-GOLD CASE — a MONEY-ONLY delta, end to end.
    --
    --     The reported break: gold taken out of the mailbox on one account
    --     never showed up on the others. Nothing moves in that scenario except
    --     `money` (and, once the inbox row is gone, the additive mail summary),
    --     so every link below has to treat money as a change ON ITS OWN:
    --     PLAYER_MONEY has to be in the dirty set, the delta detector has to
    --     have money as a term, the rev has to move, and the payload that
    --     reaches the wire has to carry the NEW copper.
    --
    --     Each assertion is paired with a MUTATION that removes exactly the one
    --     thing it is about, so none of them can pass by accident.
    ------------------------------------------------------------------
    do
        local savedM    = Inventory._mode
        local savedNSS  = (_G.Daseeki and _G.Daseeki.Sync
                           and _G.Daseeki.Sync._namespaces[NS_KEY]) or nil
        local savedC    = _G.C_Container
        local savedGIL  = _G.GetInventoryItemLink
        local savedGM   = _G.GetMoney
        local savedCurM = _G.GetCursorMoney
        local savedTrM  = _G.GetPlayerTradeMoney
        local savedSigF = Inventory.PayloadSignature
        local savedPush = ns.Mesh and ns.Mesh.PushNamespace

        -- A world in which the ONLY thing that can move is gold: no bags, no
        -- equipment, no mail rows.
        local GOLD = 151441920
        _G.GetMoney            = function() return GOLD end
        _G.GetCursorMoney      = function() return 0 end
        _G.GetPlayerTradeMoney = function() return 0 end
        _G.C_Container = {
            GetContainerNumSlots = function() return 0 end,
            GetContainerItemID   = function() return nil end,
            GetContainerItemInfo = function() return nil end,
        }
        _G.GetInventoryItemLink = function() return nil end

        local pushes = 0
        if ns.Mesh then
            ns.Mesh.PushNamespace = function() pushes = pushes + 1 end
        end

        Inventory._mode = "publish"
        Inventory._enteredWorldAt = nil
        Inventory._lastSig = nil
        local selfKey = Inventory.SelfKey()
        S.SyncNS()[NS_KEY][selfKey] = nil
        area.owners[selfKey] = nil
        ck("mail-gold: the namespace registers", Inventory.RegisterNamespace() == true)

        -- --- the event side: PLAYER_MONEY really is a dirty signal ----------
        ck("mail-gold: PLAYER_MONEY is a dirty signal",
            Inventory.IsDirtyEvent("PLAYER_MONEY") == true)
        ck("mail-gold: PLAYER_MONEY is in the PLAIN list the wiring loops over",
            (function()
                for i = 1, #Inventory.PLAIN_DIRTY_EVENTS do
                    if Inventory.PLAIN_DIRTY_EVENTS[i] == Inventory.MONEY_EVENT then return true end
                end
                return false
            end)())
        ck("mail-gold: MAIL_CLOSED and MAIL_INBOX_UPDATE are dirty signals too",
            Inventory.IsDirtyEvent("MAIL_CLOSED") and Inventory.IsDirtyEvent("MAIL_INBOX_UPDATE"))
        -- MUTATION: take PLAYER_MONEY out of the set and the predicate must say
        -- no. That is the regression the missing gold looked like.
        ck("mail-gold MUTATION: without PLAYER_MONEY in the set nothing is dirty",
            Inventory.IsDirtyEvent("PLAYER_MONEY", { "PLAYER_EQUIPMENT_CHANGED" }, {}) == false)
        ck("mail-gold: an unrelated event is not a dirty signal",
            Inventory.IsDirtyEvent("PLAYER_REGEN_ENABLED") == false)

        -- --- the detector: money is a term, ts is not -----------------------
        local base = { money = 100, itemCounts = { [4306] = 2 }, currency = {},
                       mail = { n = 0, money = 0 }, ts = 1 }
        local richer = { money = 200, itemCounts = { [4306] = 2 }, currency = {},
                         mail = { n = 0, money = 0 }, ts = 1 }
        local later  = { money = 100, itemCounts = { [4306] = 2 }, currency = {},
                         mail = { n = 0, money = 0 }, ts = 999999 }
        ck("signature: a money-only delta CHANGES the signature",
            Inventory.PayloadSignature(base) ~= Inventory.PayloadSignature(richer))
        ck("signature: a ts-only delta does NOT change the signature",
            Inventory.PayloadSignature(base) == Inventory.PayloadSignature(later))
        ck("signature: mail-summary copper is a term",
            Inventory.PayloadSignature(base) ~= Inventory.PayloadSignature(
                { money = 100, itemCounts = { [4306] = 2 }, currency = {},
                  mail = { n = 0, money = 500 }, ts = 1 }))
        ck("signature: an item delta still changes the signature",
            Inventory.PayloadSignature(base) ~= Inventory.PayloadSignature(
                { money = 100, itemCounts = { [4306] = 3 }, currency = {},
                  mail = { n = 0, money = 0 }, ts = 1 }))
        ck("signature: identical content signs identically regardless of key order",
            Inventory.PayloadSignature({ money = 5, itemCounts = { [9] = 1, [2] = 3 } })
            == Inventory.PayloadSignature({ itemCounts = { [2] = 3, [9] = 1 }, money = 5 }))
        ck("signature: a non-table signs empty", Inventory.PayloadSignature(nil) == "")

        -- --- the pipeline: first publish, then a MONEY-ONLY change ----------
        ck("mail-gold: the first publish goes out", Inventory.Publish() == true)
        local first = S.SyncNSGet(NS_KEY, selfKey)
        ck("mail-gold: the first payload carries the pre-mail gold",
            first ~= nil and first.data.money == GOLD)
        local rev0, pushes0 = first and first.rev or 0, pushes

        -- Nothing moved: the detector must settle, WITHOUT a rev bump or a push.
        ck("mail-gold: an unchanged republish reports 'unchanged'",
            Inventory.Publish() == "unchanged")
        local same = S.SyncNSGet(NS_KEY, selfKey)
        ck("mail-gold: an unchanged republish does not move the rev",
            same ~= nil and same.rev == rev0)
        ck("mail-gold: an unchanged republish pushes nothing", pushes == pushes0)

        -- 7000 gold out of the mailbox. Nothing else in the world changed.
        GOLD = GOLD + 70000000
        ck("mail-gold: a MONEY-ONLY change publishes", Inventory.Publish() == true)
        local after = S.SyncNSGet(NS_KEY, selfKey)
        ck("mail-gold: the rev moved on a money-only change",
            after ~= nil and after.rev > rev0)
        ck("mail-gold: the payload on the wire carries the NEW gold",
            after ~= nil and after.data.money == GOLD)
        ck("mail-gold: the money-only change was handed to the mesh", pushes > pushes0)
        local mineNow = S.InventoryGet(selfKey)
        ck("mail-gold: the owners graph carries the new gold",
            mineNow ~= nil and type(mineNow.data) == "table" and mineNow.data.money == GOLD)

        -- MUTATION: a detector that leaves money out — the exact "content hash
        -- that excludes money" failure — must swallow the very same change.
        do
            local revBefore = S.SyncNSGet(NS_KEY, selfKey).rev
            Inventory.PayloadSignature = function(p)
                if type(p) ~= "table" then return "" end
                return savedSigF({ itemCounts = p.itemCounts, currency = p.currency,
                                   level = p.level, class = p.class, race = p.race,
                                   sex = p.sex, faction = p.faction })
            end
            Inventory._lastSig = nil
            GOLD = GOLD + 12340000
            ck("mail-gold MUTATION: a money-blind signature swallows the change",
                Inventory.Publish() == "unchanged")
            ck("mail-gold MUTATION: ...and the wire still holds the OLD gold",
                S.SyncNSGet(NS_KEY, selfKey).rev == revBefore)
            Inventory.PayloadSignature = savedSigF
            Inventory._lastSig = nil
            ck("mail-gold: the real signature publishes what the mutant swallowed",
                Inventory.Publish() == true
                and S.SyncNSGet(NS_KEY, selfKey).data.money == GOLD)
        end

        -- --- the throttle: a burst of money events coalesces into ONE -------
        do
            local savedTimer = _G.C_Timer
            local timers = {}
            _G.C_Timer = {
                After     = function() return { Cancel = function() end } end,
                NewTicker = function() return { Cancel = function() end } end,
                NewTimer  = function(d, f)
                    local t = { d = d, f = f, cancelled = false }
                    t.Cancel = function() t.cancelled = true end
                    timers[#timers + 1] = t
                    return t
                end,
            }
            Inventory._dirtyTimer = nil
            GOLD = GOLD + 1
            ck("throttle: MarkDirty arms a timer", Inventory.MarkDirty() == true)
            Inventory.MarkDirty()
            Inventory.MarkDirty()
            local live, delay = 0, nil
            for i = 1, #timers do
                if not timers[i].cancelled then live = live + 1; delay = timers[i].d end
            end
            ck("throttle: three dirty signals leave exactly ONE live timer", live == 1)
            ck("throttle: the window is the documented debounce",
                delay == Inventory.PUBLISH_DEBOUNCE)

            local before = S.SyncNSGet(NS_KEY, selfKey).rev
            for i = 1, #timers do if not timers[i].cancelled then timers[i].f() end end
            ck("throttle: the coalesced burst produced exactly one rev bump",
                S.SyncNSGet(NS_KEY, selfKey).rev == before + 1)

            -- ...and a debounce that lands on a no-op must SETTLE, not re-arm
            -- forever on a character standing still in a city.
            timers = {}
            Inventory._dirtyTimer = nil
            Inventory.MarkDirty()
            local armed = #timers
            timers[1].f()
            ck("throttle: an 'unchanged' publish does not re-arm the debounce",
                #timers == armed and Inventory._dirtyTimer == nil)

            -- The other direction: a genuinely COLD moment (still inside the
            -- post-loading-screen grace, so NOT teardown) still re-arms, and a
            -- real edit is never dropped because the world was mid-load.
            timers = {}
            Inventory._dirtyTimer = nil
            Inventory.MarkDirty()
            local armedCold = #timers
            Inventory._enteredWorldAt = (GetTime and GetTime()) or 0
            ck("throttle: the grace really does make the world read cold",
                Inventory.CaptureAllowed() == false and Inventory.IsTeardown() == false)
            timers[1].f()
            Inventory._enteredWorldAt = nil
            ck("throttle: a COLD publish does re-arm the debounce",
                #timers > armedCold and Inventory._dirtyTimer ~= nil)
            Inventory._dirtyTimer = nil

            _G.C_Timer = savedTimer
        end

        -- --- restore --------------------------------------------------------
        Inventory.PayloadSignature = savedSigF
        if ns.Mesh then ns.Mesh.PushNamespace = savedPush end
        _G.GetMoney, _G.GetCursorMoney, _G.GetPlayerTradeMoney = savedGM, savedCurM, savedTrM
        _G.C_Container, _G.GetInventoryItemLink = savedC, savedGIL
        if _G.Daseeki and _G.Daseeki.Sync then
            _G.Daseeki.Sync._namespaces[NS_KEY] = savedNSS
        end
        S.SyncNS()[NS_KEY][selfKey] = nil
        area.owners[selfKey] = nil
        Inventory._mode = savedM
        Inventory._lastSig = nil
    end

    ------------------------------------------------------------------
    -- 3) COEXISTENCE MATRIX
    --
    -- The load-bearing case is 3a: the world as Bags 2.0 actually shapes it.
    -- Gen 1 of this probe read that world as "a publisher is present" and put
    -- every account on the suite consume-only, so nobody published and every
    -- peer's item counts froze at the cutover. It is asserted first and from
    -- both directions (mode AND the fact that a publish actually happens).
    ------------------------------------------------------------------
    local m, why

    -- 3a) THE 2.0-SHAPED WORLD: the folder is loaded (same folder name as 1.x),
    --     and there is no addon-table global at all because 2.0 is not a
    --     WildAddon addon. This MUST publish.
    m, why = Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = nil })
    ck("Bags 2.0 shape (folder loaded, no publisher global) -> PUBLISH", m == "publish")
    ck("Bags 2.0 shape -> reason names 2.0, not ambiguity",
        type(why) == "string" and why ~= "" and why:find("2.0", 1, true) ~= nil)

    -- ...and it is not merely a label. THE FULL BROKEN LINK, end to end, in the
    -- world Bags 2.0 actually presents: a live bag scan picks an item up,
    -- capture folds it into the payload, the payload reaches the wire under our
    -- own key, and projecting the wire lands it in the owners graph — which is
    -- the exact chain that produces a peer's tooltip line. The item id is one
    -- the fixture has never seen before, so nothing here can pass on stale data.
    do
        local NEWITEM = 13442      -- Mighty Rage Potion
        local savedM   = Inventory._mode
        local savedNSS = (_G.Daseeki and _G.Daseeki.Sync
                          and _G.Daseeki.Sync._namespaces[NS_KEY]) or nil
        local savedC   = _G.C_Container
        local savedGIL = _G.GetInventoryItemLink

        -- A carried backpack holding two stacks of the new item and nothing else.
        _G.C_Container = {
            GetContainerNumSlots  = function(bag) return bag == 0 and 4 or 0 end,
            GetContainerItemID    = function(bag, slot)
                if bag == 0 and (slot == 1 or slot == 2) then return NEWITEM end
                return nil
            end,
            GetContainerItemInfo  = function(bag, slot)
                if bag == 0 and slot == 1 then return { stackCount = 3 } end
                if bag == 0 and slot == 2 then return { stackCount = 1 } end
                return nil
            end,
        }
        _G.GetInventoryItemLink = function() return nil end

        Inventory._mode = Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = nil })
        Inventory._enteredWorldAt = nil
        local selfKey = Inventory.SelfKey()
        S.SyncNS()[NS_KEY][selfKey] = nil
        area.owners[selfKey] = nil

        local captured = Inventory.BuildPayload(1700005000)
        ck("2.0-shaped world: capture sees the new item id",
            type(captured) == "table" and type(captured.itemCounts) == "table"
            and captured.itemCounts[NEWITEM] == 4)

        ck("2.0-shaped world: the namespace registers", Inventory.RegisterNamespace() == true)
        ck("2.0-shaped world: Publish() puts a payload on the wire",
            Inventory.Publish() == true)

        local wire = S.SyncNSGet(NS_KEY, selfKey)
        ck("2.0-shaped world: the wire entry exists under our own key",
            wire ~= nil and type(wire.data) == "table")
        ck("2.0-shaped world: the wire payload carries the new item id",
            wire ~= nil and type(wire.data.itemCounts) == "table"
            and wire.data.itemCounts[NEWITEM] == 4)
        ck("2.0-shaped world: the wire rev is a real revision",
            wire ~= nil and tonumber(wire.rev) ~= nil and tonumber(wire.rev) > 0)

        local mineNow = S.InventoryGet(selfKey)
        ck("2.0-shaped world: the owners graph received the new item id",
            mineNow ~= nil and type(mineNow.data) == "table"
            and type(mineNow.data.itemCounts) == "table"
            and mineNow.data.itemCounts[NEWITEM] == 4)

        -- ...and the same account under a LIVE 1.x publisher stays off the wire.
        S.SyncNS()[NS_KEY][selfKey] = nil
        Inventory._mode = Inventory.EvaluateMode({ bagsLoaded = true,
                                                   bagsTable = { SyncBridge = {} } })
        ck("1.x publisher present: the same capture never reaches the wire",
            Inventory.Publish() == false and S.SyncNSGet(NS_KEY, selfKey) == nil)

        _G.C_Container, _G.GetInventoryItemLink = savedC, savedGIL
        if _G.Daseeki and _G.Daseeki.Sync then
            _G.Daseeki.Sync._namespaces[NS_KEY] = savedNSS
        end
        Inventory._mode = savedM
    end

    -- 3b) A synthetic LIVE 1.x publisher, one case per retired module name.
    for _, modName in ipairs(Inventory.LEGACY_PUBLISHERS) do
        m, why = Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = { [modName] = {} } })
        ck("1.x " .. modName .. " present -> consume-only", m == "consume")
        ck("1.x " .. modName .. " -> reason names the module",
            type(why) == "string" and why:find(modName, 1, true) ~= nil)
    end

    m = Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = { SyncBridge = { active = true } } })
    ck("Bags publisher ACTIVE -> consume-only", m == "consume")

    m = Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = { SyncBridge = { active = false } } })
    ck("Bags publisher present but on its legacy mesh -> still consume-only", m == "consume")

    m = Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = { SyncBridge = {} } })
    ck("Bags publisher present, state unknown -> consume-only", m == "consume")

    m = Inventory.EvaluateMode({ bagsLoaded = false, bagsTable = { SyncBridge = { active = true } } })
    ck("publisher table present even without the loaded flag -> consume-only", m == "consume")

    -- 3c) A Bags addon table that carries NO publisher module is not a publisher,
    --     whatever else it holds.
    m = Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = { Owners = {}, Frame = {} } })
    ck("a Bags table with no publisher module -> we publish", m == "publish")
    ck("LegacyPublisherIn finds nothing in a publisher-less table",
        Inventory.LegacyPublisherIn({ Owners = {}, Frame = {} }) == nil)
    ck("LegacyPublisherIn ignores a non-table module slot",
        Inventory.LegacyPublisherIn({ SyncBridge = true }) == nil)
    ck("LegacyPublisherIn survives a non-table argument",
        Inventory.LegacyPublisherIn("Daseeki-Bags") == nil)
    ck("LegacyPublisherIn names the module it found",
        Inventory.LegacyPublisherIn({ MeshSync = {} }) == "MeshSync")

    -- 3d) The FOLDER NAME MUST NOT DECIDE ANYTHING. Same table, both values of
    --     bagsLoaded, same verdict — in both directions.
    ck("bagsLoaded cannot turn a publisher-less world into consume-only",
        Inventory.EvaluateMode({ bagsLoaded = true })
        == Inventory.EvaluateMode({ bagsLoaded = false }))
    ck("bagsLoaded cannot turn a live publisher into publish",
        Inventory.EvaluateMode({ bagsLoaded = false, bagsTable = { SyncBridge = {} } })
        == Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = { SyncBridge = {} } }))

    -- 3e) A foreign registered provider still wins: somebody else owns the wire.
    m = Inventory.EvaluateMode({ bagsLoaded = false, nsProvider = true })
    ck("a foreign `bags` provider -> consume-only regardless of Bags", m == "consume")
    m = Inventory.EvaluateMode({ bagsLoaded = true, bagsTable = nil, nsProvider = true })
    ck("a foreign provider outranks the 2.0 shape", m == "consume")

    m, why = Inventory.EvaluateMode({ bagsLoaded = false })
    ck("no Bags at all -> publish", m == "publish")
    ck("no Bags -> reason given", type(why) == "string" and why ~= "")
    ck("EvaluateMode survives a nil probe", Inventory.EvaluateMode(nil) == "publish")

    -- The live probe reports the shape it read without deciding on the folder.
    do
        local p = Inventory.ProbeEnvironment()
        ck("ProbeEnvironment returns a probe table", type(p) == "table")
        ck("ProbeEnvironment reports bagsLoaded as a boolean", type(p.bagsLoaded) == "boolean")
        ck("ProbeEnvironment reports nsProvider as a boolean", type(p.nsProvider) == "boolean")
    end

    -- Consume-only really does not publish, and never registers (which would
    -- replace the other publisher's spec).
    Inventory._mode = "consume"
    ck("consume-only refuses to publish", Inventory.Publish() == false)
    ck("consume-only refuses to mark dirty", Inventory.MarkDirty() == false)
    ck("consume-only still projects", type(Inventory.Refresh()) == "number")
    Inventory._mode = "publish"

    ------------------------------------------------------------------
    -- 3f) THE GEN-1 CONSUME-ONLY HEAL
    --
    --     Impossible state: publishing now, but the save was last written by a
    --     probe generation that could only ever have said consume-only here.
    --     Fires ONCE, behind the probeGen marker, and stays silent for an
    --     account that never ran under gen 1.
    ------------------------------------------------------------------
    local SELF = "Healer-Whitemane"
    local function genArea(probeGen, withSelf)
        local a = { owners = {}, probeGen = probeGen }
        if withSelf then a.owners[SELF] = { rev = 1, updatedAt = 1, data = {} } end
        return a
    end

    ck("gen-1 save with a self record and a publishing verdict -> HEAL",
        Inventory.NeedsPublishHeal(genArea(nil, true), "publish", SELF) == true)
    ck("heal does not fire when we are consume-only",
        Inventory.NeedsPublishHeal(genArea(nil, true), "consume", SELF) == false)
    ck("heal does not fire on a save already stamped with this generation",
        Inventory.NeedsPublishHeal(genArea(Inventory.PROBE_GEN, true), "publish", SELF) == false)
    ck("heal does not fire on a first-ever login (no self record)",
        Inventory.NeedsPublishHeal(genArea(nil, false), "publish", SELF) == false)
    ck("heal does not fire on a peer-only graph",
        Inventory.NeedsPublishHeal(
            { owners = { ["Someone-Else"] = { rev = 1 } } }, "publish", SELF) == false)
    ck("heal tolerates a missing area", Inventory.NeedsPublishHeal(nil, "publish", SELF) == false)
    ck("heal tolerates an empty self key",
        Inventory.NeedsPublishHeal(genArea(nil, true), "publish", "") == false)
    ck("heal tolerates a malformed owners table",
        Inventory.NeedsPublishHeal({ owners = "nope" }, "publish", SELF) == false)

    -- Marker: stamped once, then idempotent, and the heal never fires twice.
    local healArea = genArea(nil, true)
    ck("stamping a gen-1 save changes it", Inventory.StampProbeGen(healArea) == true)
    ck("the stamp records the current generation", healArea.probeGen == Inventory.PROBE_GEN)
    ck("re-stamping is a no-op", Inventory.StampProbeGen(healArea) == false)
    ck("a stamped save no longer needs the heal",
        Inventory.NeedsPublishHeal(healArea, "publish", SELF) == false)
    ck("StampProbeGen tolerates a missing area", Inventory.StampProbeGen(nil) == false)

    -- An older generation number still heals (the marker is a generation, not a
    -- boolean), and a future one does not re-trigger.
    ck("an older probeGen still heals",
        Inventory.NeedsPublishHeal(genArea(1, true), "publish", SELF) == true)

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
    -- 7) THE MAILBOX READABILITY WINDOW  (honesty audit NX-5, Class 4 + 6)
    --
    -- §5 of the audit names this suite's own blindness: inventory.lua NEVER
    -- stubbed GetInboxNumItems, so ScanMail short-circuited on its capability
    -- guard in every single test and the whole mail path was unexercised — the
    -- only mail assertion in the file was the teardown refusal above. Nothing
    -- here could have seen NX-5, and a green run said so anyway.
    --
    -- So the client is installed first. `INBOX.readable` is the mailbox being
    -- REALLY open, which is a different fact from whether Nexus BELIEVES it is
    -- open, and the whole fixture lives in the gap between the two: a dark
    -- profile that answers 0/nil to everything, and a populated profile that
    -- answers rows. The visit is then driven through the REAL handlers.
    --
    -- RED CONTROLS carry the 1.1.5 body verbatim and must reproduce the wipe
    -- against the identical world, or the green rows are asserting nothing.
    ------------------------------------------------------------------
    local savedInboxAPI = {
        num = _G.GetInboxNumItems, link = _G.GetInboxItemLink,
        item = _G.GetInboxItem, header = _G.GetInboxHeaderInfo,
    }
    local savedMailWin = { Inventory._mailOpen, Inventory._mailAnswered }
    local savedParts   = area.parts and area.parts[Inventory.SelfKey()]

    do
        local INBOX = { readable = false, mail = {} }
        _G.GetInboxNumItems = function() return (INBOX.readable and #INBOX.mail) or 0 end
        _G.GetInboxHeaderInfo = function(i)
            local m = INBOX.readable and INBOX.mail[i]
            return nil, nil, nil, nil, (m and m.money) or 0
        end
        _G.GetInboxItemLink = function(i, j)
            local m = INBOX.readable and INBOX.mail[i]
            if not m or j ~= 1 or not m.id then return nil end
            return "|cffffffff|Hitem:" .. m.id .. "::::::::60:::::|h[Mail]|h|r"
        end
        _G.GetInboxItem = function(i, j)
            local m = INBOX.readable and INBOX.mail[i]
            if not m or j ~= 1 or not m.id then return nil end
            return "Mail", m.id, nil, m.count or 1
        end

        -- The 1.1.5 body, verbatim: scan, write, no questions asked.
        local function PRE_RefreshMail(parts)
            local slots, summary = Inventory.ScanMail()
            parts.mail      = Inventory.AggregateCounts({ slots = { slots } })
            parts.mailN     = summary.n
            parts.mailMoney = summary.money
            return true
        end

        local parts = Inventory.Parts(true)
        local function resetMail()
            parts.mail, parts.mailN, parts.mailMoney = {}, 0, 0
            Inventory._mailOpen, Inventory._mailAnswered = false, false
        end
        local function held(where)
            ck(where .. ": the mail items survived", parts.mail[4306] == 20)
            ck(where .. ": the row count survived",  parts.mailN == 1)
            ck(where .. ": the attached gold survived", parts.mailMoney == 5000)
        end

        -- ---- 7a) the scanner itself, now that it is finally reachable ------
        resetMail()
        INBOX.readable, INBOX.mail = true, { { id = 4306, count = 20, money = 5000 } }
        local sl, sm = Inventory.ScanMail()
        ck("mail scan: the row was read", #sl == 1 and sl[1].id == 4306 and sl[1].count == 20)
        ck("mail scan: the row count", sm.n == 1)
        ck("mail scan: the attached gold", sm.money == 5000)
        INBOX.readable = false
        local dl, dm = Inventory.ScanMail()
        ck("mail scan: a closed mailbox answers nothing", #dl == 0 and dm.n == 0 and dm.money == 0)

        -- ---- 7b) A WARM VISIT records the inbox ---------------------------
        resetMail()
        INBOX.readable = true
        Inventory.OnMailShow()
        Inventory.OnMailInboxUpdate()
        held("a warm visit")
        ck("a warm visit proves the inbox answered", Inventory.MailReadable() == true)

        -- ---- 7c) THE BUG. The client goes cold, THEN MAIL_CLOSED lands ----
        --      This is the whole finding: every mailbox visit ended by erasing
        --      the mail half of the inventory and publishing the loss.
        INBOX.readable = false
        Inventory.OnMailClosed()
        held("the close frame")
        ck("the window closed", Inventory._mailOpen == false)

        -- RED CONTROL: the shipped body against the identical cold client.
        local r = { mail = { [4306] = 20 }, mailN = 1, mailMoney = 5000 }
        PRE_RefreshMail(r)
        ck("RED CONTROL FAILED (NX-5 close frame): the pre-fix body no longer wipes "
           .. "the mail snapshot, so the row above proves nothing",
           next(r.mail) == nil and r.mailN == 0 and r.mailMoney == 0)

        -- ---- 7d) a stray inbox event OUTSIDE any visit ---------------------
        --      MAIL_INBOX_UPDATE can be delivered by anything that calls
        --      CheckInbox. With no window open it is entitled to add, never to
        --      subtract.
        Inventory.OnMailInboxUpdate()
        held("a stray update outside a visit")
        ck("a stray update did not open a window", Inventory._mailOpen == false)

        -- ---- 7e) THE CLASS 6 HALF. The first update of a visit lands before
        --      the server has delivered the list: open, but nothing answered.
        Inventory.OnMailShow()                      -- frame up, inbox still dark
        ck("an unanswered window is not readable", Inventory.MailReadable() == false)
        Inventory.OnMailInboxUpdate()
        held("the first update of a visit, inbox still dark")

        --      ...and the moment the list actually arrives, it lands.
        INBOX.readable = true
        INBOX.mail = { { id = 4306, count = 20, money = 5000 },
                       { id = 12811, count = 3, money = 0 } }
        Inventory.OnMailInboxUpdate()
        ck("the delivered list landed", parts.mail[12811] == 3 and parts.mailN == 2)
        ck("the delivered list proved the inbox", Inventory._mailAnswered == true)

        -- ---- 7f) THE FREEZE IS NOT A ONE-WAY STICK. Emptying your mailbox is
        --      a real state and MUST be recorded: the owner takes everything
        --      while the frame is open and the proven zero writes through.
        INBOX.mail = {}
        Inventory.OnMailInboxUpdate()
        ck("a proven empty inbox still clears the items", next(parts.mail) == nil)
        ck("a proven empty inbox still clears the count", parts.mailN == 0)
        ck("a proven empty inbox still clears the gold",  parts.mailMoney == 0)
        Inventory.OnMailClosed()

        -- ---- 7g) a mail carrying ONLY gold is still an answer -------------
        --      #slots is 0 for it, so the old shape of this guard would have
        --      called the read empty and destroyed mailMoney on the next visit.
        resetMail()
        INBOX.readable, INBOX.mail = true, { { money = 12345 } }
        Inventory.OnMailShow()
        Inventory.OnMailInboxUpdate()
        ck("a gold-only mail records its gold", parts.mailMoney == 12345)
        ck("a gold-only mail proves the inbox answered", Inventory._mailAnswered == true)
        INBOX.readable = false
        Inventory.OnMailClosed()
        ck("a gold-only snapshot survives the close frame", parts.mailMoney == 12345)

        -- ---- 7h) the predicate's truth table, pure ------------------------
        ck("readable: open + answered", Inventory.MailReadable(true, true) == true)
        ck("readable: open, nothing answered", Inventory.MailReadable(true, false) == false)
        ck("readable: answered but the window closed", Inventory.MailReadable(false, true) == false)
        ck("readable: neither", Inventory.MailReadable(false, false) == false)

        -- ---- 7i) MAIL_SHOW is wired as a dirty signal ---------------------
        ck("MAIL_SHOW is a dirty signal", Inventory.IsDirtyEvent("MAIL_SHOW") == true)

        -- ---- 7j) the teardown gate still outranks a proven window ---------
        Inventory._mailOpen, Inventory._mailAnswered = true, true
        Inventory._leavingWorld = true
        ck("teardown refuses the mail refresh even inside a proven window",
            Inventory.RefreshMail(true) == false)
        Inventory._leavingWorld = false
        resetMail()
    end

    _G.GetInboxNumItems, _G.GetInboxItemLink = savedInboxAPI.num, savedInboxAPI.link
    _G.GetInboxItem, _G.GetInboxHeaderInfo   = savedInboxAPI.item, savedInboxAPI.header
    Inventory._mailOpen, Inventory._mailAnswered = savedMailWin[1], savedMailWin[2]
    if area.parts then area.parts[Inventory.SelfKey()] = savedParts end

    ------------------------------------------------------------------
    -- Restore
    ------------------------------------------------------------------
    area.owners   = savedOwners
    area.migrated = savedMigrated
    S.SyncNS()[NS_KEY] = savedNS
    Inventory._mode, Inventory._activated = savedMode, savedActivated
    Inventory._enteredWorldAt, Inventory._leavingWorld = savedEntered, savedLeaving
    Inventory._lastSig = savedSig
    Inventory._pending = nil
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
