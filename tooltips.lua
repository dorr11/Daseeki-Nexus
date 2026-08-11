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

-- The suite ACCENT ink (the delegate loud line's label). The UI kit's token
-- when DaseekiUI is up — Nexus hard-depends on Daseeki-Core, so it normally
-- is — with a fixed literal of the same family otherwise, the creamRGB shape.
local function accent(text)
    local UI = _G.DaseekiUI
    if UI and UI.Color then
        local r, g, b = UI.Color("accent")
        if type(r) == "number" then return hex(r, g, b) .. tostring(text) .. "|r" end
    end
    return "|cffd79921" .. tostring(text) .. "|r"
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
-- ═══════════ RECIPE LINES — NOT TRANSCRIBED, NEXUS ORIGINAL ═════════
--
-- Everything from here to the end of this section is the PROFESSIONS module's
-- tooltip surface (wave P3). It has nothing to do with Daseeki-Bags, is NOT
-- part of the transcription, and is NOT covered by the cross-addon parity gate
-- — the gate drives AppendCounts and the pure count model only, and those are
-- untouched above. Do not transcribe anything from Bags into this section and
-- do not let anything here leak upward.
--
-- WHAT IT DRAWS. On a RECIPE ITEM (a plan / pattern / formula / recipe /
-- schematic — anything the dataset maps to a teaching spell), two lines:
--
--     Known: You, Zug
--     Learnable: Puucons (285/275)
--     (2 characters unscanned)
--
-- Known = characters we have PROVEN know it. Learnable = characters we have
-- proven do NOT know it, who have the profession, whose current skill meets
-- the requirement, and who hold the specialisation when the recipe is gated on
-- one. The owner's ruling was "just learned and can learn is fine" — so a
-- character whose skill is short, or who lacks the gating specialisation,
-- appears in NEITHER line. There is no craftable-by line. The viewer is one of
-- these characters, shown as "You", first in its line (see WHICH CHARACTERS).
--
-- WHY THE THIRD LINE EXISTS — the defect we refuse to reproduce.
-- PROFESSIONS_DATASET_ADDENDUM §5.3: the shipped third-party equivalent stores
-- each alt's MISSING set and treats "absent from missing" as KNOWN. An alt
-- whose record predates the recipe — dataset updated, alt not logged in since —
-- is therefore reported as ALREADY KNOWING IT. That hides exactly the alt the
-- player opened the tooltip to find.
--
-- Our chain cannot say that. professions.lua stores the LEARNED set, and
-- Professions.KnownState returns "known" / "missing" / "unknown" with no
-- boolean form. An "unknown" alt is in neither list — and because silence is
-- itself a claim, the count of them is stated out loud, quietly, in grey. An
-- absent third line means we have a proven answer for every alt that has the
-- profession. That is the whole difference between this and the thing it
-- replaces.
--
-- WHICH CHARACTERS. Every character in the professions owners graph — this
-- account's and every peer account's, since the mesh is the point — that HAS
-- the profession recorded. A character with no record of that profession is
-- not a data gap, it is a proven negative, and it is counted nowhere. The
-- VIEWER's own character is INCLUDED, under the exact same eligibility rules,
-- rendered as "You" and listed FIRST in whichever line it lands in (owner
-- ruling, 2026-08: hovering a learnable recipe on the very character that
-- could learn it used to answer with everyone BUT them). Its record is read
-- from the same store bucket as every alt's — Store.ProfessionsOwners()
-- [selfKey], the record Publish keeps projected via ProjectOwner, which is
-- also what the professions tab's payloadLookup reads for the local
-- character — so self is never a special data path, only a special label.
--
-- PROFESSION RESOLUTION is an item-id lookup into our dataset
-- (Dataset.RecipeItemSpell), never the item's recipe SUBCLASS ORDINAL. The
-- addendum's §5.2 ceiling — a fixed positional list of eight professions, so
-- poisons and fishing get no lines at all and a client renumber silently
-- re-attributes everything — is not inherited.
--
-- STAND-DOWN. MissingTradeSkillsList draws its own version of these lines. It
-- is going away, but it is still installed today, and two blocks on one hover
-- is worse than either. So while that addon is loaded we draw NOTHING and say
-- so once. This is the same rule, and the same probe shape, as the Bags
-- stand-down above — the difference is that Daseeki-Bags does not draw recipe
-- lines, so the wealth stand-down does NOT gate this block, and this one does
-- not gate the wealth block.
--
-- INERTNESS. No new hook is installed for this: the OnTooltipSetItem hook that
-- already exists for the count block calls this appender too, and it returns on
-- its first line when the Professions module is off — before the dataset is
-- asked for anything, which is what keeps "disabled means no dataset resident"
-- true.
----------------------------------------------------------------------

-- The addon FOLDER, exactly as the Bags probe reads its own. A SavedVariables
-- file is not the signal: it survives an uninstall and would mute us forever.
Tooltips.MTSL_ADDON = "MissingTradeSkillsList"

-- PURE. probe = { mtslLoaded = bool }.
function Tooltips.MTSLOwnsRecipeLines(probe)
    if type(probe) ~= "table" then return false end
    return probe.mtslLoaded and true or false
end

function Tooltips.ProbeMTSL(G)
    G = G or _G
    local name = Tooltips.MTSL_ADDON
    local loaded = false
    local CA = G.C_AddOns
    if CA and CA.IsAddOnLoaded then
        local ok, res = pcall(CA.IsAddOnLoaded, name)
        loaded = (ok and res) and true or false
    elseif G.IsAddOnLoaded then
        local ok, res = pcall(G.IsAddOnLoaded, name)
        loaded = (ok and res) and true or false
    end
    return { mtslLoaded = loaded }
end

-- The gate for the recipe block. Deliberately independent of Tooltips.Status():
-- the wealth block stands down for Daseeki-Bags, this one does not (Bags draws
-- no recipe lines), and this one stands down for MTSL, which the wealth block
-- has no opinion about.
function Tooltips.RecipeStatus()
    local P = ns.Professions
    if not (P and P.IsEnabled) then
        return false, "the Professions module is not loaded"
    end
    if not P.IsEnabled() then
        return false, "the Professions module is switched off"
    end
    if Tooltips.MTSLOwnsRecipeLines(Tooltips.ProbeMTSL()) then
        return false, "MissingTradeSkillsList is installed and draws its own recipe lines"
    end
    return true, "active"
end

function Tooltips.RecipeActive()
    local active = Tooltips.RecipeStatus()
    return active
end

-- Said ONCE per session, on the first recipe we decline to annotate, so the
-- feature's silence during the transition is explained rather than mysterious.
function Tooltips.NoteRecipeStandDown(why)
    if Tooltips._recipeNoted then return false end
    Tooltips._recipeNoted = true
    if ns.Print then
        ns:Print("recipe tooltip lines are standing down — " .. tostring(why)
            .. ". Uninstall it to use the Nexus lines.")
    end
    return true
end

----------------------------------------------------------------------
-- PURE MODEL — the recipe block
--
-- `entries` is one record per candidate character:
--   { key=, name=, class=, state="known"|"missing"|"unknown", skill=<n|nil>,
--     specs={ <spec spell ids> }, isSelf=<true on the viewer's own entry|nil> }
-- `req` is the recipe's required skill; `specID` the gating specialisation spell
-- id or nil. Neither the dataset nor any client API is touched here.
----------------------------------------------------------------------

-- Does this character hold the specialisation the recipe is gated on?
--
-- ONE SPEC RULE, not two: this routes through Professions.SpecStanding, the
-- same tree-aware predicate the professions panel's list, census, shopping
-- list and who-can-craft read (see its header in professions.lua). "Learnable"
-- means HOLDING the gate — standing "ok" — which the tree widens by exactly
-- one honest case: a Master Axesmith holds Weaponsmith by implication, so a
-- Weaponsmith-gated recipe is learnable for him. A plain Weaponsmith is NOT
-- learnable for a Master Axesmith recipe (standing "openable": he must take
-- the spec first) — and that was already true of every unspecced character.
--
-- The fallback is exact membership, which is what the tree degenerates to for
-- a spec it does not carry. It is what runs when this file is loaded ALONE —
-- the cross-addon parity gate's micro-runtime publishes no ns.Professions —
-- so the pure layer stays loadable on its own.
function Tooltips.RecipeSpecOK(entry, specID)
    if specID == nil then return true end
    local list = entry and entry.specs
    if type(list) ~= "table" then return false end
    local P = ns.Professions
    if P and P.SpecStanding then
        return P.SpecStanding(specID, list) == "ok"
    end
    for i = 1, #list do
        if list[i] == specID then return true end
    end
    return false
end

-- PURE. entries -> { known = {entry,...}, learnable = {entry,...}, unscanned = n }.
--
-- The three-way sort is deterministic by construction (class 8): in BOTH lists
-- the viewer's own entry (isSelf) is pinned first, then known by name, and
-- learnable by skill DESCENDING then name, so the alt best placed to learn it
-- reads first. `unscanned` counts every character that has the profession and
-- about whom we cannot give a proven answer — the never-scanned window, the
-- payload written against a different dataset version, and the scanned record
-- whose skill level never resolved (we cannot judge learnability without it).
function Tooltips.BuildRecipeBlock(entries, req, specID)
    local block = { known = {}, learnable = {}, unscanned = 0 }
    if type(entries) ~= "table" then return block end
    req = tonumber(req)

    for i = 1, #entries do
        local e = entries[i]
        if type(e) == "table" and e.name then
            if e.state == "known" then
                block.known[#block.known + 1] = e
            elseif e.state == "missing" then
                local skill = tonumber(e.skill)
                if skill == nil then
                    -- proven not-known, but we cannot say whether they COULD
                    -- learn it. That is a gap, and gaps are counted, not hidden.
                    block.unscanned = block.unscanned + 1
                elseif req ~= nil and skill >= req and Tooltips.RecipeSpecOK(e, specID) then
                    block.learnable[#block.learnable + 1] = e
                end
                -- skill short, or specialisation missing: the owner asked for
                -- "learned and can learn" only. Neither line, and NOT a gap —
                -- we know the answer, it is just not one of the two he wants.
            else
                block.unscanned = block.unscanned + 1
            end
        end
    end

    -- Self first is not a preference, it is part of the class-8 pin: isSelf is
    -- normalised to 0/1 so a nil flag can never make the comparator flap.
    table.sort(block.known, function(a, b)
        local as, bs = a.isSelf and 1 or 0, b.isSelf and 1 or 0
        if as ~= bs then return as > bs end
        return tostring(a.name) < tostring(b.name)
    end)
    table.sort(block.learnable, function(a, b)
        local as, bs = a.isSelf and 1 or 0, b.isSelf and 1 or 0
        if as ~= bs then return as > bs end
        local sa, sb = tonumber(a.skill) or 0, tonumber(b.skill) or 0
        if sa ~= sb then return sa > sb end
        return tostring(a.name) < tostring(b.name)
    end)
    return block
end

-- PURE. block -> the rows to draw, in order.
-- Each row is { kind = "known"|"learnable"|"unscanned", text = <coloured>,
-- plain = <uncoloured> }. `colorize` is injectable so the self-tests can read
-- the text without escape sequences; live callers pass nothing.
function Tooltips.RecipeRows(block, req, colorize)
    local rows = {}
    if type(block) ~= "table" then return rows end
    local plainMode = (colorize == false)
    local wrapName = plainMode and function(_, n) return n end
        or (type(colorize) == "function" and colorize)
        or function(class, n) return hex(classColor(class)) .. n .. "|r" end
    local wrapQuiet = plainMode and function(s) return s end or gray
    -- The viewer's own entry is labelled "You", never the character name, in
    -- BOTH the coloured and the plain form — the colorize seam changes the
    -- wrapping, never the word. The class colour still comes from e.class, so
    -- "You" wears the viewer's own class colour like any other name.
    local function dispName(e) return e.isSelf and "You" or e.name end
    req = tonumber(req)

    if #block.known > 0 then
        local parts = {}
        for i, e in ipairs(block.known) do parts[i] = wrapName(e.class, dispName(e)) end
        rows[#rows + 1] = {
            kind  = "known",
            text  = wrapQuiet("Known:") .. " " .. table.concat(parts, ", "),
            plain = "Known: " .. (function()
                local p = {} for i, e in ipairs(block.known) do p[i] = dispName(e) end
                return table.concat(p, ", ") end)(),
        }
    end

    if #block.learnable > 0 then
        local parts, plains = {}, {}
        for i, e in ipairs(block.learnable) do
            local skill = tonumber(e.skill)
            -- current/required, so the line answers "by how much" as well as
            -- "who" — the same two numbers the recipe's own requirement line
            -- shows, from the other character's side.
            local suffix = (skill and req) and string.format(" (%d/%d)", skill, req)
                or (skill and string.format(" (%d)", skill) or "")
            parts[i]  = wrapName(e.class, dispName(e)) .. wrapQuiet(suffix)
            plains[i] = dispName(e) .. suffix
        end
        rows[#rows + 1] = {
            kind  = "learnable",
            text  = wrapQuiet("Learnable:") .. " " .. table.concat(parts, ", "),
            plain = "Learnable: " .. table.concat(plains, ", "),
        }
    end

    if (block.unscanned or 0) > 0 then
        local n = block.unscanned
        -- "characters", not "alts": the gap count can now include the VIEWER
        -- (a fresh character is unscanned like anyone else — no special-casing
        -- beyond the name and the ordering), and calling yourself an alt on
        -- your own screen would be a small lie.
        local label = string.format("(%d %s unscanned)", n,
            (n == 1) and "character" or "characters")
        rows[#rows + 1] = { kind = "unscanned", text = wrapQuiet(label), plain = label }
    end

    return rows
end

----------------------------------------------------------------------
-- THE DELEGATE LOUD LINE  (profession-delegates phase 1)
--
-- ONE accent line ABOVE Known/Learnable when the viewer's-faction PRIMARY for
-- this recipe's lane is PROVEN missing it:
--
--     Primary missing: Poonyx (280/275)
--
-- The rules, each one the owner's:
--   * proven "missing" ONLY. An unscanned primary gets NO loud line (unproven
--     is not missing — the three-state honesty rule); they still count in the
--     grey unscanned gap like anyone else.
--   * ALWAYS shown when proven missing, even with the skill short of the
--     requirement — this is COLLECTION framing (the primary collects every
--     recipe of the lane), so the line states current skill vs req and lets
--     the owner see the distance. A nil skill states nothing rather than
--     inventing a number.
--   * the primary IS the viewer -> "Primary missing: You (...)" — the same
--     isSelf rendering (and class colour) as the lines below it.
--   * SECONDARY delegates get no loud line. Primary only.
--
-- PURE: `primaryKey` arrives already resolved (Professions.ResolveDelegate
-- owns the lane walk and the faction scoping; its self-tests own that matrix).
-- A primaryKey with no entry in `entries` — no record of the profession at
-- all — is unproven, so: no line.
----------------------------------------------------------------------

function Tooltips.RecipePrimaryRow(entries, primaryKey, req, colorize)
    if type(primaryKey) ~= "string" or primaryKey == "" then return nil end
    if type(entries) ~= "table" then return nil end
    local e
    for i = 1, #entries do
        local c = entries[i]
        if type(c) == "table" and c.key == primaryKey then e = c break end
    end
    if not e or e.state ~= "missing" then return nil end

    local plainMode = (colorize == false)
    local wrapName = plainMode and function(_, n) return n end
        or (type(colorize) == "function" and colorize)
        or function(class, n) return hex(classColor(class)) .. n .. "|r" end
    local wrapQuiet = plainMode and function(s) return s end or gray
    local wrapLoud  = plainMode and function(s) return s end or accent

    local name = e.isSelf and "You" or e.name
    local skill, reqN = tonumber(e.skill), tonumber(req)
    local suffix = (skill and reqN) and string.format(" (%d/%d)", skill, reqN)
        or (skill and string.format(" (%d)", skill) or "")
    return {
        kind  = "primary",
        text  = wrapLoud("Primary missing:") .. " "
                .. wrapName(e.class, name) .. wrapQuiet(suffix),
        plain = "Primary missing: " .. name .. suffix,
    }
end

-- Live: resolve the viewer's-faction primary for this recipe's lane and build
-- the row. Degrades to nil at every rung (no module, no faction, no
-- designation, record vanished, unproven).
function Tooltips.RecipePrimaryRowLive(facts, entries)
    local P = ns.Professions
    if not (P and P.ResolvePrimary and type(facts) == "table") then return nil end
    -- The viewer's faction, the ~1343 UnitFactionGroup precedent below.
    local faction = (_G.UnitFactionGroup and _G.UnitFactionGroup("player")) or nil
    if not faction then return nil end
    local primaryKey = P.ResolvePrimary(faction, facts.profKey, facts.specID)
    if not primaryKey then return nil end
    return Tooltips.RecipePrimaryRow(entries, primaryKey, facts.req)
end

----------------------------------------------------------------------
-- LIVE: collecting the candidate characters
----------------------------------------------------------------------

-- Class tag and side for every character the account graph knows, keyed by
-- "Name-Realm". Account buckets are walked in sorted id order and the first
-- writer wins, so a character parked under two buckets always resolves to the
-- same record rather than to whichever one pairs() happened to reach first.
function Tooltips.CharMeta()
    local out = {}
    local S = ns.Store
    local data = S and S.GetData and S.GetData()
    local accounts = data and data.accounts
    if type(accounts) ~= "table" then return out end
    local aids = {}
    for aid in pairs(accounts) do aids[#aids + 1] = tostring(aid) end
    table.sort(aids)
    local selfID = (ns.GetAccountID and ns:GetAccountID()) or nil
    if selfID and accounts[selfID] then table.insert(aids, 1, tostring(selfID)) end
    for _, aid in ipairs(aids) do
        local bucket = accounts[aid]
        if type(bucket) == "table" then
            for _, field in ipairs({ "characters", "homeless" }) do
                local t = bucket[field]
                if type(t) == "table" then
                    for key, rec in pairs(t) do
                        if type(key) == "string" and type(rec) == "table" and out[key] == nil then
                            out[key] = { class = rec.classTag, faction = rec.faction }
                        end
                    end
                end
            end
        end
    end
    return out
end

-- PURE. ownerKeys -> display name per key. A bare first name normally; the full
-- "Name-Realm" for any name two characters share, so the block never shows the
-- same label twice meaning two different alts.
function Tooltips.RecipeDisplayNames(keys)
    local seen, out = {}, {}
    for i = 1, #keys do
        local name = keys[i]:match("^([^%-]+)") or keys[i]
        seen[name] = (seen[name] or 0) + 1
    end
    for i = 1, #keys do
        local name = keys[i]:match("^([^%-]+)") or keys[i]
        out[keys[i]] = (seen[name] > 1) and keys[i] or name
    end
    return out
end

-- The candidate list for one recipe, read from the professions owners graph.
-- Every character that HAS the profession contributes exactly one entry; a
-- character with no record of it contributes nothing at all. The VIEWER is a
-- candidate like any other — same bucket (their record is projected into
-- Store.ProfessionsOwners() by Publish/ProjectOwner, the same record the
-- professions tab reads), same eligibility, same gap accounting — the only
-- differences are the "You" label and the ordering pin, and both of those
-- live downstream of here (RecipeRows / BuildRecipeBlock) off the isSelf flag.
function Tooltips.RecipeEntries(facts, viewerKey)
    local out = {}
    local P, S = ns.Professions, ns.Store
    if not (P and P.KnownState and S and S.ProfessionsOwners) then return out end
    if type(facts) ~= "table" or not facts.profKey then return out end

    local owners = S.ProfessionsOwners()
    if type(owners) ~= "table" then return out end

    local keys, otherKeys = {}, {}
    for key in pairs(owners) do
        if type(key) == "string" and key ~= "" then
            keys[#keys + 1] = key
            if key ~= viewerKey then otherKeys[#otherKeys + 1] = key end
        end
    end
    table.sort(keys)                          -- class 8: one order, every hover
    -- Collision detection runs over the OTHER characters only: the viewer's
    -- entry always renders as "You", so their bare name can never be the
    -- second meaning of a label, and a same-named alt keeps its short form.
    local names = Tooltips.RecipeDisplayNames(otherKeys)
    local meta  = Tooltips.CharMeta()

    for i = 1, #keys do
        local key = keys[i]
        local entry = owners[key]
        local payload = type(entry) == "table" and entry.data or nil
        local prec = (type(payload) == "table" and type(payload.p) == "table")
                     and payload.p[facts.profKey] or nil
        if prec then
            local state, skill = P.KnownState(payload, facts.profKey, facts.spell)
            local m = meta[key] or EMPTY
            out[#out + 1] = {
                key    = key,
                name   = names[key] or key:match("^([^%-]+)") or key,
                class  = m.class,
                state  = state,
                skill  = skill,
                specs  = (type(prec.s) == "table") and prec.s or nil,
                isSelf = (viewerKey ~= nil and key == viewerKey) or nil,
            }
        end
    end
    return out
end

-- Session cache: itemID -> facts|false. A bag full of recipes hovers the same
-- ids over and over, and the dataset is frozen, so this is answered once.
-- Dropped when the module is toggled (Invalidate is called from the same
-- store-refresh signal the owners cache listens to).
Tooltips._recipeFacts = nil

function Tooltips.InvalidateRecipes()
    Tooltips._recipeFacts = nil
end

-- itemID -> { profKey, spell, req, specID, prof } or nil.
function Tooltips.ResolveRecipeItem(itemID)
    itemID = tonumber(itemID)
    if not itemID then return nil end
    Tooltips._recipeFacts = Tooltips._recipeFacts or {}
    local hit = Tooltips._recipeFacts[itemID]
    if hit ~= nil then return hit or nil end

    local P = ns.Professions
    local D = P and P.Dataset
    local facts
    if D and D.RecipeItemSpell then
        local spell = D.RecipeItemSpell(itemID)
        if spell and D.RecipeFacts then facts = D.RecipeFacts(spell) end
    end
    Tooltips._recipeFacts[itemID] = facts or false
    return facts
end

-- Append the recipe block to a tooltip that has just been populated for an item.
function Tooltips.AppendRecipeLines(tt)
    if type(tt) ~= "table" and type(tt) ~= "userdata" then return end
    if tt.__dsnRecipeShown then return end            -- one block per populate
    local active, why = Tooltips.RecipeStatus()
    if not active then
        -- Only the third-party collision is worth a word; "the module is off"
        -- is the player's own doing and needs no announcement.
        if why and why:find(Tooltips.MTSL_ADDON, 1, true) then
            Tooltips.NoteRecipeStandDown(why)
        end
        return
    end

    local getItem = tt.GetItem
    if not getItem then return end
    local _, link = getItem(tt)
    if not link then return end
    local getInstant = _G.GetItemInfoInstant
        or (_G.C_Item and _G.C_Item.GetItemInfoInstant)
    if not getInstant then return end
    -- The id comes out of the LINK, not out of the item cache, so a cold item
    -- resolves exactly as well as a warm one (the addendum's §5.5 "no item-cache
    -- guard" defect cannot occur here: there is nothing to be cold about).
    local itemID, _, _, _, _, classID = getInstant(link)
    if not itemID then return end
    -- Cheap pre-filter so a player who never hovers a recipe never causes the
    -- item index to be built at all. The class is a SHORTCUT, never the
    -- authority: an unanswered class falls through to the dataset lookup. That
    -- distinction is the whole of the addendum's §5.2 ceiling — the examined
    -- implementation made a client classification the authority and lost
    -- poisons and fishing to it permanently.
    local RECIPE_CLASS = (_G.Enum and _G.Enum.ItemClass and _G.Enum.ItemClass.Recipe)
        or _G.LE_ITEM_CLASS_RECIPE or 9
    if classID ~= nil and classID ~= RECIPE_CLASS then return end

    local facts = Tooltips.ResolveRecipeItem(itemID)
    if not facts then return end                      -- not a recipe we carry

    local entries = Tooltips.RecipeEntries(facts, Tooltips.SelfKey())
    local block = Tooltips.BuildRecipeBlock(entries, facts.req, facts.specID)
    local rows = Tooltips.RecipeRows(block, facts.req)
    -- The delegate loud line sits ABOVE Known/Learnable (deterministic: one
    -- resolved primary, one row, always position 1 when present).
    local prow = Tooltips.RecipePrimaryRowLive(facts, entries)
    if prow then table.insert(rows, 1, prow) end
    if #rows == 0 then return end
    tt.__dsnRecipeShown = true

    local r, g, b = creamRGB()
    if tt.AddLine then tt:AddLine(" ") end
    for _, row in ipairs(rows) do
        -- wrap = true: a realm full of alts wraps inside the tooltip rather than
        -- stretching it across the screen or being truncated. Nothing is hidden.
        if tt.AddLine then tt:AddLine(row.text, r, g, b, true) end
    end
    if tt.Show then tt:Show() end
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
                -- ONE hook, two blocks, in reading order: what this item MEANS
                -- for the roster first (it is a recipe, and here is who wants
                -- it), then how many of it the roster already holds. Each
                -- appender owns its own gate and its own latch; neither can
                -- suppress the other.
                if ns.SafeCall then
                    ns:SafeCall(Tooltips.AppendRecipeLines, self)
                    ns:SafeCall(Tooltips.AppendCounts, self)
                else
                    Tooltips.AppendRecipeLines(self)
                    Tooltips.AppendCounts(self)
                end
            end)
            -- reset the guards whenever the tooltip is cleared/reused for a new item.
            tt:HookScript("OnTooltipCleared", function(self)
                self.__dsnCountsShown, self.__dsnRecipeShown = nil, nil
            end)
            tt:HookScript("OnHide", function(self)
                self.__dsnCountsShown, self.__dsnRecipeShown = nil, nil
            end)
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

-- The recipe facts cache is keyed on the FROZEN dataset, so a store refresh
-- cannot stale it — only the module being toggled can (a disabled module has
-- unloaded the dataset, and the cached answers came out of it). The owners the
-- block reads are fetched live per hover, so they need no cache of their own.
ns:On("PROFESSIONS_TOGGLED", function() Tooltips.InvalidateRecipes() end)

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
    local ractive, rwhy = Tooltips.RecipeStatus()
    ns:Print("  recipe lines: " .. (ractive and "ACTIVE" or "standing down")
        .. " — " .. tostring(rwhy))
    do
        local P = ns.Professions
        local D = P and P.Dataset
        local nOwners = 0
        if ns.Store and ns.Store.ProfessionsOwners then
            for _ in pairs(ns.Store.ProfessionsOwners()) do nOwners = nOwners + 1 end
        end
        local nItems = 0
        if D and D.itemOfRecipe then for _ in pairs(D.itemOfRecipe) do nItems = nItems + 1 end end
        ns:Print(string.format("    mtsl=%s | professions owners=%d | recipe-item index=%s",
            tostring(Tooltips.ProbeMTSL().mtslLoaded), nOwners,
            (nItems > 0) and tostring(nItems) or "not built"))
    end
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

    ------------------------------------------------------------------
    -- RECIPE LINES (wave P3). The rows below are the whole contract:
    -- who lands on which line, what an unproven alt does, and the ONE
    -- thing the block may never say.
    ------------------------------------------------------------------
    do
        local function rowKinds(rs)
            local out = {} for i, r in ipairs(rs) do out[i] = r.kind end
            return table.concat(out, ",")
        end
        local function plain(rs, kind)
            for _, r in ipairs(rs) do if r.kind == kind then return r.plain end end
            return nil
        end

        -- The population: one of each state, against a recipe needing skill 275.
        local entries = {
            { name = "Knower",  class = "MAGE",    state = "known",   skill = 300 },
            { name = "Able",    class = "PRIEST",  state = "missing", skill = 285 },
            { name = "Short",   class = "WARRIOR", state = "missing", skill = 120 },
            { name = "Ghost",   class = "ROGUE",   state = "unknown", skill = 300 },
        }
        local block = Tooltips.BuildRecipeBlock(entries, 275, nil)
        local rows = Tooltips.RecipeRows(block, 275, false)
        ck("recipe/anatomy", rowKinds(rows) == "known,learnable,unscanned")
        ck("recipe/known", plain(rows, "known") == "Known: Knower")
        ck("recipe/learnable", plain(rows, "learnable") == "Learnable: Able (285/275)")
        ck("recipe/skill-short-dropped",
            not (plain(rows, "learnable") or ""):find("Short", 1, true))
        ck("recipe/unscanned-line", plain(rows, "unscanned") == "(1 character unscanned)")

        -- THE POLARITY RED CONTROL. This is the reproduced defect
        -- (PROFESSIONS_DATASET_ADDENDUM §5.3): an alt we have never scanned
        -- listed as KNOWING the recipe. Our chain has no path that does it.
        ck("recipe/polarity",
            not (plain(rows, "known") or ""):find("Ghost", 1, true))
        ck("recipe/polarity-not-learnable",
            not (plain(rows, "learnable") or ""):find("Ghost", 1, true))
        ck("recipe/polarity-counted", block.unscanned == 1)
        -- ...and an all-unknown roster says so instead of saying nothing.
        do
            local dark = Tooltips.BuildRecipeBlock(
                { { name = "A", state = "unknown" }, { name = "B", state = "unknown" } }, 275)
            local drows = Tooltips.RecipeRows(dark, 275, false)
            ck("recipe/all-dark", rowKinds(drows) == "unscanned")
            ck("recipe/all-dark-count", plain(drows, "unscanned") == "(2 characters unscanned)")
        end
        -- A fully-proven roster shows NO third line. Absence of the line is
        -- itself the claim "we have an answer for everyone".
        do
            local clean = Tooltips.BuildRecipeBlock(
                { { name = "A", state = "known" },
                  { name = "B", state = "missing", skill = 300 } }, 275)
            ck("recipe/no-gap-line", #Tooltips.RecipeRows(clean, 275, false) == 2)
        end

        -- SPECIALISATION GATE: same skill, only the holder is learnable, and the
        -- non-holder is a PROVEN negative — not a gap.
        do
            local spec = Tooltips.BuildRecipeBlock({
                { name = "Gnomer", state = "missing", skill = 300, specs = { 20219 } },
                { name = "Goblin", state = "missing", skill = 300, specs = { 20222 } },
                { name = "Plain",  state = "missing", skill = 300 },
            }, 275, 20219)
            local srows = Tooltips.RecipeRows(spec, 275, false)
            ck("recipe/spec-gate", plain(srows, "learnable") == "Learnable: Gnomer (300/275)")
            ck("recipe/spec-not-a-gap", spec.unscanned == 0)
            ck("recipe/spec-ok", Tooltips.RecipeSpecOK({ specs = { 1, 2, 3 } }, 2) == true
                and Tooltips.RecipeSpecOK({ specs = { 1, 3 } }, 2) == false
                and Tooltips.RecipeSpecOK({}, nil) == true)
        end

        -- ONE SPEC RULE, not two: the Learnable gate is the professions
        -- module's tree-aware predicate, so a spec that IMPLIES the gate
        -- (a child spec holds its parent) is learnable, and a spec that is
        -- merely on the way to it is not. Structural — a spec with a parent
        -- and a sibling under that parent, read off the shipped edges.
        do
            local D = ns.Professions and ns.Professions.Dataset
            if D and D.LoadCore and D.LoadCore() then
                local kid, par, sib
                for i = 1, #D.specs do
                    local s = D.specs[i]
                    if s.parent then
                        for j = 1, #D.specs do
                            if j ~= i and D.specs[j].parent == s.parent then sib = D.specs[j] break end
                        end
                        if sib then kid, par = s, D.specs[s.parent] break end
                    end
                end
                if kid then
                    ck("recipe/spec-tree-implies",
                       Tooltips.RecipeSpecOK({ specs = { kid.id } }, par.id) == true)
                    ck("recipe/spec-tree-not-yet",
                       Tooltips.RecipeSpecOK({ specs = { par.id } }, kid.id) == false)
                    ck("recipe/spec-tree-sibling",
                       Tooltips.RecipeSpecOK({ specs = { sib.id } }, kid.id) == false)
                    local blk = Tooltips.BuildRecipeBlock({
                        { name = "Master", state = "missing", skill = 300,
                          specs = { par.id, kid.id } },
                        { name = "Plain",  state = "missing", skill = 300, specs = { par.id } },
                    }, 275, par.id)
                    ck("recipe/spec-tree-learnable",
                       #blk.learnable == 2 and blk.unscanned == 0)
                end
            end
        end

        -- A scanned alt whose SKILL never resolved cannot be judged, so it is a
        -- gap, not a silent omission (truthy-zero class 5: nil ~= 0).
        do
            local noskill = Tooltips.BuildRecipeBlock(
                { { name = "Blank", state = "missing", skill = nil } }, 275)
            ck("recipe/skill-nil-is-a-gap", noskill.unscanned == 1
                and #noskill.learnable == 0)
            local zero = Tooltips.BuildRecipeBlock(
                { { name = "Zero", state = "missing", skill = 0 } }, 275)
            ck("recipe/skill-zero-is-an-answer", zero.unscanned == 0
                and #zero.learnable == 0)
        end

        -- Ordering is fixed, not inherited from a table walk (class 8).
        do
            local many = Tooltips.BuildRecipeBlock({
                { name = "Zeta",  state = "known" },
                { name = "Alpha", state = "known" },
                { name = "Low",   state = "missing", skill = 280 },
                { name = "High",  state = "missing", skill = 300 },
            }, 275)
            local mrows = Tooltips.RecipeRows(many, 275, false)
            ck("recipe/known-sorted", plain(mrows, "known") == "Known: Alpha, Zeta")
            ck("recipe/learnable-best-first",
                plain(mrows, "learnable") == "Learnable: High (300/275), Low (280/275)")
        end

        -- SELF (owner ruling 2026-08). The viewer is a candidate like any
        -- other — same eligibility, same gap accounting — rendered "You" and
        -- PINNED first in its line, ahead of the deterministic order.
        do
            -- Learnable: self's skill is deliberately the LOWEST qualifying
            -- one, so only the pin (not skill-desc) can put "You" first.
            local sl = Tooltips.BuildRecipeBlock({
                { name = "High",   class = "MAGE",   state = "missing", skill = 300 },
                { name = "Mid",    class = "DRUID",  state = "missing", skill = 295 },
                { name = "Poonyx", class = "PRIEST", state = "missing", skill = 280, isSelf = true },
            }, 275)
            local slr = Tooltips.RecipeRows(sl, 275, false)
            ck("recipe/self-learnable-you-first", plain(slr, "learnable")
                == "Learnable: You (280/275), High (300/275), Mid (295/275)")
            -- ...and the character's own name never leaks past the label.
            ck("recipe/self-name-hidden",
                not (plain(slr, "learnable") or ""):find("Poonyx", 1, true))

            -- Known: self would sort LAST by name; the pin still wins.
            local sk = Tooltips.BuildRecipeBlock({
                { name = "Zzz",   class = "PRIEST", state = "known", isSelf = true },
                { name = "Alpha", class = "MAGE",   state = "known" },
            }, 275)
            local skr = Tooltips.RecipeRows(sk, 275, false)
            ck("recipe/self-known-you-first", plain(skr, "known") == "Known: You, Alpha")
            -- The coloured path wraps "You" in the VIEWER's class, through the
            -- injectable colorize seam.
            local ckr = Tooltips.RecipeRows(sk, 275,
                function(class, n) return "[" .. tostring(class) .. "]" .. n end)
            local ktext
            for _, r in ipairs(ckr) do if r.kind == "known" then ktext = r.text end end
            ck("recipe/self-you-class-colored",
                (ktext or ""):find("[PRIEST]You", 1, true) ~= nil)

            -- An unscanned self counts in the gap like anyone else — the name
            -- and the ordering are the ONLY special-casing.
            local su = Tooltips.BuildRecipeBlock({
                { name = "Poonyx", class = "PRIEST", state = "unknown", isSelf = true },
                { name = "Knower", class = "MAGE",   state = "known" },
            }, 275)
            local sur = Tooltips.RecipeRows(su, 275, false)
            ck("recipe/self-unscanned-counted", su.unscanned == 1
                and plain(sur, "unscanned") == "(1 character unscanned)")
            ck("recipe/self-unscanned-not-listed",
                not (plain(sur, "known") or ""):find("You", 1, true))

            -- A viewer with NO profession record contributes no entry at all
            -- (RecipeEntries emits nothing for them), so no "You" anywhere —
            -- the pre-ruling behaviour for that case, unchanged.
            local noSelf = Tooltips.BuildRecipeBlock({
                { name = "Knower", class = "MAGE",   state = "known" },
                { name = "Able",   class = "PRIEST", state = "missing", skill = 285 },
            }, 275)
            for _, r in ipairs(Tooltips.RecipeRows(noSelf, 275, false)) do
                ck("recipe/no-self-no-you", not r.plain:find("You", 1, true))
            end

            -- DETERMINISM PIN (class 8): two builds of the same block are
            -- byte-identical, coloured and plain.
            local function build()
                local b = Tooltips.BuildRecipeBlock({
                    { name = "High",   class = "MAGE",    state = "missing", skill = 300 },
                    { name = "Mid",    class = "DRUID",   state = "missing", skill = 295 },
                    { name = "Poonyx", class = "PRIEST",  state = "known",   isSelf = true },
                    { name = "Alpha",  class = "WARRIOR", state = "known" },
                    { name = "Ghost",  class = "ROGUE",   state = "unknown" },
                }, 275)
                local out = {}
                for _, r in ipairs(Tooltips.RecipeRows(b, 275, false)) do
                    out[#out + 1] = r.plain
                end
                for _, r in ipairs(Tooltips.RecipeRows(b, 275)) do
                    out[#out + 1] = r.text
                end
                return table.concat(out, "\n")
            end
            ck("recipe/self-deterministic", build() == build())
        end

        -- Empty in, empty out — no headings over nothing.
        ck("recipe/empty", #Tooltips.RecipeRows(Tooltips.BuildRecipeBlock({}, 275), 275, false) == 0)
        ck("recipe/nil-entries", Tooltips.BuildRecipeBlock(nil, 275).unscanned == 0)

        -- Display names: bare first name, full key only when two alts collide.
        do
            local nm = Tooltips.RecipeDisplayNames({ "Ann-A", "Ann-B", "Bob-A" })
            ck("recipe/name-collision", nm["Ann-A"] == "Ann-A" and nm["Ann-B"] == "Ann-B")
            ck("recipe/name-plain", nm["Bob-A"] == "Bob")
        end

        -- STAND-DOWN vs MissingTradeSkillsList, and its independence from the
        -- Bags stand-down that governs the count block.
        ck("recipe/mtsl-absent", Tooltips.MTSLOwnsRecipeLines({ mtslLoaded = false }) == false)
        ck("recipe/mtsl-loaded", Tooltips.MTSLOwnsRecipeLines({ mtslLoaded = true }) == true)
        ck("recipe/mtsl-nil", Tooltips.MTSLOwnsRecipeLines(nil) == false)
        do
            local G  = { C_AddOns = { IsAddOnLoaded = function() return true end } }
            local G2 = { IsAddOnLoaded = function() return false end }
            ck("recipe/probe-loaded", Tooltips.ProbeMTSL(G).mtslLoaded == true)
            ck("recipe/probe-absent", Tooltips.ProbeMTSL(G2).mtslLoaded == false)
        end
        do
            -- The recipe gate follows the PROFESSIONS module, never wealthTooltips,
            -- and the two blocks cannot switch each other off.
            local S = ns.Store
            local db = S and S.GetSettings and S.GetSettings()
            local P = ns.Professions
            if db and P and P.IsEnabled then
                local savedW, savedP = db.wealthTooltips, db.professionsEnabled
                db.wealthTooltips, db.professionsEnabled = false, true
                ck("recipe/independent-of-wealth", Tooltips.RecipeActive() == true
                    and Tooltips.Active() == false)
                db.professionsEnabled = false
                ck("recipe/module-off", Tooltips.RecipeActive() == false)
                -- INERTNESS: standing down happens before the dataset is asked
                -- anything, so a disabled module stays dataset-free.
                local D = P.Dataset
                if D and D.Unload then D.Unload() end
                Tooltips.InvalidateRecipes()
                local tt = { lines = {},
                             GetItem = function() return "R", "|Hitem:1:|h[R]|h" end,
                             AddLine = function(self, t) self.lines[#self.lines + 1] = t end,
                             Show = function() end }
                Tooltips.AppendRecipeLines(tt)
                ck("recipe/inert-no-lines", #tt.lines == 0)
                ck("recipe/inert-no-dataset", (D and D.IsLoaded and D.IsLoaded()) == false)
                ck("recipe/inert-no-itemindex", (D and D.itemOfRecipe) == nil)
                db.wealthTooltips, db.professionsEnabled = savedW, savedP
                Tooltips.InvalidateRecipes()
            end
        end

        -- The live entry point is a safe no-op on junk.
        ck("recipe/live-safe", pcall(Tooltips.AppendRecipeLines, {})
            and pcall(Tooltips.AppendRecipeLines, nil))
        -- One block per populate: the latch survives the client's double-fire.
        do
            local n = 0
            local tt = { AddLine = function() n = n + 1 end, Show = function() end,
                         GetItem = function() return nil end, __dsnRecipeShown = true }
            Tooltips.AppendRecipeLines(tt)
            ck("recipe/latched", n == 0)
        end

        ------------------------------------------------------------------
        -- THE DELEGATE LOUD LINE (profession-delegates phase 1). The lane
        -- walk and faction scoping live in Professions.ResolveDelegate and
        -- are pinned THERE; this matrix owns the rendering rules: proven-
        -- missing only, always-even-when-skill-short, "You", no line for
        -- known/unscanned/secondary/vanished, colorize-seam parity.
        ------------------------------------------------------------------
        do
            local dEntries = {
                { key = "Prim-R",  name = "Prim",  class = "MAGE",   state = "missing", skill = 285 },
                { key = "Short-R", name = "Short", class = "DRUID",  state = "missing", skill = 120 },
                { key = "Know-R",  name = "Know",  class = "PRIEST", state = "known",   skill = 300 },
                { key = "Dark-R",  name = "Dark",  class = "ROGUE",  state = "unknown" },
                { key = "Bare-R",  name = "Bare",  class = "SHAMAN", state = "missing", skill = nil },
                { key = "Self-R",  name = "Poonyx", class = "PRIEST", state = "missing",
                  skill = 280, isSelf = true },
            }
            local P = function(k) return Tooltips.RecipePrimaryRow(dEntries, k, 275, false) end

            -- proven missing -> the line, with current/required skill.
            local r = P("Prim-R")
            ck("primary/missing-fires", r ~= nil and r.kind == "primary"
                and r.plain == "Primary missing: Prim (285/275)")
            -- ALWAYS shown even when the skill is short (collection framing).
            ck("primary/skill-short-still-fires",
                (P("Short-R") or {}).plain == "Primary missing: Short (120/275)")
            -- a nil skill states nothing rather than inventing a number.
            ck("primary/nil-skill-no-numbers",
                (P("Bare-R") or {}).plain == "Primary missing: Bare")
            -- the primary knows it -> no line.
            ck("primary/known-silent", P("Know-R") == nil)
            -- unscanned primary -> no line (unproven is not missing)...
            ck("primary/unscanned-silent", P("Dark-R") == nil)
            -- ...and they still count in the gap line like anyone else.
            do
                local blk = Tooltips.BuildRecipeBlock(dEntries, 275, nil)
                ck("primary/unscanned-still-in-gap", blk.unscanned >= 1)
            end
            -- the primary IS the viewer -> "You" (the isSelf rendering).
            ck("primary/self-is-you",
                (P("Self-R") or {}).plain == "Primary missing: You (280/275)")
            -- a vanished/undesignated resolution (nil key) or a primary with
            -- no record of the profession (key not among the entries) -> nil.
            ck("primary/nil-key", P(nil) == nil)
            ck("primary/no-entry", P("Ghost-R") == nil)
            -- the colorize seam: the injected wrapper wears the class, the
            -- label survives verbatim, the word "You" is never rewrapped.
            do
                local cr = Tooltips.RecipePrimaryRow(dEntries, "Self-R", 275,
                    function(class, n) return "[" .. tostring(class) .. "]" .. n end)
                ck("primary/colorize-seam", cr ~= nil
                    and cr.text:find("[PRIEST]You", 1, true) ~= nil
                    and cr.text:find("Primary missing:", 1, true) ~= nil)
            end
            -- determinism (class 8): same inputs, byte-identical row, both forms.
            do
                local a1, a2 = P("Prim-R"), P("Prim-R")
                local c1 = Tooltips.RecipePrimaryRow(dEntries, "Prim-R", 275)
                local c2 = Tooltips.RecipePrimaryRow(dEntries, "Prim-R", 275)
                ck("primary/deterministic", a1.plain == a2.plain and c1.text == c2.text)
            end
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
