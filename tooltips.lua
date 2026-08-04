-- Daseeki Nexus — tooltips.lua   (CROSS-ACCOUNT WEALTH TOOLTIPS)
--
-- The cross-character item-count block on an item tooltip, and the cross-account
-- gold breakdown on the money frame — for a player who runs the DEFAULT BLIZZARD
-- BAGS. Nexus already holds the data (inventory.lua's owners graph); until now the
-- only surface that rendered it was Daseeki-Bags. This file is that surface.
--
-- ══ WHY THIS FILE IS A TRANSCRIPTION, NOT A REUSE ════════════════════════════
-- Owner directive: "I want the tooltips in Nexus to be the exact same ones Bags
-- codes, so maybe we can just re-use that."
--
-- Runtime reuse is impossible in the case that matters. The whole point of this
-- feature is the Bags-LESS install: with Daseeki-Bags absent, none of its code is
-- loaded, so there is no ns.Features to call, no ns.Owner to ask, nothing to
-- require. Calling into Bags would make the feature work only when it is not
-- needed and fail exactly when it is.
--
-- So the PURE MODEL below is a line-for-line TRANSCRIPTION of Bags' own pure
-- layer, every function annotated with its Daseeki-Bags source file:line, and the
-- copy is PINNED by a cross-addon PARITY GATE in the external harness
-- (nexus-test-harness/harness/paritytips.lua). That gate loadfile()s BOTH addons'
-- pure layers headless, drives them with the same fixtures, and asserts row-for-row
-- identical output. Drift in either copy turns the run red. This is the mechanism
-- that makes "the exact same ones Bags codes" a checked fact rather than a hope.
--
-- Both trees are OURS (Daseeki-Bags, Daseeki-Nexus). No third-party source was read.
--
-- ══ THE ONE PERMITTED DELTA: LOCATION BADGES ═════════════════════════════════
-- Bags' row anatomy is
--     [portrait] Poonyx      785|cffXXXXXX=|r770|Tbags|t +15|Tbank|t
-- where the "=<badge run>" suffix says WHERE the stack lives (equipped / bags /
-- bank). Nexus renders the SAME anatomy with the badge slot EMPTY:
--     [portrait] Poonyx      785
--
-- It is empty, never faked, for two independent reasons:
--   1. THE DATA DOES NOT EXIST HERE. Nexus's wire contract (inventory.lua) is an
--      AGGREGATE — `itemCounts = { [itemID] = count }` — with no per-slot, no
--      container id, no bank/bags split. Bags' own model already handles exactly
--      this case: Features.LocationParts returns NOTHING for a line whose
--      `exact ~= true`, and every Nexus-sourced line is exact == false. So the
--      empty badge slot is not a Nexus behaviour at all; it is Bags' behaviour on
--      Bags' own summary rows, which is all Nexus can ever produce.
--   2. TWO OF THE THREE BADGE TEXTURES SHIP IN Daseeki-Bags\art\. On the install
--      this feature exists for — Bags absent — those files are not on disk.
--
-- Consequently the CountItemInOwner transcription below keeps its per-slot branch
-- verbatim even though Nexus's data never reaches it: the parity gate drives full
-- per-slot fixtures through both copies, so the branch is genuinely pinned, and a
-- future per-slot source in Nexus would light up the badges with no model change.
-- The gate encodes the render-layer delta as ONE named transform
-- (`stripBadgeRun`) and permits nothing else.
--
-- ══ STAND-DOWN: DASEEKI-BAGS OWNS THE WEALTH UI WHENEVER IT IS LOADED ════════
-- Bags 1.x and Bags 2.0 BOTH render their own item-count block and their own money
-- tooltip. If Nexus also appended, every hover would carry the block twice. So:
-- when the Daseeki-Bags addon is loaded, Nexus appends NOTHING — not a line.
--
-- PROBE CHOICE — the FOLDER, via C_AddOns.IsAddOnLoaded("Daseeki-Bags"), plus the
-- 1.x WildAddon table _G["Daseeki-Bags"] as a second positive signal. This is
-- deliberately the OPPOSITE of inventory.lua's publisher probe, and the difference
-- is not an inconsistency — the two probes answer different questions:
--
--   inventory.lua asks "is another module PUBLISHING to the `bags` mesh
--     namespace?". 1.x publishes; 2.0 does not. The folder name is shared by
--     both, so it carries NO information about a publisher and is excluded
--     (that mistake was probe gen 1 — see inventory.lua's PROBE_GEN header).
--
--   this file asks "is another addon already DRAWING these tooltips?". 1.x draws
--     them and 2.0 draws them, so ANY loaded Daseeki-Bags is a yes, and the folder
--     name is precisely the right evidence. There is no version of Daseeki-Bags
--     that loads and does not own this UI.
--
-- SavedVariables are NOT used as the signal: DaseekiBags2Data / DaseekiBagsAccount
-- survive an uninstall, so a stale save would mute Nexus forever.
--
-- ══ SETTING ══════════════════════════════════════════════════════════════════
-- `wealthTooltips`, default ON, and an ABSENT key also reads ON (store.lua seeds
-- it; IsEnabled below is the belt). Purely additive — one boolean, no schema bump.
--
-- ══ CATALOG EVIDENCE (WoW Classic Era 1.15.9.68808) ══════════════════════════
--   ITEM TOOLTIP. The retail TooltipDataProcessor / AddTooltipPostCall surface is
--     ABSENT from the catalog (it is retail-only). The supported 1.15 surface is
--     the script hook GameTooltip:HookScript("OnTooltipSetItem", fn); the FrameXML
--     handler GameTooltip_OnTooltipSetItem is catalog-present (globals.txt:4745),
--     which is what proves the script exists to hook. Hovered item resolved with
--     GameTooltip:GetItem() -> name, link then GetItemInfoInstant(link) -> itemID
--     (globals.txt:5161; C_Item.GetItemInfoInstant globals.txt:1929).
--   MONEY FRAME. MoneyFrame_OnEnter (globals.txt:6633) and MoneyFrame_OnLeave
--     (globals.txt:6635) are the FrameXML handlers every MoneyFrameTemplate wires,
--     post-hooked with hooksecurefunc (globals.txt:5988). A direct per-frame
--     HookScript on the named player-money frames is installed alongside as the
--     belt, because a template that never wires OnEnter would leave the
--     hooksecurefunc path dormant. Both routes funnel into ONE renderer behind one
--     latch, so a frame covered by both is still drawn once.
--   PRESENCE. C_AddOns.IsAddOnLoaded (globals.txt:497), with the pre-namespace
--     IsAddOnLoaded as the fallback, exactly as inventory.lua probes.
--   Glyphs: CreateTextureMarkup (globals.txt:4149), CreateAtlasMarkup
--     (globals.txt:4063), C_Texture.GetAtlasInfo (globals.txt:2826),
--     GetMoneyString (globals.txt:5292).
--
-- SECURE AUDIT: zero protected calls. Everything here is a post-hook that reads
-- state and adds fontstrings to an UNPROTECTED tooltip, plus one CreateFrame for
-- the 1px rule parented to GameTooltip.

local ADDON, ns = ...

local Tooltips = {}
ns.Tooltips = Tooltips

local EMPTY = {}

----------------------------------------------------------------------
-- Enablement + stand-down
----------------------------------------------------------------------

-- DEFAULT ON, and an ABSENT key also means ON (the same rule inventory.lua's
-- IsEnabled applies to inventoryEnabled, for the same reason: a SavedVariables
-- file written before the key existed must behave like a fresh one).
function Tooltips.IsEnabled()
    local S = ns.Store
    local db = S and S.GetSettings and S.GetSettings()
    if not db then return true end
    if db.wealthTooltips == nil then return true end
    return db.wealthTooltips and true or false
end

-- PURE. probe = { bagsLoaded = bool, bagsTable = table|nil }.
-- ANY loaded Daseeki-Bags owns the wealth UI (see the stand-down header).
function Tooltips.BagsOwnsWealthUI(probe)
    if type(probe) ~= "table" then return false end
    if probe.bagsLoaded then return true end
    if type(probe.bagsTable) == "table" then return true end
    return false
end

-- Live probe. Reuses inventory.lua's ProbeEnvironment when it is loaded so the two
-- probes read the SAME evidence (they weigh it differently — see the header); the
-- inline fallback keeps this file standalone-testable.
function Tooltips.ProbeBags(G)
    G = G or _G
    local I = ns.Inventory
    if I and I.ProbeEnvironment and G == _G then
        local ok, p = pcall(I.ProbeEnvironment)
        if ok and type(p) == "table" then return p end
    end
    local name = (I and I.BAGS_ADDON) or "Daseeki-Bags"
    local loaded = false
    local CA = G.C_AddOns
    if CA and CA.IsAddOnLoaded then
        local ok, res = pcall(CA.IsAddOnLoaded, name)
        loaded = (ok and res) and true or false
    elseif G.IsAddOnLoaded then
        local ok, res = pcall(G.IsAddOnLoaded, name)
        loaded = (ok and res) and true or false
    end
    local B = rawget(G, name)
    return { bagsLoaded = loaded, bagsTable = (type(B) == "table") and B or nil }
end

-- The single gate every live hook consults. Returns active(bool), reason(string).
function Tooltips.Status()
    if not Tooltips.IsEnabled() then
        return false, "cross-account tooltips are switched off"
    end
    if Tooltips.BagsOwnsWealthUI(Tooltips.ProbeBags()) then
        return false, "Daseeki Bags is installed and renders these tooltips itself"
    end
    local I = ns.Inventory
    if I and I.IsEnabled and not I.IsEnabled() then
        return false, "the Inventory module is switched off (no data to show)"
    end
    return true, "active"
end

function Tooltips.Active()
    local active = Tooltips.Status()
    return active
end

----------------------------------------------------------------------
-- ═══════════ PURE MODEL — ITEM COUNTS ═══════════════════════════════
-- TRANSCRIBED from Daseeki-Bags/features.lua. Source line cited per function.
-- Pinned by nexus-test-harness/harness/paritytips.lua.
----------------------------------------------------------------------

-- TRANSCRIBED: Daseeki-Bags/store.lua Store.ContainerClass + Store.IsBankContainer,
-- including its constants (BACKPACK 0, BANK -1, KEYRING -2) and the two live slot
-- counts (NUM_BAG_SLOTS default 4, NUM_BANKBAGSLOTS default 7). Only the per-slot
-- branch below consults it, and Nexus's own data never reaches that branch — it is
-- transcribed so the parity gate can drive full per-slot fixtures through both copies.
local BACKPACK_CONTAINER = 0
local BANK_CONTAINER     = -1
local KEYRING_CONTAINER  = -2
local function numBagSlots()     return _G.NUM_BAG_SLOTS or 4 end
local function numBankBagSlots() return _G.NUM_BANKBAGSLOTS or 7 end

function Tooltips.ContainerClass(cid)
    cid = tonumber(cid)
    if cid == nil then return "unknown" end
    if cid == BACKPACK_CONTAINER then return "backpack" end
    if cid == KEYRING_CONTAINER  then return "keyring"  end
    if cid == BANK_CONTAINER     then return "bank"     end
    if cid >= 1 and cid <= numBagSlots() then return "bag" end
    if cid >= numBagSlots() + 1 and cid <= numBagSlots() + numBankBagSlots() then
        return "bankbag"
    end
    -- Ids beyond the known bag ranges (should not occur on Era) are treated as
    -- bank-side storage so a stray high id never renders as a carried bag.
    if cid > 0 then return "bankbag" end
    return "unknown"
end

-- True when a container id belongs to the bank (only capturable at the bank).
function Tooltips.IsBankContainer(cid)
    local c = Tooltips.ContainerClass(cid)
    return c == "bank" or c == "bankbag"
end

-- TRANSCRIBED: Daseeki-Bags/features.lua:91 Features.CountItemInOwner.
-- Count `itemID` within a single owner. Full owners (per-slot containers) return an
-- exact split { bags, bank, equip, carried, total, exact=true }; summary owners (no
-- containers, only an aggregate itemCounts map) return { total, exact=false }.
-- Returns nil when the owner holds none of the item.
--
-- EVERY Nexus owner takes the second branch: the "bags" wire contract carries
-- itemCounts and nothing per-slot. That is what makes every Nexus row counts-only.
function Tooltips.CountItemInOwner(owner, itemID)
    if type(owner) ~= "table" or not itemID then return nil end
    local containers = owner.containers
    if type(containers) == "table" and next(containers) ~= nil then
        local bags, bank, equip = 0, 0, 0
        for cid, c in pairs(containers) do
            local isBank = Tooltips.IsBankContainer(cid)
            local slots = c and c.slots
            if type(slots) == "table" then
                for _, slot in pairs(slots) do
                    if slot.id == itemID then
                        local n = slot.count or 1
                        if isBank then bank = bank + n else bags = bags + n end
                    end
                end
            end
        end
        if type(owner.equip) == "table" then
            for _, e in pairs(owner.equip) do
                if e.id == itemID then equip = equip + (e.count or 1) end  -- equipped => "on hand"
            end
        end
        local total = bags + bank + equip
        if total == 0 then return nil end
        return { bags = bags, bank = bank, equip = equip,
                 carried = bags + equip, total = total, exact = true }
    end
    -- summary owner: aggregate only (bank/carried unknowable)
    local agg = owner.itemCounts and owner.itemCounts[itemID]
    if agg and agg > 0 then
        return { carried = nil, bank = nil, total = agg, exact = false }
    end
    return nil
end

-- TRANSCRIBED: Daseeki-Bags/features.lua:131 Features.IsOtherAccountOwner
-- (identical rule to Daseeki-Bags/ui_owner.lua:318 Owner.IsOtherAccount — one rule,
-- two surfaces, and this file's money model reuses it below for the same reason).
--
-- NEXUS SEMANTICS OF `source`: Bags sets "full" on a locally-captured character and
-- "summary" on one that arrived over the mesh. Tooltips.ToOwnerRecord below stamps
-- the same two values from Nexus's OWN account graph — a key that sits in this
-- account's bucket is "full", anything else is "summary" — so the partition means
-- the same thing on both sides: my characters above the line, other accounts below.
function Tooltips.IsOtherAccountOwner(owner)
    return (type(owner) == "table" and owner.source == "summary") and true or false
end

-- TRANSCRIBED: Daseeki-Bags/features.lua:139 Features.BuildCountLines.
-- Build ordered display lines for an itemID across `owners` (map [key]=owner).
-- `viewerKey` sorts the viewer's own character first.
function Tooltips.BuildCountLines(owners, itemID, viewerKey)
    local lines = {}
    if type(owners) ~= "table" then return lines end
    for key, owner in pairs(owners) do
        local c = Tooltips.CountItemInOwner(owner, itemID)
        if c then
            lines[#lines + 1] = {
                key = key, name = owner.name or key, class = owner.class,
                race = owner.race, sex = owner.sex, faction = owner.faction,
                account = owner.account or "", source = owner.source or "summary",
                bags = c.bags, equip = c.equip,
                carried = c.carried, bank = c.bank, total = c.total, exact = c.exact,
                isSelf = (viewerKey ~= nil and key == viewerKey),
                isOther = Tooltips.IsOtherAccountOwner(owner),
            }
        end
    end
    -- deterministic order: self first, then total desc, then name asc.
    table.sort(lines, function(a, b)
        if a.isSelf ~= b.isSelf then return a.isSelf end
        if a.total ~= b.total then return a.total > b.total end
        return tostring(a.name) < tostring(b.name)
    end)
    return lines
end

-- TRANSCRIBED: Daseeki-Bags/features.lua:168 Features.FormatCountLine.
-- Plain-copy left/right text for one holder line. Kept because it is part of the
-- transcribed surface the parity gate asserts; the live renderer uses RowStrings.
function Tooltips.FormatCountLine(line)
    local right
    if line.exact and line.bank and line.bank > 0 then
        right = tostring(line.carried) .. " \194\183 Bank " .. tostring(line.bank)  -- \194\183 = middot
    else
        right = tostring(line.total)
    end
    return line.name, right
end

-- TRANSCRIBED: Daseeki-Bags/features.lua:179 Features.SumCountLines.
function Tooltips.SumCountLines(lines)
    local t = 0
    for _, ln in ipairs(lines) do t = t + (ln.total or 0) end
    return t
end

local OTHER_ACCOUNTS_LABEL = "Other Accounts"

-- TRANSCRIBED: Daseeki-Bags/features.lua:215 Features.LocationParts.
-- The ordered LOCATION parts for one holder line, in 1.x's Format() argument order
-- (equipped, bags, bank). Zero-count locations are dropped. A summary line
-- (exact ~= true) has NO parts at all: its number is an aggregate with no
-- provenance — which is EVERY Nexus line, and is why the badge slot stays empty
-- without a single behavioural change to this model.
function Tooltips.LocationParts(line)
    local parts = {}
    if type(line) ~= "table" or line.exact ~= true then return parts end
    if (line.equip or 0) > 0 then parts[#parts + 1] = { loc = "equip", count = line.equip } end
    if (line.bags  or 0) > 0 then parts[#parts + 1] = { loc = "bags",  count = line.bags  } end
    if (line.bank  or 0) > 0 then parts[#parts + 1] = { loc = "bank",  count = line.bank  } end
    return parts
end

-- TRANSCRIBED: Daseeki-Bags/features.lua:227 Features.BuildTooltipRows.
-- Partition + frame the built lines into the ordered tooltip row model:
--
--   Total: 887                     <- ONLY when there is more than ONE holder row
--   [icon] Poonyx        785       <- same-account rows, class colored
--   [icon] Puucons        18
--                                  <- blank separator
--   [A] Other Accounts             <- account glyph + LIGHTGRAY label
--   [icon] Zug            84       <- cross-account rows
--
-- Returns an array of rows plus the grand total as a second value.
-- Row kinds: "total" | "char" | "spacer" | "section".
function Tooltips.BuildTooltipRows(lines)
    local mine, other, total = {}, {}, 0
    for _, ln in ipairs(lines or {}) do
        total = total + (ln.total or 0)
        if ln.isOther then other[#other + 1] = ln else mine[#mine + 1] = ln end
    end

    local rows = {}
    -- The Total header appears only when there is more than ONE holder row. With a
    -- single holder its number is already on that row, so it is suppressed.
    if (#mine + #other) > 1 then
        rows[#rows + 1] = { kind = "total", total = total }
    end
    for _, ln in ipairs(mine) do
        rows[#rows + 1] = { kind = "char", line = ln, badges = true }
    end
    if #other > 0 then
        rows[#rows + 1] = { kind = "spacer" }
        rows[#rows + 1] = { kind = "section", label = OTHER_ACCOUNTS_LABEL }
        for _, ln in ipairs(other) do
            -- badges = false: remote data is aggregate; there is no location to badge.
            rows[#rows + 1] = { kind = "char", line = ln, badges = false }
        end
    end
    return rows, total
end

----------------------------------------------------------------------
-- ═══════════ PURE MODEL — MONEY ═════════════════════════════════════
-- TRANSCRIBED from Daseeki-Bags/ui_owner.lua. Source line cited per function.
----------------------------------------------------------------------

local OTHERS_LABEL = "Others"

-- TRANSCRIBED: Daseeki-Bags/ui_owner.lua:318 Owner.IsOtherAccount. Same predicate as
-- Tooltips.IsOtherAccountOwner above — kept under both names because Bags keeps both,
-- and the parity gate asserts the two agree on every fixture (a divergence would
-- split the item tooltip from the gold panel).
function Tooltips.IsOtherAccount(char)
    return (type(char) == "table" and char.source == "summary") and true or false
end

-- TRANSCRIBED: Daseeki-Bags/ui_owner.lua:335 Owner.BuildMoneyReport.
--   chars = { { key, name, class, account, faction, race, sex, source, favorite, copper }, ... }
--   opts  = { minCopper, maxPerGroup (default 5), sameFactionOnly, selfFaction,
--             isOther (predicate), favoriteIgnoresMinCopper }
-- Row kinds: "char" | "others" | "spacer" | "section" | "rule" | "total".
--
-- `favorite` has no Nexus equivalent (Nexus has no per-character pin), so the live
-- adapter passes false for every character. The flag is transcribed anyway: it is
-- part of the pinned model, the parity gate exercises it, and a Nexus favourite
-- concept would need no model change.
function Tooltips.BuildMoneyReport(chars, opts)
    opts = opts or {}
    local minCopper   = opts.minCopper or 0
    local maxPerGroup = opts.maxPerGroup or 5
    local factionGate = opts.sameFactionOnly and opts.selfFaction and opts.selfFaction ~= ""
    local isOther     = opts.isOther or Tooltips.IsOtherAccount
    local favPinsMin  = opts.favoriteIgnoresMinCopper and true or false

    -- Filter + partition.
    local mine, others = {}, {}
    for _, c in ipairs(chars or {}) do
        -- Same-faction filter: drop opposite-faction characters entirely (rows + total).
        -- Unknown faction (nil) is KEPT — never hide gold we cannot prove is cross-faction.
        if not (factionGate and c.faction ~= nil and c.faction ~= opts.selfFaction) then
            local copper = c.copper or 0
            if copper > 0 and (copper >= minCopper or (favPinsMin and c.favorite)) then
                local row = {
                    kind = "char", key = c.key, name = c.name or "?", class = c.class,
                    account = c.account or "", source = c.source or "summary",
                    faction = c.faction, race = c.race, sex = c.sex,
                    favorite = c.favorite and true or false,
                    copper = copper,
                }
                if isOther(c) then others[#others + 1] = row else mine[#mine + 1] = row end
            end
        end
    end

    -- Sort: money DESC, then name ASC (deterministic tiebreak).
    local function sortGroup(g)
        table.sort(g, function(a, b)
            if a.copper ~= b.copper then return a.copper > b.copper end
            return tostring(a.name):lower() < tostring(b.name):lower()
        end)
    end
    sortGroup(mine); sortGroup(others)

    -- Emit. `shown` counts RENDERED rows only, and a favorite renders regardless of
    -- the cap. `total` accumulates AFTER the filter and for BOTH rendered and
    -- rolled-up rows, so Total == the sum of what is on screen.
    local rows, total = {}, 0
    local function emitGroup(g)
        local shown, overflow = 0, 0
        for _, row in ipairs(g) do
            if shown < maxPerGroup or row.favorite then
                rows[#rows + 1] = row
                shown = shown + 1
            else
                overflow = overflow + row.copper
            end
            total = total + row.copper
        end
        if overflow > 0 then
            rows[#rows + 1] = { kind = "others", copper = overflow }
        end
    end

    emitGroup(mine)
    if #others > 0 then
        -- the separating blank line only when this account had rows.
        if #mine > 0 then rows[#rows + 1] = { kind = "spacer" } end
        rows[#rows + 1] = { kind = "section", label = OTHER_ACCOUNTS_LABEL }
        emitGroup(others)
    end
    -- the blank line + drawn rule, then the grand total. Always emitted, even with
    -- zero characters (the header/rule/Total footer is the frame of the tip).
    rows[#rows + 1] = { kind = "rule" }
    rows[#rows + 1] = { kind = "total", copper = total }
    return rows
end

----------------------------------------------------------------------
-- PURE presentation helpers (TRANSCRIBED from Daseeki-Bags/ui_owner.lua)
----------------------------------------------------------------------

-- Classic Era character-create race sheet + its 4x4 UV grid (male rows, then female),
-- and the faction banners used when the race is unknown.
local RACE_SHEET      = "Interface/Glues/CharacterCreate/UI-CharacterCreate-Races"
local ALLIANCE_BANNER = "Interface/Icons/Inv_BannerPvP_02"
local HORDE_BANNER    = "Interface/Icons/Inv_BannerPvP_01"
local RACE_UV = {
    HUMAN_MALE      = { 0,    0.25, 0,    0.25 },
    DWARF_MALE      = { 0.25, 0.5,  0,    0.25 },
    GNOME_MALE      = { 0.5,  0.75, 0,    0.25 },
    NIGHTELF_MALE   = { 0.75, 1.0,  0,    0.25 },
    TAUREN_MALE     = { 0,    0.25, 0.25, 0.5  },
    SCOURGE_MALE    = { 0.25, 0.5,  0.25, 0.5  },
    TROLL_MALE      = { 0.5,  0.75, 0.25, 0.5  },
    ORC_MALE        = { 0.75, 1.0,  0.25, 0.5  },
    HUMAN_FEMALE    = { 0,    0.25, 0.5,  0.75 },
    DWARF_FEMALE    = { 0.25, 0.5,  0.5,  0.75 },
    GNOME_FEMALE    = { 0.5,  0.75, 0.5,  0.75 },
    NIGHTELF_FEMALE = { 0.75, 1.0,  0.5,  0.75 },
    TAUREN_FEMALE   = { 0,    0.25, 0.75, 1.0  },
    SCOURGE_FEMALE  = { 0.25, 0.5,  0.75, 1.0  },
    TROLL_FEMALE    = { 0.5,  0.75, 0.75, 1.0  },
    ORC_FEMALE      = { 0.75, 1.0,  0.75, 1.0  },
}

-- TRANSCRIBED: Daseeki-Bags/ui_owner.lua Owner.RaceIconUV. `race` is UnitRace's FILE
-- tag ("Scourge", "NightElf", ...); sex 3 = female, anything else male. nil when the
-- race is unknown (-> faction banner).
function Tooltips.RaceIconUV(race, sex)
    if type(race) ~= "string" or race == "" then return nil end
    local key = (race:upper():gsub("%s+", "")) .. "_" .. (sex == 3 and "FEMALE" or "MALE")
    return RACE_UV[key]
end

-- TRANSCRIBED: Daseeki-Bags/ui_owner.lua:450 Owner.IconMarkup. The 12px row portrait:
-- a race face cropped out of the 128x128 race sheet, or the faction banner when the
-- race is unknown. Uses Blizzard's CreateTextureMarkup in-game; hand-builds the
-- identical escape headless so the parity gate compares real strings.
function Tooltips.IconMarkup(race, sex, faction, size)
    size = size or 12
    local uv  = Tooltips.RaceIconUV(race, sex)
    local tex = uv and RACE_SHEET
                or ((faction == "Alliance") and ALLIANCE_BANNER or HORDE_BANNER)
    local l, r, t, b
    if uv then l, r, t, b = uv[1], uv[2], uv[3], uv[4] else l, r, t, b = 0, 1, 0, 1 end
    if _G.CreateTextureMarkup then
        return _G.CreateTextureMarkup(tex, 128, 128, size, size, l, r, t, b, 0, 0)
    end
    return string.format("|T%s:%d:%d:0:0:128:128:%d:%d:%d:%d|t",
        tex, size, size, l * 128, r * 128, t * 128, b * 128)
end

-- TRANSCRIBED: Daseeki-Bags/store.lua Store.MoneyParts.
function Tooltips.MoneyParts(copper)
    copper = copper or 0
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    return g, s, c
end

-- TRANSCRIBED: Daseeki-Bags/ui_owner.lua Owner.GroupDigits.
function Tooltips.GroupDigits(n)
    local s = tostring(math.floor(tonumber(n) or 0))
    local out = s
    while true do
        local rep
        out, rep = out:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
        if rep == 0 then break end
    end
    return out
end

-- TRANSCRIBED: Daseeki-Bags/ui_owner.lua:483 Owner.FormatCoins. GetMoneyString(copper,
-- true) in-game — coin-icon textures, gold thousands-separated, zero denominations
-- suppressed. GetCoinTextureString is the intermediate fallback; the last branch
-- mirrors GetMoneyString's own shape so the headless gate asserts real behavior.
function Tooltips.FormatCoins(copper)
    copper = copper or 0
    if _G.GetMoneyString then return _G.GetMoneyString(copper, true) end
    if _G.GetCoinTextureString then return _G.GetCoinTextureString(copper) end
    local g, s, c = Tooltips.MoneyParts(copper)
    local parts = {}
    if g > 0 then parts[#parts + 1] = Tooltips.GroupDigits(g) .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
    return table.concat(parts, " ")
end

----------------------------------------------------------------------
-- ═══════════ NEXUS DATA ADAPTER ═════════════════════════════════════
--
-- Nexus's owners graph is DaseekiNexusData.inventory.owners, shaped
--     [ownerKey] = { rev, updatedAt, data = <the frozen "bags" wire payload> }
-- and the payload is
--     { key, class, race, sex, faction, level, money,
--       itemCounts = { [itemID] = count }, currency, tracked, ts, mail }
-- (inventory.lua's header is the contract). The pure model above eats Bags-shaped
-- OWNER RECORDS, so one conversion sits between them — the mirror image of
-- Daseeki-Bags/nexus.lua:201 Nexus.ToOwnerRecord, which converts the same entries
-- the other way for Bags' consumption.
--
-- OWN-ACCOUNT vs OTHER-ACCOUNT. The graph carries no account attribution (it is a
-- union of our capture, mesh payloads and the 1.x import). Nexus's account graph
-- does: Store.GetSelfAccount().characters / .homeless is precisely "the characters
-- on THIS account" — the same set the dashboard calls mine. A key in that set gets
-- source = "full"; anything else gets "summary" and lands under Other Accounts.
-- The viewer's own key is always in the set, even before the tracker has written a
-- record for it.
----------------------------------------------------------------------

-- PURE. The set of ownerKeys belonging to this account, from a Nexus account bucket.
-- `selfKey` is always included. Returns a [key]=true map.
function Tooltips.OwnKeySet(bucket, selfKey)
    local set = {}
    if type(bucket) == "table" then
        for _, field in ipairs({ "characters", "homeless" }) do
            local t = bucket[field]
            if type(t) == "table" then
                for key in pairs(t) do
                    if type(key) == "string" and key ~= "" then set[key] = true end
                end
            end
        end
    end
    if type(selfKey) == "string" and selfKey ~= "" then set[selfKey] = true end
    return set
end

-- PURE. One inventory-graph entry -> a Bags-shaped owner record.
-- Mirrors Daseeki-Bags/nexus.lua:201 Nexus.ToOwnerRecord, with the source stamp
-- decided by `ownSet` instead of being hard-coded to "summary" (Bags always sees
-- Nexus entries as remote; Nexus sees its own account's entries as local).
-- Returns nil for anything unconvertible.
function Tooltips.ToOwnerRecord(ownerKey, entry, ownSet)
    if type(ownerKey) ~= "string" or ownerKey == "" then return nil end
    if type(entry) ~= "table" or type(entry.data) ~= "table" then return nil end
    local d = entry.data

    local name = ownerKey:match("^([^%-]+)") or ownerKey
    local o = {
        nameRealm  = ownerKey,
        name       = name,
        class      = d.class,
        race       = d.race,
        sex        = tonumber(d.sex),
        faction    = d.faction,
        level      = tonumber(d.level) or 0,
        money      = tonumber(d.money) or 0,
        rev        = tonumber(entry.rev) or 0,
        ts         = tonumber(d.ts) or tonumber(entry.updatedAt) or 0,
        account    = "",
        source     = (type(ownSet) == "table" and ownSet[ownerKey]) and "full" or "summary",
        containers = nil,          -- NEVER per-slot: the wire contract is aggregate
        itemCounts = {},
    }
    if type(d.itemCounts) == "table" then
        for id, n in pairs(d.itemCounts) do
            id, n = tonumber(id), tonumber(n)
            if id and n and id > 0 and n > 0 then o.itemCounts[id] = n end
        end
    end
    return o
end

-- PURE. The whole graph -> a Bags-shaped owners map the pure model can read.
function Tooltips.BuildOwners(graph, ownSet)
    local out = {}
    if type(graph) ~= "table" then return out end
    for key, entry in pairs(graph) do
        local rec = Tooltips.ToOwnerRecord(key, entry, ownSet)
        if rec then out[key] = rec end
    end
    return out
end

-- PURE. Owner records -> the money-tooltip `chars` list.
-- TRANSCRIBED from Daseeki-Bags/ui_owner.lua:995 Owner.MoneyChars, minus the
-- favorites lookup (Nexus has no per-character pin — see BuildMoneyReport's note).
function Tooltips.MoneyCharsFrom(owners)
    local out = {}
    if type(owners) ~= "table" then return out end
    for key, o in pairs(owners) do
        if type(o) == "table" then
            out[#out + 1] = {
                key      = key,
                name     = o.name or "?",
                class    = o.class,
                account  = o.account or "",
                source   = o.source or "summary",
                faction  = o.faction,
                race     = o.race,
                sex      = o.sex,
                copper   = o.money or 0,
                favorite = false,
            }
        end
    end
    return out
end

----------------------------------------------------------------------
-- LIVE data access (guarded; every one degrades to "no rows")
----------------------------------------------------------------------

function Tooltips.SelfKey()
    local I = ns.Inventory
    if I and I.SelfKey then
        local ok, k = pcall(I.SelfKey)
        if ok and type(k) == "string" and k ~= "" then return k end
    end
    local name = (_G.UnitName and _G.UnitName("player")) or nil
    if not name then return nil end
    local realm = (_G.GetRealmName and _G.GetRealmName()) or ""
    realm = (realm:gsub("%s+", ""))
    if realm == "" then return name end
    return name .. "-" .. realm
end

-- The owners universe every live surface reads, rebuilt at most once a second.
-- Both tooltips rebuild on hover and a rebuild allocates one record per owner; one
-- second is short enough that nothing on screen is ever visibly stale and long
-- enough that a fast mouse does not churn the collector. (The same TTL and the same
-- reasoning as Daseeki-Bags/nexus.lua's merged-view cache.)
local CACHE_TTL = 1
Tooltips._cache, Tooltips._cacheAt = nil, nil

function Tooltips.Invalidate()
    Tooltips._cache, Tooltips._cacheAt = nil, nil
end

function Tooltips.Owners()
    local S = ns.Store
    if not (S and S.InventoryOwners) then return EMPTY end

    local now = (_G.GetTime and _G.GetTime()) or 0
    local at  = Tooltips._cacheAt
    if Tooltips._cache and at and now - at >= 0 and now - at < CACHE_TTL then
        return Tooltips._cache
    end

    local graph = S.InventoryOwners()
    local bucket = S.GetSelfAccount and S.GetSelfAccount(false) or nil
    local owners = Tooltips.BuildOwners(graph, Tooltips.OwnKeySet(bucket, Tooltips.SelfKey()))
    Tooltips._cache, Tooltips._cacheAt = owners, now
    return owners
end

----------------------------------------------------------------------
-- LIVE presentation constants (TRANSCRIBED from Daseeki-Bags)
----------------------------------------------------------------------

-- Daseeki-Bags/features.lua:259 classColor — cream (#ECE3D0) fallback for an
-- unknown class on the ITEM tooltip.
local function classColor(class)
    local c = class and ((_G.CUSTOM_CLASS_COLORS or _G.RAID_CLASS_COLORS or {})[class])
    if c then return c.r, c.g, c.b end
    return 0.925, 0.890, 0.816
end

-- Daseeki-Bags/features.lua:265 creamRGB — the UI-kit `text` token when DaseekiUI is
-- up (Nexus hard-depends on Daseeki-Core, so it normally is), same literal otherwise.
local function creamRGB()
    local UI = _G.DaseekiUI
    if UI and UI.Color then return UI.Color("text") end
    return 0.925, 0.890, 0.816
end

-- Daseeki-Bags/ui_owner.lua moneyClassRGB — the MONEY tooltip is a Blizzard-toned
-- surface, so an unknown class falls back to plain white, NOT the cream token.
local function moneyClassRGB(class)
    local c = class and ((_G.CUSTOM_CLASS_COLORS or _G.RAID_CLASS_COLORS or {})[class])
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

-- Daseeki-Bags/features.lua:293 hex — "|cffRRGGBB" for r,g,b in 0..1, the class hex
-- the row numbers are wrapped in.
local function hex(r, g, b)
    return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5),
        math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- Daseeki-Bags/features.lua:299 / ui_owner.lua gray — LIGHTGRAY wrap for the section
-- header and the money Total.
local function gray(text)
    local col = _G.LIGHTGRAY_FONT_COLOR
    if col and col.WrapTextInColorCode then return col:WrapTextInColorCode(text) end
    return "|cffbbbbbb" .. tostring(text) .. "|r"
end

-- Daseeki-Bags/features.lua:308 / ui_owner.lua — the "Other Accounts" glyph: the
-- retail quest-log account atlas when the client has it, the Battle.net WoW icon
-- (which ships with the Classic client) otherwise.
local ACCOUNT_ATLAS    = "questlog-questtypeicon-account"
local ACCOUNT_FALLBACK = "|TInterface/FriendsFrame/Battlenet-WoWicon:12:12|t"
local accountGlyphCache
local function accountGlyph()
    if accountGlyphCache then return accountGlyphCache end
    local info = _G.C_Texture and _G.C_Texture.GetAtlasInfo
                 and _G.C_Texture.GetAtlasInfo(ACCOUNT_ATLAS)
    if info and _G.CreateAtlasMarkup then
        accountGlyphCache = _G.CreateAtlasMarkup(ACCOUNT_ATLAS, 0, 0, 0, 0)
    else
        accountGlyphCache = ACCOUNT_FALLBACK
    end
    return accountGlyphCache
end

-- Daseeki-Bags/ui_owner.lua OTHERS_ICON — the overflow rollup's native-size icon.
local OTHERS_ICON = "|TInterface/Icons/INV_Misc_QuestionMark:0:0|t"

----------------------------------------------------------------------
-- LIVE: the item-count block
----------------------------------------------------------------------

-- TRANSCRIBED: Daseeki-Bags/features.lua:334 rowStrings, MINUS THE BADGE RUN — the
-- one permitted delta (see the header). Bags composes
--     right = <classHex><total>|r .. gray("=" .. badge1 .. " +" .. badge2)
-- and renders a single location bare; Nexus composes the class-colored count and
-- stops. The badge slot of the anatomy is left EMPTY, never faked with a guessed
-- location. Since Nexus's data is aggregate-only, Bags' own model would produce an
-- empty parts list for every one of these lines anyway (LocationParts requires
-- exact == true) — this is the same output, arrived at one step earlier.
--
-- `withBadges` is accepted and ignored, so the call signature stays identical to
-- Bags' and the parity gate can drive both with the same arguments.
function Tooltips.RowStrings(line, withBadges)   -- luacheck: ignore withBadges
    local icon = Tooltips.IconMarkup(line.race, line.sex, line.faction, 16)
    local left = (icon ~= "" and (icon .. " ") or "") .. tostring(line.name or "?")
    local right = hex(classColor(line.class)) .. tostring(line.total or 0) .. "|r"
    return left, right
end

-- TRANSCRIBED: Daseeki-Bags/features.lua:359 appendCounts.
-- Append the count block to a tooltip that has just been populated for an item.
function Tooltips.AppendCounts(tt)
    if type(tt) ~= "table" and type(tt) ~= "userdata" then return end
    if tt.__dsnCountsShown then return end                 -- one block per populate
    if not Tooltips.Active() then return end
    local getItem = tt.GetItem
    if not getItem then return end
    local _, link = getItem(tt)
    if not link then return end
    local getInstant = _G.GetItemInfoInstant
        or (_G.C_Item and _G.C_Item.GetItemInfoInstant)
    if not getInstant then return end
    local itemID = getInstant(link)
    if not itemID then return end
    local owners = Tooltips.Owners()
    if not owners then return end

    local lines = Tooltips.BuildCountLines(owners, itemID, Tooltips.SelfKey())
    if #lines == 0 then return end
    tt.__dsnCountsShown = true

    local rows = Tooltips.BuildTooltipRows(lines)
    if tt.AddLine then tt:AddLine(" ") end
    for _, row in ipairs(rows) do
        if row.kind == "total" then
            if tt.AddLine then
                tt:AddLine(string.format("%s: |cffffffff%d|r", _G.TOTAL or "Total", row.total))
            end
        elseif row.kind == "char" then
            local left, right = Tooltips.RowStrings(row.line, row.badges)
            local nr, ng, nb = classColor(row.line.class)
            local vr, vg, vb = creamRGB()
            -- The right column carries its own colour escape; the colour args are the
            -- fallback for a client that strips them.
            if tt.AddDoubleLine then tt:AddDoubleLine(left, right, nr, ng, nb, vr, vg, vb) end
        elseif row.kind == "spacer" then
            if tt.AddLine then tt:AddLine(" ") end
        elseif row.kind == "section" then
            if tt.AddLine then tt:AddLine(accountGlyph() .. " " .. gray(row.label)) end
        end
    end
    if tt.Show then tt:Show() end   -- re-fit to the added rows
end

----------------------------------------------------------------------
-- LIVE: the money tooltip
----------------------------------------------------------------------

-- TRANSCRIBED: Daseeki-Bags/ui_owner.lua ensureRule/showRule — the 1px (.3,.3,.3)
-- rule drawn above Total. Created lazily per tooltip (never at file scope: this file
-- must stay CreateFrame-free at load) and parented to the tooltip so it dies with it.
-- It self-hides on the tooltip's OnHide / OnTooltipCleared, so it cannot survive an
-- item tooltip reusing GameTooltip.
local rules = setmetatable({}, { __mode = "k" })

local function ensureRule(GT)
    local existing = rules[GT]
    if existing then return existing end
    if not _G.CreateFrame then return nil end
    local f = _G.CreateFrame("Frame", nil, GT)
    f:SetHeight(5)
    local line = f:CreateLine()
    line:SetStartPoint("LEFT", 0, -5)
    line:SetEndPoint("RIGHT", 0, -5)
    line:SetColorTexture(0.3, 0.3, 0.3)
    line:SetThickness(1)
    f:Hide()
    rules[GT] = f
    if GT.HookScript then
        local function hide() f:Hide() end
        pcall(GT.HookScript, GT, "OnHide", hide)
        pcall(GT.HookScript, GT, "OnTooltipCleared", hide)
    end
    return f
end

local function showRule(GT)
    local f = ensureRule(GT)
    if not f or not GT.NumLines or not GT.GetName then return end
    local base = GT:GetName()
    local n    = GT:NumLines()
    if not base or not n or n < 1 then return end
    local left, right = _G[base .. "TextLeft" .. n], _G[base .. "TextRight" .. n]
    if not (left and right) then return end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", left, "TOPLEFT")
    f:SetPoint("TOPRIGHT", right, "TOPRIGHT")
    f:Show()
end

-- TRANSCRIBED: Daseeki-Bags/ui_owner.lua:1104 Owner.RenderMoneyTooltip.
-- All content comes from the pure BuildMoneyReport; this only formats and draws.
--
-- The two Bags settings the report reads (moneyTooltipMinGold, moneyTooltipFaction)
-- have no Nexus equivalent and are NOT invented here: Nexus passes the Bags DEFAULTS
-- (minCopper 0, no faction gate), which is what a Bags user sees out of the box.
function Tooltips.RenderMoneyTooltip(GT)
    if not GT then return end
    if not Tooltips.Active() then return end
    if GT.ClearLines then GT:ClearLines() end
    if GT.AddLine then GT:AddLine(_G.MONEY or "Money", 1, 1, 1) end   -- pure white header

    local selfFaction = (_G.UnitFactionGroup and _G.UnitFactionGroup("player")) or nil
    local rows = Tooltips.BuildMoneyReport(Tooltips.MoneyCharsFrom(Tooltips.Owners()), {
        minCopper       = 0,
        maxPerGroup     = 5,
        sameFactionOnly = false,
        selfFaction     = selfFaction,
    })

    for _, row in ipairs(rows) do
        if row.kind == "char" then
            local r, g, b = moneyClassRGB(row.class)
            GT:AddDoubleLine(
                Tooltips.IconMarkup(row.race, row.sex, row.faction, 12) .. " " .. row.name,
                Tooltips.FormatCoins(row.copper), r, g, b, r, g, b)
        elseif row.kind == "others" then
            -- NO colour args -> default tooltip white, both columns.
            GT:AddDoubleLine(OTHERS_ICON .. " " .. OTHERS_LABEL, Tooltips.FormatCoins(row.copper))
        elseif row.kind == "spacer" then
            GT:AddLine(" ")
        elseif row.kind == "section" then
            GT:AddLine(accountGlyph() .. " " .. gray(row.label))
        elseif row.kind == "rule" then
            GT:AddDoubleLine(" ", " ")
            showRule(GT)
        elseif row.kind == "total" then
            GT:AddDoubleLine(gray(_G.TOTAL or "Total"), gray(Tooltips.FormatCoins(row.copper)))
        end
    end
    if GT.Show then GT:Show() end
end

----------------------------------------------------------------------
-- LIVE HOOKS (all guarded; absent API => the file loads and self-tests run,
-- the hooks simply no-op)
----------------------------------------------------------------------

-- TRANSCRIBED: Daseeki-Bags/features.lua:403 Features.HookTooltip.
-- Era surface: GameTooltip:HookScript("OnTooltipSetItem", fn). The retail
-- TooltipDataProcessor.AddTooltipPostCall does not exist on 1.15 (catalog-absent);
-- GameTooltip_OnTooltipSetItem is catalog-present (globals.txt:4745), which is the
-- evidence the OnTooltipSetItem script fires on this client.
--
-- The hook is installed UNCONDITIONALLY (even with Bags loaded) and stands down
-- INSIDE AppendCounts, so that a user who disables the setting mid-session — or
-- somehow unloads Bags — needs no re-hook. Standing down is one boolean read.
function Tooltips.HookTooltip()
    if Tooltips._tipHooked then return end
    if not _G.GameTooltip then return end
    Tooltips._tipHooked = true
    local tips = { _G.GameTooltip, _G.ItemRefTooltip, _G.ShoppingTooltip1, _G.ShoppingTooltip2 }
    for _, tt in ipairs(tips) do
        if tt and tt.HookScript then
            tt:HookScript("OnTooltipSetItem", function(self)
                if ns.SafeCall then ns:SafeCall(Tooltips.AppendCounts, self)
                else Tooltips.AppendCounts(self) end
            end)
            -- reset the guard whenever the tooltip is cleared/reused for a new item.
            tt:HookScript("OnTooltipCleared", function(self) self.__dsnCountsShown = nil end)
            tt:HookScript("OnHide",           function(self) self.__dsnCountsShown = nil end)
        end
    end
end

-- The player-money frames a default-UI Classic Era player can hover. Every one is
-- name-probed and guarded; a client that does not create one simply gets no hook.
-- ContainerFrame1MoneyFrame is the load-bearing entry — it is the gold readout at
-- the bottom of the default BACKPACK, i.e. the surface this whole feature exists for.
Tooltips.MONEY_FRAMES = {
    "ContainerFrame1MoneyFrame",   -- default backpack
    "MerchantMoneyFrame",          -- vendor window
    "MailFrameMoneyFrame",         -- mailbox
    "BankFrameMoneyFrame",         -- bank window
}

-- Render into GameTooltip anchored to `frame`. One latch so a frame reached by both
-- hook routes (the hooksecurefunc post-hook and the per-frame OnEnter) draws once.
local moneyShownFor
local function showMoneyTooltip(frame)
    if not Tooltips.Active() then return end
    local GT = _G.GameTooltip
    if not (GT and GT.SetOwner) then return end
    if moneyShownFor == frame and GT.IsShown and GT:IsShown() then return end
    moneyShownFor = frame
    GT:SetOwner(frame or _G.UIParent, "ANCHOR_RIGHT")
    Tooltips.RenderMoneyTooltip(GT)
end

local function hideMoneyTooltip()
    moneyShownFor = nil
    local GT = _G.GameTooltip
    if GT and GT.Hide then GT:Hide() end
end

Tooltips._ShowMoneyTooltip = showMoneyTooltip   -- exposed for diagnostics

-- Is this a PLAYER-money frame? MoneyFrame_OnLoad stamps `moneyType`; an unstamped
-- frame from our own name list is accepted (the names are all player-money frames),
-- but a frame arriving through the global post-hook must prove it.
local function isPlayerMoneyFrame(frame, trusted)
    if type(frame) ~= "table" then return false end
    local mt = rawget(frame, "moneyType")
    if mt == "PLAYER" then return true end
    if mt ~= nil then return false end
    return trusted and true or false
end

-- Idempotent; safe to call repeatedly (frames like the merchant money display are
-- created the first time their window opens).
function Tooltips.HookMoneyFrames()
    Tooltips._moneyHooked = Tooltips._moneyHooked or {}
    for _, name in ipairs(Tooltips.MONEY_FRAMES) do
        local f = _G[name]
        if f and not Tooltips._moneyHooked[name] and f.HookScript then
            Tooltips._moneyHooked[name] = true
            if f.EnableMouse then pcall(f.EnableMouse, f, true) end
            f:HookScript("OnEnter", function(self)
                if ns.SafeCall then ns:SafeCall(showMoneyTooltip, self) else showMoneyTooltip(self) end
            end)
            f:HookScript("OnLeave", function() hideMoneyTooltip() end)
        end
    end
end

-- The global post-hook: catches every MoneyFrameTemplate that wires the FrameXML
-- handlers, including ones we never named. hooksecurefunc runs AFTER the original,
-- so our rendering wins over Blizzard's own truncated-money tip.
function Tooltips.HookMoneyGlobal()
    if Tooltips._moneyGlobalHooked then return end
    if type(_G.hooksecurefunc) ~= "function" then return end
    if type(_G.MoneyFrame_OnEnter) ~= "function" then return end
    Tooltips._moneyGlobalHooked = true
    _G.hooksecurefunc("MoneyFrame_OnEnter", function(frame)
        if not isPlayerMoneyFrame(frame, false) then return end
        if ns.SafeCall then ns:SafeCall(showMoneyTooltip, frame) else showMoneyTooltip(frame) end
    end)
    if type(_G.MoneyFrame_OnLeave) == "function" then
        _G.hooksecurefunc("MoneyFrame_OnLeave", function() hideMoneyTooltip() end)
    end
end
Tooltips._IsPlayerMoneyFrame = isPlayerMoneyFrame

function Tooltips.Activate()
    if Tooltips._activated then return end
    Tooltips._activated = true
    Tooltips.HookTooltip()
    Tooltips.HookMoneyGlobal()
    Tooltips.HookMoneyFrames()
end

----------------------------------------------------------------------
-- Event wiring
----------------------------------------------------------------------

-- Hook at LOGIN, after the FrameXML money frames exist. Late-created frames (the
-- merchant/bank/mail displays) are picked up by the idempotent re-scan below.
ns:On("LOGIN", function() Tooltips.Activate() end)

for _, evt in ipairs({ "MERCHANT_SHOW", "BANKFRAME_OPENED", "MAIL_SHOW" }) do
    ns:RegisterEvent(evt, function()
        if Tooltips._activated then Tooltips.HookMoneyFrames() end
    end)
end

-- Any store refresh (mesh delivery, import, projection) makes the cached owners view
-- stale immediately; an account-ID change re-partitions mine vs Other Accounts, so it
-- invalidates too. The 1s TTL is the floor, not the only signal.
ns:On("STORE_REFRESHED",   function() Tooltips.Invalidate() end)
ns:On("ACCOUNT_ID_CHANGED", function() Tooltips.Invalidate() end)

----------------------------------------------------------------------
-- Diagnostics
----------------------------------------------------------------------

ns:RegisterDebugCommand("tooltips", function()
    local active, why = Tooltips.Status()
    ns:Print("tooltips: " .. (active and "ACTIVE" or "standing down") .. " — " .. tostring(why))
    local probe = Tooltips.ProbeBags()
    ns:Print(string.format("  setting=%s | bagsLoaded=%s | bags 1.x table=%s",
        tostring(Tooltips.IsEnabled()), tostring(probe.bagsLoaded),
        tostring(probe.bagsTable ~= nil)))
    local owners = Tooltips.Owners()
    local n, mine, gold = 0, 0, 0
    for _, o in pairs(owners) do
        n = n + 1
        if o.source == "full" then mine = mine + 1 end
        gold = gold + (o.money or 0)
    end
    ns:Print(string.format("  owners=%d (this account %d) | total %dg | self=%s",
        n, mine, math.floor(gold / 10000), tostring(Tooltips.SelfKey())))
    ns:Print(string.format("  hooks: item=%s moneyGlobal=%s moneyFrames=%s",
        tostring(Tooltips._tipHooked and true or false),
        tostring(Tooltips._moneyGlobalHooked and true or false),
        (function()
            local names = {}
            for k in pairs(Tooltips._moneyHooked or EMPTY) do names[#names + 1] = k end
            table.sort(names)
            return (#names > 0) and table.concat(names, ",") or "none"
        end)()))
end)

----------------------------------------------------------------------
-- Self-tests (pure Lua; suite "tooltips")
----------------------------------------------------------------------

local function selfTest(verbose)
    local pass = true
    local function ck(name, cond)
        if not cond then
            pass = false
            if verbose and ns.Print then ns:Print("  FAIL tooltips/" .. name) end
        end
    end

    local function kinds(rows)
        local out = {}
        for i, r in ipairs(rows) do out[i] = r.kind end
        return table.concat(out, ",")
    end

    ------------------------------------------------------------------
    -- STAND-DOWN (the rule that keeps Bags users from seeing double lines)
    ------------------------------------------------------------------
    ck("standdown/absent",  Tooltips.BagsOwnsWealthUI({ bagsLoaded = false }) == false)
    ck("standdown/loaded",  Tooltips.BagsOwnsWealthUI({ bagsLoaded = true })  == true)
    ck("standdown/1xtable", Tooltips.BagsOwnsWealthUI({ bagsLoaded = false,
                                                        bagsTable = { SyncBridge = {} } }) == true)
    ck("standdown/nil",     Tooltips.BagsOwnsWealthUI(nil) == false)
    do
        -- The live probe on a synthetic global table: folder loaded => stand down.
        local G = { C_AddOns = { IsAddOnLoaded = function() return true end } }
        ck("standdown/probe-loaded", Tooltips.BagsOwnsWealthUI(Tooltips.ProbeBags(G)) == true)
        local G2 = { C_AddOns = { IsAddOnLoaded = function() return false end } }
        ck("standdown/probe-absent", Tooltips.BagsOwnsWealthUI(Tooltips.ProbeBags(G2)) == false)
        local G3 = { IsAddOnLoaded = function() return false end,
                     ["Daseeki-Bags"] = { MeshSync = {} } }
        ck("standdown/probe-1x", Tooltips.BagsOwnsWealthUI(Tooltips.ProbeBags(G3)) == true)
    end

    ------------------------------------------------------------------
    -- THE ANATOMY (Bags' 1.x shape; the parity gate pins it against Bags itself)
    ------------------------------------------------------------------
    local owners = {
        ["Poonyx-R"] = { name = "Poonyx", class = "MAGE", source = "full",
                         itemCounts = { [100] = 785 } },
        ["Puucons-R"] = { name = "Puucons", class = "PRIEST", source = "full",
                          itemCounts = { [100] = 18 } },
        ["Zug-R"]  = { name = "Zug", class = "WARRIOR", source = "summary",
                       itemCounts = { [100] = 84 } },
    }
    local lines = Tooltips.BuildCountLines(owners, 100, "Poonyx-R")
    ck("lines/count", #lines == 3)
    local rows, total = Tooltips.BuildTooltipRows(lines)
    ck("rows/total", total == 887)
    ck("rows/anatomy", kinds(rows) == "total,char,char,spacer,section,char")
    ck("rows/header", rows[1].kind == "total" and rows[1].total == 887)
    ck("rows/selffirst", rows[2].line.name == "Poonyx")
    ck("rows/section", rows[5].label == "Other Accounts")
    ck("rows/other", rows[6].line.name == "Zug" and rows[6].badges == false)
    ck("rows/empty", #Tooltips.BuildTooltipRows({}) == 0)

    -- The >1-holder gate: a single holder suppresses the Total header.
    local one = Tooltips.BuildCountLines({ ["Solo-R"] = owners["Puucons-R"] }, 100, "Solo-R")
    ck("rows/single", kinds(Tooltips.BuildTooltipRows(one)) == "char")

    -- Remote-only still gets the section frame.
    local rr = Tooltips.BuildTooltipRows(
        Tooltips.BuildCountLines({ ["Zug-R"] = owners["Zug-R"], ["Zug2-R"] = owners["Zug-R"] }, 100, nil))
    ck("rows/remoteonly", kinds(rr) == "total,spacer,section,char,char")

    ------------------------------------------------------------------
    -- BADGE ABSENCE: every Nexus line is aggregate, so LocationParts is empty.
    ------------------------------------------------------------------
    for _, ln in ipairs(lines) do
        ck("badges/exact-false", ln.exact == false)
        ck("badges/no-parts", #Tooltips.LocationParts(ln) == 0)
    end
    -- ...but the transcribed per-slot branch is intact and still produces parts in
    -- Bags' order (equip, bags, bank) when given exact data. That is what the parity
    -- gate drives; a Nexus source that ever gains per-slot data lights up for free.
    local eq = Tooltips.LocationParts({ exact = true, equip = 1, bags = 2, bank = 3 })
    ck("badges/order", #eq == 3 and eq[1].loc == "equip" and eq[2].loc == "bags"
        and eq[3].loc == "bank")
    local full = Tooltips.CountItemInOwner({
        containers = { [0]  = { slots = { { id = 100, count = 400 }, { id = 100, count = 370 } } },
                       [-1] = { slots = { { id = 100, count = 15 } } } },
        equip = {} }, 100)
    ck("counts/perslot", full and full.exact == true and full.bags == 770
        and full.bank == 15 and full.total == 785)
    ck("counts/bankcid", Tooltips.IsBankContainer(-1) and Tooltips.IsBankContainer(6)
        and not Tooltips.IsBankContainer(0) and not Tooltips.IsBankContainer(4))
    ck("counts/none", Tooltips.CountItemInOwner({ itemCounts = { [1] = 1 } }, 100) == nil)

    -- The RENDER delta: the right column is the class-colored count and nothing else,
    -- even when the line carries an exact split.
    do
        local _, right = Tooltips.RowStrings({ name = "X", class = "MAGE", total = 785,
                                               exact = true, bags = 770, bank = 15 }, true)
        ck("render/nobadges", not right:find("|T", 1, true))
        ck("render/count", right:find("785", 1, true) ~= nil)
    end

    ------------------------------------------------------------------
    -- THE ADAPTER: Nexus graph entry -> owner record; own vs other account.
    ------------------------------------------------------------------
    local graph = {
        ["Me-R"]     = { rev = 2, updatedAt = 1700000900,
                         data = { class = "MAGE", money = 105 * 10000, ts = 1700000800,
                                  itemCounts = { [100] = 5 } } },
        ["Alt-R"]    = { rev = 1, updatedAt = 1700000500,
                         data = { class = "PRIEST", money = 20000, ts = 1700000400,
                                  itemCounts = { [100] = 7 } } },
        ["Remote-R"] = { rev = 9, updatedAt = 1700009000,
                         data = { class = "WARRIOR", money = 3 * 10000, ts = 1700008000,
                                  itemCounts = { [100] = 11 } } },
        ["Junk-R"]   = { rev = 1 },                        -- no data: unconvertible
    }
    local ownSet = Tooltips.OwnKeySet({ characters = { ["Alt-R"] = {} } }, "Me-R")
    ck("adapter/ownset", ownSet["Me-R"] and ownSet["Alt-R"] and not ownSet["Remote-R"])
    local recs = Tooltips.BuildOwners(graph, ownSet)
    ck("adapter/skips-junk", recs["Junk-R"] == nil)
    ck("adapter/self-full", recs["Me-R"].source == "full")
    ck("adapter/alt-full", recs["Alt-R"].source == "full")
    ck("adapter/remote-summary", recs["Remote-R"].source == "summary")
    ck("adapter/no-containers", recs["Me-R"].containers == nil)
    ck("adapter/name", recs["Remote-R"].name == "Remote")
    ck("adapter/counts", recs["Remote-R"].itemCounts[100] == 11)
    ck("adapter/ts-prefers-capture", recs["Me-R"].ts == 1700000800)
    local grows = Tooltips.BuildTooltipRows(Tooltips.BuildCountLines(recs, 100, "Me-R"))
    ck("adapter/anatomy", kinds(grows) == "total,char,char,spacer,section,char")
    ck("adapter/self-first", grows[2].line.name == "Me")

    ------------------------------------------------------------------
    -- MONEY: the same partition, the 5-row cap, the Others rollup, the Total.
    ------------------------------------------------------------------
    local chars = Tooltips.MoneyCharsFrom(recs)
    ck("money/chars", #chars == 3)
    local mrows = Tooltips.BuildMoneyReport(chars, {})
    local function totalOf(rs)
        for _, r in ipairs(rs) do if r.kind == "total" then return r.copper end end
    end
    ck("money/total", totalOf(mrows) == 105 * 10000 + 20000 + 3 * 10000)
    ck("money/anatomy", kinds(mrows) == "char,char,spacer,section,char,rule,total")
    ck("money/frame-when-empty", kinds(Tooltips.BuildMoneyReport({}, {})) == "rule,total")
    ck("money/zero-dropped",
        kinds(Tooltips.BuildMoneyReport({ { name = "Broke", copper = 0, source = "full" } }, {}))
        == "rule,total")
    -- The 5-row cap plus the Others rollup, and Total still equals what is on screen.
    do
        local many = {}
        for i = 1, 8 do
            many[i] = { name = "C" .. i, copper = i * 10000, source = "full" }
        end
        local capped = Tooltips.BuildMoneyReport(many, {})
        ck("money/cap", kinds(capped) == "char,char,char,char,char,others,rule,total")
        ck("money/cap-total", totalOf(capped) == 36 * 10000)
        local pinned = Tooltips.BuildMoneyReport(
            { { name = "A", copper = 900, source = "full" },
              { name = "B", copper = 800, source = "full" },
              { name = "C", copper = 700, source = "full" },
              { name = "D", copper = 600, source = "full" },
              { name = "E", copper = 500, source = "full" },
              { name = "F", copper = 1,   source = "full", favorite = true } }, {})
        ck("money/favorite-beats-cap", kinds(pinned) == "char,char,char,char,char,char,rule,total")
    end
    -- min-gold pre-filter drops the character from rows AND from the Total.
    do
        local filtered = Tooltips.BuildMoneyReport(
            { { name = "Rich", copper = 50 * 10000, source = "full" },
              { name = "Poor", copper = 5,          source = "full" } }, { minCopper = 10000 })
        ck("money/minfilter", kinds(filtered) == "char,rule,total"
            and totalOf(filtered) == 50 * 10000)
    end
    -- the two partition predicates are ONE rule.
    for _, o in pairs(recs) do
        ck("money/one-partition",
            Tooltips.IsOtherAccount(o) == Tooltips.IsOtherAccountOwner(o))
    end
    -- coins + portraits
    ck("coins/parts", select(1, Tooltips.MoneyParts(1234567)) == 123)
    ck("coins/group", Tooltips.GroupDigits(1234567) == "1,234,567")
    ck("coins/format", type(Tooltips.FormatCoins(105 * 10000)) == "string")
    ck("icon/race", Tooltips.RaceIconUV("Scourge", 3) ~= nil
        and Tooltips.RaceIconUV("NotARace", 2) == nil)
    ck("icon/markup", Tooltips.IconMarkup("Human", 2, "Alliance", 12):find("|T", 1, true) == 1
        or Tooltips.IconMarkup("Human", 2, "Alliance", 12):find("CreateTextureMarkup") ~= nil)

    ------------------------------------------------------------------
    -- The live entry points must be safe no-ops headless / when standing down.
    ------------------------------------------------------------------
    ck("live/append-inert", pcall(Tooltips.AppendCounts, {}))
    ck("live/append-nontable", pcall(Tooltips.AppendCounts, nil))
    ck("live/money-nil", pcall(Tooltips.RenderMoneyTooltip, nil))
    ck("live/moneyframe-guard",
        Tooltips._IsPlayerMoneyFrame({ moneyType = "PLAYER" }, false) == true
        and Tooltips._IsPlayerMoneyFrame({ moneyType = "STATIC" }, false) == false
        and Tooltips._IsPlayerMoneyFrame({}, false) == false
        and Tooltips._IsPlayerMoneyFrame({}, true) == true)

    -- The setting reads ON when absent.
    do
        local S = ns.Store
        local db = S and S.GetSettings and S.GetSettings()
        if db then
            local saved = db.wealthTooltips
            db.wealthTooltips = nil
            ck("setting/absent-on", Tooltips.IsEnabled() == true)
            db.wealthTooltips = false
            ck("setting/explicit-off", Tooltips.IsEnabled() == false)
            ck("setting/off-standsdown", Tooltips.Active() == false)
            db.wealthTooltips = saved
        end
    end

    if verbose and ns.Print then
        ns:Print(pass and "  tooltips selftest: PASS" or "  tooltips selftest: FAIL")
    end
    return pass
end

Tooltips._SelfTest = selfTest

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("tooltips", selfTest)
end
