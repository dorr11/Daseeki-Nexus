-- Daseeki Nexus — ui_instancespanel.lua
-- The INSTANCES PANEL — the lower-left panel of the control-panel dashboard's panel
-- layer (owner round-6). It REPLACES the retired Instances TAB (ui_tab_instances.lua):
-- the tab dissolves into this compact panel that sits beside the timers panel in the
-- bottom row of the Characters screen. Content: per-account instance-cap meters (hour
-- + day rolling windows) + a short newest-first recent-entries list.
--
-- The proven view-model logic is re-housed here verbatim from the retired tab as
-- ns.InstancesUI (meter-state classification, cap model, money/ago/row formatting,
-- entry gather/filter, account sort, class lookup) — all pure and headless-tested.
--
-- AESTHETIC (control-panel + round-4 pop pass): flat token fills, uppercase micro
-- labels at `muted`, borderLite edges, attention-inverted meter tokens (calm under
-- cap, amber at warn, danger at cap). No grain/serif. All colors via theme tokens.
--
-- Clean-room build on our own DaseekiUI stack. No third-party code or identifiers.

local ADDON, ns = ...
local UI = DaseekiUI                 -- nil under the headless harness; only ever
local Dashboard = ns.Dashboard       -- dereferenced inside function bodies below.

local InstancesUI = {}
ns.InstancesUI = InstancesUI
local InstancesPanel = {}
ns.InstancesPanel = InstancesPanel

-- ════════════════════════════════════════════════════════════════════════════
--  PURE VIEW-MODEL LOGIC (frame-free → headless-tested). Re-housed verbatim from
--  the retired ui_tab_instances.lua.
-- ════════════════════════════════════════════════════════════════════════════

-- Attention-inverted token per meter state: calm under cap, amber at warn, danger cap.
local STATE_TOKEN = { ok = "muted", warn = "warn", cap = "danger" }
function InstancesUI.StateToken(state) return STATE_TOKEN[state] or "muted" end

-- Classify a rolling-window count against its cap + warn threshold. Pure.
function InstancesUI.MeterState(count, cap, warn)
    count = count or 0
    if cap and count >= cap then return "cap" end
    if warn and count >= warn then return "warn" end
    return "ok"
end

-- Seconds until a rolling-window slot re-opens (nextSlotAt - now), floored at 0. Pure.
function InstancesUI.NextSlotSeconds(nextSlotAt, nowE)
    if not nextSlotAt then return nil end
    local rem = nextSlotAt - (nowE or 0)
    if rem < 0 then rem = 0 end
    return math.floor(rem)
end

-- Countdown numerals as M:SS. Pure.
function InstancesUI.FormatMSS(sec)
    sec = math.max(0, math.floor(sec or 0))
    return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
end

-- Assemble a per-account meter model from the engine's WindowCounts shape. Pure.
function InstancesUI.MeterModel(counts, nowE, caps)
    counts = counts or {}
    local E = caps or ns.Instances or {}
    local hCap, hWarn = E.HOURLY_CAP or 5,  E.WARN_HOURLY or 4
    local dCap, dWarn = E.DAILY_CAP or 30,  E.WARN_DAILY  or 27
    local hState = InstancesUI.MeterState(counts.hour, hCap, hWarn)
    local dState = InstancesUI.MeterState(counts.day,  dCap, dWarn)
    local model = {
        hour = { count = counts.hour or 0, cap = hCap, state = hState,
                 token = InstancesUI.StateToken(hState), atCap = (hState == "cap") },
        day  = { count = counts.day or 0,  cap = dCap, state = dState,
                 token = InstancesUI.StateToken(dState), atCap = (dState == "cap") },
    }
    if model.hour.atCap then model.hour.countdown = InstancesUI.NextSlotSeconds(counts.nextHourSlotAt, nowE) end
    if model.day.atCap  then model.day.countdown  = InstancesUI.NextSlotSeconds(counts.nextDaySlotAt,  nowE) end
    return model
end

-- The cross-account TOTAL row. Deliberately NOT a MeterModel: the server enforces
-- the 5/hr and 30/day limits PER ACCOUNT, so a sum across accounts has no cap to
-- be measured against. Feeding it through MeterModel made the row read
-- "Hr 9/5" in the danger token permanently the moment a second account was
-- active -- a red meter that means nothing. The total renders as a bare count,
-- neutral token, no cap denominator and no countdown. Pure.
function InstancesUI.TotalModel(total)
    total = total or {}
    return {
        neutral = true,
        hour = { count = total.hour or 0, cap = nil, state = "none", token = "muted", atCap = false },
        day  = { count = total.day  or 0, cap = nil, state = "none", token = "muted", atCap = false },
    }
end

-- Meter row text for either model shape: "Hr 3/5" for a capped account row,
-- "Hr 9" for the uncapped total. Pure.
function InstancesUI.MeterText(label, cell)
    cell = cell or {}
    local txt = cell.cap and ("%s %d/%d"):format(label, cell.count or 0, cell.cap)
                        or  ("%s %d"):format(label, cell.count or 0)
    if cell.countdown then txt = txt .. " " .. InstancesUI.FormatMSS(cell.countdown) end
    return txt
end

-- Signed copper -> "Ng Ms" / "Ms Nc" / "Nc" (compact register cell). Pure.
function InstancesUI.FormatMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    local sign = ""
    if copper < 0 then sign = "-"; copper = -copper end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("%s%dg %ds", sign, g, s) end
    if s > 0 then return string.format("%s%ds %dc", sign, s, c) end
    return string.format("%s%dc", sign, c)
end

-- Signed copper -> the FULL coin form "4g 82s 10c", dropping only the leading
-- units that are zero. The compact FormatMoney above stops at two units because
-- it feeds a 42px register cell; the row hover has the room for the real figure,
-- and "raw gold from mobs" is one of the numbers the owner reads off it. Pure.
function InstancesUI.FormatMoneyFull(copper)
    copper = math.floor(tonumber(copper) or 0)
    local sign = ""
    if copper < 0 then sign = "-"; copper = -copper end
    local g = math.floor(copper / 10000)
    local s = math.floor((copper % 10000) / 100)
    local c = copper % 100
    if g > 0 then return string.format("%s%dg %ds %dc", sign, g, s, c) end
    if s > 0 then return string.format("%s%ds %dc", sign, s, c) end
    return string.format("%s%dc", sign, c)
end

-- An epoch -> a wall-clock time the owner can match against their evening:
-- "8:42 PM" for today, "12 Aug 8:42 PM" for anything older. 12-hour, matching
-- the reference's own default.
--
-- SIMPLIFICATION: entry epochs are SERVER time and this renders them through the
-- local clock, so a player whose realm sits in another timezone reads a shifted
-- clock. Differencing GetGameTime() against the local clock to correct that is a
-- whole feature of its own; every OTHER figure in the block (durations, "ago")
-- is a difference of epochs and is timezone-proof either way. Pure given a clock.
function InstancesUI.ClockText(epoch, nowE)
    epoch = tonumber(epoch)
    if not epoch or epoch <= 0 then return nil end
    local D = date or (os and os.date)
    if not D then return nil end
    local ok, hm = pcall(D, "%I:%M %p", epoch)
    if not ok or type(hm) ~= "string" or hm == "" then return nil end
    hm = hm:gsub("^0", "")
    if nowE then
        local ok2, dayA = pcall(D, "%Y%m%d", epoch)
        local ok3, dayB = pcall(D, "%Y%m%d", nowE)
        if ok2 and ok3 and dayA ~= dayB then
            local ok4, dm = pcall(D, "%d %b", epoch)
            if ok4 and type(dm) == "string" then
                return (dm:gsub("^0", "")) .. " " .. hm
            end
        end
    end
    return hm
end

-- Mobs killed on a run: the XP-derived count when it has anything to say, else
-- the combat-log count (spec §3.4 — the second exists so a boosted run of grey
-- mobs, which yields no XP at all, still reports a kill count). Pure.
function InstancesUI.MobCount(entry)
    entry = entry or {}
    local byXP = math.floor(tonumber(entry.mobXP) or 0)
    if byXP > 0 then return byXP, "xp" end
    local byKill = math.floor(tonumber(entry.mobKill) or 0)
    if byKill > 0 then return byKill, "kill" end
    return 0, nil
end

-- "just now" under a minute, else "<duration> ago". Pure.
function InstancesUI.AgoText(sec)
    sec = math.max(0, math.floor(sec or 0))
    if sec < 60 then return "just now" end
    local D = ns.Dashboard
    local dur = (D and D.FormatDuration and D.FormatDuration(sec)) or (math.floor(sec / 60) .. "m")
    return dur .. " ago"
end

-- ── ONE ROW PER PHYSICAL INSTANCE (owner: "if i leave and re-enter the same
--    instance, without resetting it, then that should show as a single line,
--    rather than 2") ───────────────────────────────────────────────────────────
--
-- The grouping key is the SERVER INSTANCE SERIAL, and nothing weaker. Two visits
-- collapse into one row iff the server says they were the same live instance —
-- exactly the rule the cap math already runs on. A reset-and-rerun of the same
-- dungeon gets a new serial, bills its own slot, and KEEPS ITS OWN ROW: those
-- rows are the owner's evidence of where the five went.
--
-- CAP MATH IS UNTOUCHED. This is a presentation fold over the same entries; each
-- visit still carries its own `merged` flag and still counts (or doesn't) exactly
-- as it did. Nothing here writes to the ledger.
--
-- SERIAL-LESS LEGACY ROWS. An entry that never observed a serial (an old Nexus
-- build, or a run where nothing was moused over, targeted, cast or swung before
-- the player left) cannot be joined on identity. For those, and ONLY those, a
-- deliberately narrow continuation heuristic applies — same account, same
-- character, same instance, the earlier visit actually recorded an exit, and the
-- re-entry happened within LEGACY_JOIN_GAP of it. When any of that is missing the
-- rows stay separate: a wrongly-folded row HIDES a run the owner paid a slot for,
-- which is much worse than showing a corpse run twice.
--
-- IMPORTED ROWS ARE NEVER FOLDED. Per the behaviour spec §8.3 a merged run does
-- not physically exist in the source file — the source deletes it and folds its
-- totals into the survivor — so every imported record is ALREADY a distinct
-- instance entry. Import stamps `src`, and any entry carrying it is excluded from
-- the legacy heuristic outright. (Imported entries that carry a serial still
-- group on it, which is the correct and lossless path.)
InstancesUI.LEGACY_JOIN_GAP = 600      -- 10 min: a corpse run, not a farm loop

-- May a serial-less entry continue the serial-less run before it? Pure.
function InstancesUI.LegacyContinues(prevEntry, entry, gap)
    if type(prevEntry) ~= "table" or type(entry) ~= "table" then return false end
    if prevEntry.src or entry.src then return false end            -- imported: never
    if (tonumber(prevEntry.serial) or 0) > 0 then return false end
    if (tonumber(entry.serial) or 0) > 0 then return false end
    local exitT = tonumber(prevEntry.exitT) or 0
    if exitT <= 0 then return false end                            -- no closing sample
    local t = tonumber(entry.t) or 0
    if t < exitT then return false end
    return (t - exitT) <= (gap or InstancesUI.LEGACY_JOIN_GAP)
end

-- Fold a GatherEntries list (newest-first) into display groups, newest-first.
-- Each group: { aid, nameRealm, key, t (newest), primary, visits (OLDEST first),
--               legacy = true when it was built by the heuristic }.
-- `primary` is the surviving entry — the one the engine folded totals into.
-- Pure.
function InstancesUI.GroupVisits(list, opts)
    local gap = (opts and opts.legacyGap) or InstancesUI.LEGACY_JOIN_GAP
    local asc = {}
    for i = #(list or {}), 1, -1 do asc[#asc + 1] = list[i] end
    local groups, bySerial, lastLegacy = {}, {}, {}
    for _, item in ipairs(asc) do
        local e = item.entry or {}
        local who = tostring(item.aid) .. "\1" .. tostring(item.nameRealm)
        local place = tostring(e.mapID or e.name or "?")
        local serial = tonumber(e.serial) or 0
        local g
        if serial > 0 then
            local key = who .. "\1" .. place .. "\1s" .. serial
            g = bySerial[key]
            if not g then
                g = { aid = item.aid, nameRealm = item.nameRealm, key = key, visits = {} }
                bySerial[key] = g
                groups[#groups + 1] = g
            end
        else
            local lkey = who .. "\1" .. place
            local last = lastLegacy[lkey]
            if last and InstancesUI.LegacyContinues(last.entry, e, gap) then g = last.group end
            if not g then
                g = { aid = item.aid, nameRealm = item.nameRealm, legacy = true, visits = {},
                      key = lkey .. "\1L" .. tostring(e.t or 0) }
                groups[#groups + 1] = g
            end
            lastLegacy[lkey] = { group = g, entry = e }
        end
        g.visits[#g.visits + 1] = item
        -- The survivor: the first NON-merged visit (the engine folds into it).
        if not g.primary then g.primary = e
        elseif g.primary.merged and not e.merged then g.primary = e end
        if (g.t or -math.huge) < (e.t or 0) then g.t = e.t or 0 end
    end
    for i = 1, #groups do
        local g = groups[i]
        g.primary = g.primary or (g.visits[1] and g.visits[1].entry) or {}
        g.count = #g.visits
    end
    table.sort(groups, function(a, b)
        if (a.t or 0) ~= (b.t or 0) then return (a.t or 0) > (b.t or 0) end
        return tostring(a.key) < tostring(b.key)
    end)
    return groups
end

-- The numbers a grouped row shows. Pure.
--
-- THE ONE SUBTLETY: when the ENGINE merged the visits (any visit flagged
-- `merged`), the survivor ALREADY carries the folded coin / XP / mob totals —
-- Instances.ApplySerial added them in at merge time — so summing across visits
-- would count them twice. Its exit epoch is likewise restamped at the true end of
-- the whole run, so its duration already spans the corpse run and the gap. For
-- an engine-folded group every total therefore comes from the survivor alone.
-- Only a LEGACY (heuristic) group, whose entries were never folded by anything,
-- is summed.
-- `isOpen` marks the LIVE run: it applies to the survivor on an engine-folded
-- group (the open run continues on it) and to the newest visit otherwise, so a
-- grouped row still reports live elapsed while the character is still inside.
function InstancesUI.AggregateVisits(visits, nowE, isOpen)
    local E = ns.Instances
    local folded, primary = false, nil
    for i = 1, #(visits or {}) do
        local e = visits[i].entry or {}
        if e.merged then folded = true elseif not primary then primary = e end
    end
    primary = primary or (visits and visits[1] and visits[1].entry) or {}
    local function dur(e, isOpen)
        return (E and E.EntryDuration and E.EntryDuration(e, nowE, isOpen)) or (e.dur or 0)
    end
    local agg = { count = #(visits or {}), folded = folded, primary = primary }
    if folded then
        agg.dur      = dur(primary, isOpen)
        agg.goldLoot = primary.goldLoot or 0
        agg.gold     = primary.gold or 0
        agg.xp       = math.max(0, primary.xp or 0)
        agg.mobXP    = primary.mobXP or 0
        agg.mobKill  = primary.mobKill or 0
    else
        agg.dur, agg.goldLoot, agg.gold, agg.xp, agg.mobXP, agg.mobKill = 0, 0, 0, 0, 0, 0
        local n = #(visits or {})
        for i = 1, n do
            local e = visits[i].entry or {}
            agg.dur      = agg.dur      + dur(e, isOpen and i == n)
            agg.goldLoot = agg.goldLoot + (e.goldLoot or 0)
            agg.gold     = agg.gold     + (e.gold or 0)
            agg.xp       = agg.xp       + math.max(0, e.xp or 0)
            agg.mobXP    = agg.mobXP    + (e.mobXP or 0)
            agg.mobKill  = agg.mobKill  + (e.mobKill or 0)
        end
    end
    return agg
end

-- Assemble one register-row model from an entry + resolved class. Pure.
-- Duration comes from Instances.EntryDuration, which prefers the PERSISTED exit
-- epoch: a run that spanned a /reload, relog, logout or disconnect used to have
-- no closing sample at all and reported 0s forever.
-- Gold prefers the loot-only accumulator over the wallet delta (the delta counts
-- repairs, vendor sales, reagents and mail, so a profitable Blackrock Depths run
-- reads negative); the delta remains the fallback for entries that predate the
-- accumulator. XP is the level-up-safe chat total and is never negative.
-- `visits` (optional) is a display group's OLDEST-first visit list; when given,
-- the row reports the whole physical instance rather than the single entry, and
-- the model carries the per-visit detail the hover renders.
function InstancesUI.RowModel(entry, nameRealm, classTag, nowE, isOpen, visits)
    entry = entry or {}
    local D = ns.Dashboard
    local E = ns.Instances
    local ago = (nowE or 0) - (entry.t or 0)
    if ago < 0 then ago = 0 end
    local agg = (visits and #visits > 0) and InstancesUI.AggregateVisits(visits, nowE, isOpen) or nil
    -- The newest visit's age is what the AGO column should read for a folded row.
    if agg then
        local newest = entry.t or 0
        for i = 1, #visits do
            local vt = (visits[i].entry and visits[i].entry.t) or 0
            if vt > newest then newest = vt end
        end
        ago = math.max(0, (nowE or 0) - newest)
    end
    local loot = agg and agg.goldLoot or (entry.goldLoot or 0)
    local wallet = agg and agg.gold or (entry.gold or 0)
    local gold = (loot ~= 0) and loot or wallet
    local xp = math.max(0, agg and agg.xp or entry.xp or 0)
    local dur = agg and agg.dur
                or (E and E.EntryDuration and E.EntryDuration(entry, nowE, isOpen))
                or (entry.dur or 0)
    local mobCount = InstancesUI.MobCount(agg or entry)

    -- Per-entry detail (all optional; a run that never captured it renders none).
    -- On a LEGACY multi-visit group the roster and trades are unioned across the
    -- visits, because no engine merge folded them together.
    local groupStr, groupAvg, trades = entry.group, entry.groupAvg, entry.trades
    if agg and not agg.folded and visits and #visits > 1 and E and E.UnionGroup then
        groupStr, trades = nil, nil
        for i = 1, #visits do
            local e = visits[i].entry or {}
            if e.group then
                local gs, ga = E.UnionGroup(groupStr, E.DecodeGroup(e.group))
                if gs then groupStr, groupAvg = gs, ga end
            end
            if type(e.trades) == "table" then
                trades = trades or {}
                for j = 1, #e.trades do trades[#trades + 1] = e.trades[j] end
            end
        end
    end
    local members = (E and E.DecodeGroup and E.DecodeGroup(groupStr)) or {}

    local visitList
    if visits and #visits > 1 then
        visitList = {}
        for i = 1, #visits do
            local e = visits[i].entry or {}
            visitList[i] = {
                t = e.t, merged = e.merged and true or false,
                clock = InstancesUI.ClockText(e.t, nowE),
            }
        end
    end

    return {
        ago       = ago,                       -- raw seconds (the compact cell layer reads this)
        agoText   = InstancesUI.AgoText(ago),
        nameRealm = nameRealm,
        classTag  = classTag,
        name      = (D and D.ShortName and D.ShortName(nameRealm))
                    or (nameRealm and nameRealm:match("^([^%-]+)")) or nameRealm,
        instance  = entry.name or "?",
        -- The register cell: a folded row carries "×2" so the fold is visible
        -- without hovering. One visit renders exactly the bare name it always did.
        instanceText = (entry.name or "?")
                       .. ((agg and agg.count > 1) and (" \195\151" .. agg.count) or ""),
        dur       = dur,
        durText   = (D and D.FormatDuration and D.FormatDuration(dur)) or (math.floor(dur) .. "s"),
        gold      = gold,
        goldFromLoot = (loot ~= 0),
        goldText  = InstancesUI.FormatMoney(gold),
        goldFullText = InstancesUI.FormatMoneyFull(gold),
        goldToken = (gold < 0) and "danger" or "muted",
        xp        = xp,
        xpText    = (xp ~= 0) and ("+" .. xp .. " xp") or nil,
        merged    = (entry.merged or (visitList ~= nil)) and true or false,
        -- ── the hover block ──
        serial       = entry.serial,
        entered      = entry.t,
        enteredText  = InstancesUI.ClockText(entry.t, nowE),
        left         = entry.exitT,
        leftText     = InstancesUI.ClockText(entry.exitT, nowE),
        mobCount     = mobCount,
        enteredLevel = entry.enteredLevel,
        groupAvg     = groupAvg,
        group        = members,
        trades       = trades,
        visits       = visitList,
        visitCount   = (agg and agg.count) or 1,
        folded       = (agg and agg.folded) or false,
    }
end

-- ── RECENT register CELLS (owner round-15 item 1) ───────────────────────────
-- The RECENT list now carries the numbers RowModel has always computed —
-- duration, gold and XP — ahead of the existing "ago" cell. The panel is 364
-- wide (344 of content) at row height 17, so the long forms RowModel produces
-- ("1h 12m", "4g 80s", "+1500 xp", "12h 30m ago" = ~250px of numerals alone)
-- do not fit beside a readable instance name. The cell layer below is the
-- COMPACT register form: it keeps the magnitude and the sign, drops the
-- secondary unit, and defers the exact figures to the row tooltip
-- (InstancesUI.RowTooltip). RowModel's long forms are untouched — this is a
-- presentation layer on top of them. All pure.

-- Signed copper -> single-unit cell: "48g" / "-12g" / "80s" / "35c". The
-- secondary unit is dropped (the tooltip carries the exact FormatMoney figure).
function InstancesUI.CompactMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    local sign = ""
    if copper < 0 then sign = "-"; copper = -copper end
    if copper >= 10000 then return sign .. math.floor(copper / 10000) .. "g" end
    if copper >= 100   then return sign .. math.floor(copper / 100) .. "s" end
    return sign .. copper .. "c"
end

-- XP -> "+950" / "+1.5k" / "+12.4k" / "+123k". Zero (and the legacy negatives
-- RowModel already floors at 0) render NO cell, matching RowModel.xpText.
function InstancesUI.CompactXP(xp)
    xp = math.floor(tonumber(xp) or 0)
    if xp <= 0 then return nil end
    if xp < 1000   then return "+" .. xp end
    if xp < 100000 then return ("+%.1fk"):format(xp / 1000) end
    return ("+%dk"):format(math.floor(xp / 1000))
end

-- Age -> "now" / "47m" / "1h12m" / "3d". The " ago" suffix is dropped: the
-- column caption above the list says AGO, so the suffix is pure width.
function InstancesUI.CompactAgo(sec)
    sec = math.max(0, math.floor(sec or 0))
    if sec < 60 then return "now" end
    local D = ns.Dashboard
    return (D and D.FormatDuration and D.FormatDuration(sec, "compact"))
           or (math.floor(sec / 60) .. "m")
end

-- One RowModel -> the four right-hand register cells. `gold` always renders (a
-- 0c run is a real result in the loot ledger); `xp` is nil-when-zero, keeping
-- RowModel.xpText's established convention. Token per RowModel (negative gold
-- -> danger). Pure.
function InstancesUI.RecentCells(model)
    model = model or {}
    local D = ns.Dashboard
    local dur = model.dur or 0
    return {
        dur       = (D and D.FormatDuration and D.FormatDuration(dur, "compact"))
                    or model.durText or (math.floor(dur) .. "s"),
        gold      = InstancesUI.CompactMoney(model.gold or 0),
        goldToken = model.goldToken or "muted",
        xp        = InstancesUI.CompactXP(model.xp or 0),
        ago       = InstancesUI.CompactAgo(model.ago or 0),
    }
end

-- The RECENT column budget in px. Lives HERE rather than as a panel-local so the
-- headless suite can assert the geometry still leaves a readable instance-name
-- flex if any column is ever re-tuned. `content` = panel width 364 (ui_cards
-- INST_W) minus the panel's 10px padding a side.
InstancesUI.RECENT_COLS = {
    content = 344, name = 56, dur = 38, gold = 42, xp = 38, ago = 38,
    gap = 5,   -- between the right-aligned numeral columns
    pad = 6,   -- either side of the flexing instance name
}

-- px left over for the flexing, ellipsising instance name. Pure.
function InstancesUI.InstanceFlexWidth(C)
    C = C or InstancesUI.RECENT_COLS
    local fixed = C.name + 2 * C.pad + C.dur + C.gold + C.xp + C.ago + 3 * C.gap
    return C.content - fixed
end

-- The group roster as a TWO-COLUMN name list: { {left, right}, ... }, each cell
-- "Bramble 57" and the character's own row annotated. Capped, with a "+N more"
-- tail so a 40-man raid cannot grow a tooltip past the screen. Pure.
function InstancesUI.GroupPairs(members, cap)
    cap = cap or 20
    members = members or {}
    local cells, over = {}, 0
    for i = 1, #members do
        local m = members[i] or {}
        if #cells >= cap then over = over + 1
        else
            local lvl = tonumber(m.level) or 0
            local txt = (lvl > 0) and (tostring(m.name) .. " " .. lvl) or tostring(m.name)
            if m.isSelf then txt = txt .. " (you)" end
            cells[#cells + 1] = txt
        end
    end
    local rows = {}
    for i = 1, #cells, 2 do rows[#rows + 1] = { cells[i], cells[i + 1] or "" } end
    if over > 0 then rows[#rows + 1] = { "+" .. over .. " more", "" } end
    return rows
end

-- One trade -> the hover line, in the reference's own phrasing. Pure.
function InstancesUI.TradeLine(tr, nowE)
    tr = tr or {}
    local who = tr.who or "?"
    local gave, got = math.floor(tonumber(tr.gave) or 0), math.floor(tonumber(tr.got) or 0)
    local F = InstancesUI.FormatMoneyFull
    local body
    if gave > 0 and got > 0 then
        body = ("Gave %s to %s, received %s"):format(F(gave), who, F(got))
    elseif gave > 0 then
        body = ("Gave %s to %s"):format(F(gave), who)
    else
        body = ("Received %s from %s"):format(F(got), who)
    end
    local when = tr.t and InstancesUI.AgoText((nowE or 0) - tr.t) or nil
    if when then body = body .. " \194\183 " .. when end
    return body
end

-- The row hover: the full per-instance block. Everything the compact register
-- cells abbreviate, plus the detail that never had anywhere to go — the serial
-- the row is grouped on, wall-clock entered/left, time inside, mobs killed, raw
-- mob coin, the level walked in at, the average group level, the roster, the
-- trades taken inside, and (when a physical instance was visited more than once)
-- the constituent visits. Frame-free; the panel walks these fields. Pure.
--
-- Every section is OMITTED when the run has no data for it, so a pre-detail
-- entry renders exactly the block it always did plus the clock lines.
function InstancesUI.RowTooltip(model, nowE)
    model = model or {}
    local lines = {}
    local function add(label, value) lines[#lines + 1] = { label, value } end

    if model.serial then add("Instance ID", tostring(model.serial)) end
    if model.enteredText then add("Entered", model.enteredText) end
    add("Left", model.leftText or "still inside")
    add("Time inside", model.durText or "")
    if (model.mobCount or 0) > 0 then add("Mobs killed", tostring(model.mobCount)) end
    add("Gold from mobs", (model.goldFullText or "")
        .. (model.goldFromLoot and " (looted)" or " (wallet delta)"))
    if model.xpText then add("XP", model.xpText) end
    if model.enteredLevel then add("Entered level", tostring(model.enteredLevel)) end
    if model.groupAvg then add("Average group level", string.format("%.1f", model.groupAvg)) end
    add("When", model.agoText or "")

    local tip = { title = model.instance or "?", character = model.name, lines = lines }

    local roster = InstancesUI.GroupPairs(model.group, 20)
    if #roster > 0 then
        tip.groupHeader = "Group (" .. #(model.group or {}) .. ")"
        tip.groupPairs = roster
    end

    if model.trades and #model.trades > 0 then
        tip.tradeHeader = "Trades while inside"
        tip.tradeLines = {}
        for i = 1, #model.trades do
            tip.tradeLines[i] = InstancesUI.TradeLine(model.trades[i], nowE)
        end
    end

    if model.visits and #model.visits > 1 then
        tip.visitHeader = "Visits (" .. #model.visits .. ")"
        tip.visitLines = {}
        for i = 1, #model.visits do
            local v = model.visits[i]
            tip.visitLines[i] = "Entered " .. (v.clock or "?")
                .. (v.merged and " (re-entry)" or "")
        end
    end

    return tip
end

-- ── CAP-COUNTDOWN TICKER GATE (owner round-15 item 2) ───────────────────────
-- The at-cap "M:SS" next-slot countdown used to freeze until something else
-- refreshed the dashboard. The panel now runs its own 1s ticker, gated by the
-- two predicates below so it costs nothing in the (overwhelmingly common) case
-- where no window is at cap. The TOTAL row can never hold the ticker open:
-- TotalModel is never atCap by construction.

-- True if ANY meter model has an hour or day window at cap. Pure.
function InstancesUI.AnyAtCap(models)
    for _, m in ipairs(models or {}) do
        if m and ((m.hour and m.hour.atCap) or (m.day and m.day.atCap)) then return true end
    end
    return false
end

-- The ticker runs ONLY while the panel is visible AND something is at cap. Pure.
function InstancesUI.TickerShouldRun(visible, models)
    if not visible then return false end
    return InstancesUI.AnyAtCap(models)
end

-- Flatten every account/character's entries into one newest-first list. Pure.
function InstancesUI.GatherEntries(instancesData)
    local out = {}
    if type(instancesData) == "table" then
        for aid, charMap in pairs(instancesData) do
            if type(charMap) == "table" then
                for nameRealm, crec in pairs(charMap) do
                    local entries = crec and crec.entries
                    if type(entries) == "table" then
                        for i = 1, #entries do
                            local e = entries[i]
                            if type(e) == "table" then
                                out[#out + 1] = { aid = aid, nameRealm = nameRealm, entry = e, t = e.t or 0 }
                            end
                        end
                    end
                end
            end
        end
    end
    table.sort(out, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        if a.aid ~= b.aid then return tostring(a.aid) < tostring(b.aid) end
        return tostring(a.nameRealm) < tostring(b.nameRealm)
    end)
    return out
end

-- Scope (single account or all) + "this character" modifier. Pure.
function InstancesUI.FilterEntries(list, scope, selfNameRealm)
    scope = scope or {}
    local out = {}
    for _, item in ipairs(list or {}) do
        local ok = true
        if scope.aid and item.aid ~= scope.aid then ok = false end
        if ok and scope.thisChar and item.nameRealm ~= selfNameRealm then ok = false end
        if ok then out[#out + 1] = item end
    end
    return out
end

-- Account ids sorted numerically (falls back to string order). Pure.
function InstancesUI.SortedAccountIDs(accountsMap)
    local ids = {}
    for aid in pairs(accountsMap or {}) do ids[#ids + 1] = aid end
    table.sort(ids, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na and nb then return na < nb end
        return tostring(a) < tostring(b)
    end)
    return ids
end

-- nameRealm -> classTag lookup across every account's characters + homeless. Pure.
function InstancesUI.ClassLookup(data)
    local map = {}
    local accounts = data and data.accounts
    if type(accounts) == "table" then
        local function scan(t)
            if type(t) ~= "table" then return end
            for nameRealm, rec in pairs(t) do
                if type(rec) == "table" and rec.classTag then map[nameRealm] = rec.classTag end
            end
        end
        for _, bucket in pairs(accounts) do
            scan(bucket.characters)
            scan(bucket.homeless)
        end
    end
    return map
end

-- Per-character EXPERIENCE / REST row (owner round-10 item 2). Consumes the record
-- fields the engine agent is adding concurrently (rec.xp / rec.xpMax / rec.restedXP)
-- GUARDEDLY — an absent field renders "—" so this is safe before the engine lands.
-- A level-60 character shows just "Level 60" (no xp / rested). Rested% is restedXP as a
-- percent of xpMax, "N% (Max)" at >= 150%. Pure/headless-tested.
local EMDASH = "\226\128\148"
function InstancesUI.ExpRow(rec, nameRealm, classTag)
    rec = rec or {}
    local D = ns.Dashboard
    local name = (D and D.ShortName and D.ShortName(nameRealm))
                 or (nameRealm and nameRealm:match("^([^%-]+)")) or nameRealm
    local level = rec.level or 0
    local maxed = level >= 60
    local xpText, restedText
    if not maxed then
        local xp, xpMax, rested = rec.xp, rec.xpMax, rec.restedXP
        if xp and xpMax and xpMax > 0 then xpText = ("%d/%d"):format(xp, xpMax) else xpText = EMDASH end
        if rested and xpMax and xpMax > 0 then
            local pct = math.floor(rested / xpMax * 100 + 0.5)
            restedText = (pct >= 150) and (pct .. "% (Max)") or (pct .. "%")
        else
            restedText = EMDASH
        end
    end
    return { nameRealm = nameRealm, classTag = classTag, name = name, level = level,
             maxed = maxed, levelText = "Level " .. level, xpText = xpText, restedText = restedText }
end

-- All characters { nameRealm, classTag, level } ordered by LEVEL desc then name asc,
-- with an "All" sentinel { all = true } prepended (owner round-10 item 3 dropdown).
-- Pure over a Store.GetData() shape.
-- ROUND-24 (owner): `aid` filters to ONE account's characters; nil = every account.
function InstancesUI.CharList(data, aid)
    local out = {}
    local accounts = data and data.accounts
    if type(accounts) == "table" then
        local function scan(t)
            if type(t) ~= "table" then return end
            for nameRealm, rec in pairs(t) do
                if type(rec) == "table" then
                    out[#out + 1] = { nameRealm = nameRealm, classTag = rec.classTag, level = rec.level or 0 }
                end
            end
        end
        for id, bucket in pairs(accounts) do
            if aid == nil or id == aid then
                scan(bucket.characters)
                scan(bucket.homeless)
            end
        end
    end
    table.sort(out, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        return tostring(a.nameRealm) < tostring(b.nameRealm)
    end)
    table.insert(out, 1, { all = true, label = "All" })
    return out
end

-- ROUND-24 (owner): the ACCOUNT dropdown's entries — an "All" sentinel, then every account
-- registered in the mesh, labelled "Account N" per the round-23 convention. Only NUMERIC
-- ids get an entry: a non-numeric id has no sensible "Account N" label, and the round-23
-- header rule already drops those rather than printing a malformed one. Pure.
function InstancesUI.AccountList(data)
    local out = { { all = true, label = "All" } }
    local accounts = data and data.accounts
    if type(accounts) == "table" then
        for _, aid in ipairs(InstancesUI.SortedAccountIDs(accounts)) do
            if tonumber(aid) then
                out[#out + 1] = { aid = aid, label = "Account " .. tonumber(aid) }
            end
        end
    end
    return out
end

-- ROUND-24 (owner): the REST view's rows — per-character XP/rested, NON-60s ONLY.
-- Level 60s are excluded ENTIRELY (not shown as bare "Level 60" rows like the old EXP
-- view did): the view answers "who has rested XP banked", and a 60 has no answer to give.
-- Ordered level DESC then name, so the character closest to 60 leads. Pure.
function InstancesUI.RestRows(data, aid, charFilter)
    local rows = {}
    local accounts = data and data.accounts
    if type(accounts) == "table" then
        local function scan(t)
            if type(t) ~= "table" then return end
            for nameRealm, rec in pairs(t) do
                if type(rec) == "table" and (rec.level or 0) < 60
                   and (charFilter == nil or nameRealm == charFilter) then
                    rows[#rows + 1] = InstancesUI.ExpRow(rec, nameRealm, rec.classTag)
                end
            end
        end
        for id, bucket in pairs(accounts) do
            if aid == nil or id == aid then
                scan(bucket.characters)
                scan(bucket.homeless)
            end
        end
    end
    table.sort(rows, function(a, b)
        if a.level ~= b.level then return a.level > b.level end
        return tostring(a.nameRealm) < tostring(b.nameRealm)
    end)
    return rows
end

-- ROUND-24 (owner): the account -> character CASCADE. Changing the account resets the
-- character selection to "All" UNLESS the selected character still belongs to the newly
-- selected account (in which case keeping it is the least surprising behaviour). With
-- "All accounts" selected every character stays valid. Pure, so the cascade is testable
-- without driving the dropdowns.
function InstancesUI.ResolveCharSelection(data, aid, selectedChar)
    if not selectedChar then return nil end
    if aid == nil then return selectedChar end
    for _, c in ipairs(InstancesUI.CharList(data, aid)) do
        if c.nameRealm == selectedChar then return selectedChar end
    end
    return nil
end

-- ════════════════════════════════════════════════════════════════════════════
--  COMPACT PANEL (in-game only; UI is non-nil there)
-- ════════════════════════════════════════════════════════════════════════════

local PAD        = 10
local METER_H    = 18
local METER_GAP  = 2
local REC_H      = 17
local REC_GAP    = 1
local MAX_METERS = 8
local MAX_REC    = 40

-- RECENT register column budget. The panel is 364 wide (ui_cards INST_W) and
-- pads 10 a side, so a row has 344 to spend. Right-anchored numeral columns,
-- left-anchored identity columns, and the instance name takes what is left:
--
--   name 56 | 6 | instance ~105 (flex, ellipsis) | 6 | DUR 38 | GOLD 42 | XP 38 | AGO 38
--                                                        \___ 5px gaps between numerals
--
-- 56 + 6 + 6 + 38+5+42+5+38+5+38 = 239 fixed, leaving ~105 for the instance
-- name (~18 chars of the 11px condensed body face — "Blackrock Depths" fits).
-- Both name and instance are non-wrapping and width-clamped, so anything longer
-- ellipsises rather than colliding with the numerals. All four right columns
-- fit in COMPACT form (InstancesUI.RecentCells); the exact figures live in the
-- row tooltip. Captions sit on the RECENT label line, so this costs no height.
-- The numbers themselves live in InstancesUI.RECENT_COLS (headless-asserted).
local RC = InstancesUI.RECENT_COLS
local COL_NAME, COL_DUR, COL_GOLD = RC.name, RC.dur, RC.gold
local COL_XP, COL_AGO             = RC.xp, RC.ago
local COL_GAP, COL_PAD            = RC.gap, RC.pad

local function tag(frame, id)
    if ns.Audit and ns.Audit.Tag and frame then ns.Audit.Tag(frame, id) end
    return frame
end
local function fstr(parent, key, justify)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(Dashboard.Font(key))   -- round-11 item 2: ARIALN dashboard type
    if justify then f:SetJustifyH(justify) end
    return f
end
local function microLabel(parent, text)
    local l = fstr(parent, "microLabel")
    l:SetTextColor(UI.Color("muted"))   -- pop pass
    if text then l:SetText(text) end
    return l
end

-- Build the instances panel into `host` (a raised panel frame from ui_cards). Returns
-- a controller with :Refresh() and .frame.
function InstancesPanel.Attach(host)
    local P = { _meters = {}, _rows = {} }
    P.frame = host

    -- ROUND-24 (owner): a THREE-DROPDOWN filter row — View · Account · Character —
    -- replaces the round-10 INSTANCES|EXP micro-toggle and the lone character dropdown.
    -- All three selections persist in UIState so the panel reopens as it was left.
    local st0 = (Dashboard.UIState and Dashboard.UIState()) or {}
    P.view         = st0.instView or "logs"    -- "logs" | "rest"
    P.selectedAcct = st0.instAcct              -- nil = All accounts
    P.selectedChar = st0.instChar              -- nil = All characters
    local function persist()
        local s = Dashboard.UIState and Dashboard.UIState()
        if not s then return end
        s.instView, s.instAcct, s.instChar = P.view, P.selectedAcct, P.selectedChar
    end

    -- Panel title (owner: "give the section a title 'INSTANCE LOG'").
    local title = microLabel(host, "INSTANCE LOG")
    title:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -PAD)
    tag(title, "instances.header")
    P.title = title

    local meta = fstr(host, "microLabel", "RIGHT")
    meta:SetPoint("TOPRIGHT", host, "TOPRIGHT", -PAD, -PAD)
    meta:SetTextColor(UI.Color("muted"))
    -- Same flex rule the dock learned in round-21: the fixed TITLE yields to the live meta
    -- so the two can never overlap. One-way (title -> meta), so no anchor cycle.
    title:SetPoint("RIGHT", meta, "LEFT", -8, 0)
    title:SetWordWrap(false)
    P.meta = meta

    -- ── Dropdown FACTORY (round-24) ─────────────────────────────────────────────
    -- One shared visual language (the round-10 popup style, generalised): a bordered
    -- button with a caret plus a DIALOG-strata scrollable popup. `rebuildFn` returns
    -- { label=, value=, tint= } entries; `onPick` receives the value (nil = "All").
    local DD_ROW_H, DD_VIS = 16, 10
    local closeOtherPopups   -- fwd decl: only one popup open at a time
    local function makeDropdown(id, rebuildFn, onPick)
        local dd = CreateFrame("Button", nil, host, "BackdropTemplate")
        dd:SetHeight(17)
        UI.Skin(dd, function(self)
            self:SetBackdrop(UI.FLAT_BACKDROP); self:SetBackdropColor(UI.Color("inset"))
            self:SetBackdropBorderColor(UI.Color("borderLite"))
        end)
        dd.label = fstr(dd, "small"); dd.label:SetPoint("LEFT", dd, "LEFT", 6, 0)
        dd.label:SetWordWrap(false); dd.label:SetText("All")
        local arrow = fstr(dd, "small"); arrow:SetPoint("RIGHT", dd, "RIGHT", -5, 0)
        arrow:SetText("\226\150\190"); arrow:SetTextColor(UI.Color("muted"))
        dd.label:SetPoint("RIGHT", arrow, "LEFT", -4, 0)
        tag(dd, id)
    -- Popup list (own frame, DIALOG strata; 10 rows visible, scroll for the rest).
    local pop = CreateFrame("Frame", nil, dd, "BackdropTemplate")
    pop:SetFrameStrata("DIALOG"); pop:SetPoint("TOPLEFT", dd, "BOTTOMLEFT", 0, -1); pop:SetPoint("TOPRIGHT", dd, "BOTTOMRIGHT", 0, -1)
    pop:SetHeight(DD_VIS * DD_ROW_H + 4)
    UI.Skin(pop, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP); self:SetBackdropColor(UI.Color("ground")); self:SetBackdropBorderColor(UI.Color("accent"))
    end)
    pop:Hide()
    local popScroll = CreateFrame("ScrollFrame", nil, pop); popScroll:SetPoint("TOPLEFT", 2, -2); popScroll:SetPoint("BOTTOMRIGHT", -2, 2)
    popScroll:SetClipsChildren(true); popScroll:EnableMouseWheel(true)
    local popChild = CreateFrame("Frame", nil, popScroll); popChild:SetSize(1, 1); popScroll:SetScrollChild(popChild)
    popScroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, popChild:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(math.max(0, math.min(maxs, self:GetVerticalScroll() - delta * DD_ROW_H * 2)))
    end)
    dd._rows, dd.pop = {}, pop
    local function ddRebuild()
        local list = rebuildFn() or {}
        local W = popScroll:GetWidth(); if W < 1 then W = dd:GetWidth() - 4 end
        popChild:SetWidth(W)
        for _, r in ipairs(dd._rows) do r:Hide() end
        local y = 0
        for i, item in ipairs(list) do
            local r = dd._rows[i]
            if not r then
                r = CreateFrame("Button", nil, popChild)
                r:SetHeight(DD_ROW_H)
                r.txt = fstr(r, "small"); r.txt:SetPoint("LEFT", r, "LEFT", 6, 0); r.txt:SetWordWrap(false)
                r.txt:SetPoint("RIGHT", r, "RIGHT", -6, 0); r.txt:SetJustifyH("LEFT")
                r:SetScript("OnEnter", function(self) self.txt:SetTextColor(UI.Color("accent")) end)
                dd._rows[i] = r
            end
            r:ClearAllPoints(); r:SetPoint("TOPLEFT", popChild, "TOPLEFT", 0, -y); r:SetPoint("TOPRIGHT", popChild, "TOPRIGHT", 0, -y)
            r.txt:SetText(item.label)
            local cr, cg, cb
            if item.tint then cr, cg, cb = Dashboard.ClassColor(item.tint) end
            if cr then r.txt:SetTextColor(cr, cg, cb) else r.txt:SetTextColor(UI.Color("text")) end
            r:SetScript("OnLeave", function(self)
                if cr then self.txt:SetTextColor(cr, cg, cb) else self.txt:SetTextColor(UI.Color("text")) end
            end)
            r._val = item.value
            r:SetScript("OnClick", function(self)
                pop:Hide(); onPick(self._val); persist(); P.Refresh()
            end)
            r:Show()
            y = y + DD_ROW_H
        end
        popChild:SetHeight(math.max(y, 1))
    end
    dd:SetScript("OnClick", function()
        if pop:IsShown() then pop:Hide()
        else closeOtherPopups(pop); ddRebuild(); pop:Show() end
    end)
    dd._rebuild = ddRebuild
    return dd
    end   -- makeDropdown

    P._popups = {}
    closeOtherPopups = function(keep)
        for _, p in ipairs(P._popups) do if p ~= keep then p:Hide() end end
    end

    -- ── The three dropdowns, left to right, inside the 364px panel ──────────────
    -- Usable width = 364 - 2*PAD(10) = 344; two 6px gaps leave 332 for three fields.
    -- View is narrowest (its labels are short), Account is fixed ("Account 99"), and
    -- Character takes the remainder because names are the longest of the three.
    local DD_GAP, DD_VIEW_W, DD_ACCT_W = 6, 74, 92
    local ddView = makeDropdown("instances.viewselect",
        function() return { { label = "Logs", value = "logs" }, { label = "Rest", value = "rest" } } end,
        function(v) P.view = v or "logs" end)
    ddView:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -(PAD + 16))
    ddView:SetWidth(DD_VIEW_W)

    local ddAcct = makeDropdown("instances.acctselect",
        function()
            local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
            local out = {}
            for _, a in ipairs(InstancesUI.AccountList(data)) do
                out[#out + 1] = { label = a.label, value = a.aid }
            end
            return out
        end,
        function(v)
            P.selectedAcct = v
            -- CASCADE (owner): a new account resets the character unless it still belongs.
            local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
            P.selectedChar = InstancesUI.ResolveCharSelection(data, P.selectedAcct, P.selectedChar)
        end)
    ddAcct:SetPoint("LEFT", ddView, "RIGHT", DD_GAP, 0)
    ddAcct:SetWidth(DD_ACCT_W)

    local ddChar = makeDropdown("instances.charselect",
        function()
            local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
            local out = {}
            for _, c in ipairs(InstancesUI.CharList(data, P.selectedAcct)) do
                if c.all then out[#out + 1] = { label = "All" }
                else
                    out[#out + 1] = {
                        label = ("%s  \194\183 %d"):format(c.nameRealm:match("^([^%-]+)") or c.nameRealm, c.level),
                        value = c.nameRealm, tint = c.classTag,
                    }
                end
            end
            return out
        end,
        function(v) P.selectedChar = v end)
    ddChar:SetPoint("LEFT", ddAcct, "RIGHT", DD_GAP, 0)
    ddChar:SetPoint("RIGHT", host, "RIGHT", -PAD, 0)

    P.ddView, P.ddAcct, P.ddChar = ddView, ddAcct, ddChar
    P.dd = ddChar   -- retained alias (older refresh code refers to P.dd)
    P._popups = { ddView.pop, ddAcct.pop, ddChar.pop }
    P._ddRebuild = function() ddChar._rebuild() end

    -- Meters container (per-account rows + ALL row) — GLOBAL, below the dropdown.
    local METERS_TOP = PAD + 38   -- round-24: title 16 + dropdown row 17 + 5 air
    local metersTop = CreateFrame("Frame", nil, host)
    metersTop:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -METERS_TOP)
    metersTop:SetPoint("RIGHT", host, "RIGHT", -PAD, 0)
    metersTop:SetHeight(1)
    tag(metersTop, "instances.meters")
    P.metersTop, P._metersTop = metersTop, METERS_TOP

    local function makeMeterRow()
        local r = CreateFrame("Frame", nil, host)
        r:SetHeight(METER_H)
        r.label = fstr(r, "small"); r.label:SetPoint("LEFT", r, "LEFT", 0, 0)
        r.day = fstr(r, "numeral", "RIGHT"); r.day:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        r.hour = fstr(r, "numeral", "RIGHT"); r.hour:SetPoint("RIGHT", r.day, "LEFT", -14, 0)
        return r
    end
    local function getMeter(i)
        local r = P._meters[i]; if not r then r = makeMeterRow(); P._meters[i] = r end; return r
    end
    P._makeMeterRow = makeMeterRow

    -- ── Cap-countdown TICKER (owner round-15 item 2) ─────────────────────────
    -- The at-cap "M:SS" next-slot countdown is recomputed from `nowE` on every
    -- paint, so with no ticker of its own the panel froze the countdown until
    -- some unrelated event refreshed the dashboard. This 1s ticker repaints ONLY
    -- the meter rows — the recent list, the dropdown and the scroll offset are
    -- untouched. Gating, mirroring the timers dock's hidden-pause:
    --   * the ticker frame is a CHILD of `host`, so a hidden panel makes it
    --     non-visible and WoW stops firing its OnUpdate entirely (the pause);
    --   * it is Shown only while InstancesUI.AnyAtCap says a window is capped,
    --     so an under-cap panel runs no OnUpdate at all (the stop);
    --   * the handler re-checks InstancesUI.TickerShouldRun(IsVisible, models)
    --     each frame, so both halves of the gate are asserted in the live path.
    P._meterModels, P._meterCount, P._tickAccum = {}, 0, 0
    local ticker = CreateFrame("Frame", nil, host)
    ticker:SetSize(1, 1); ticker:SetPoint("TOPLEFT", host, "TOPLEFT", 0, 0)
    ticker:Hide()
    ticker:SetScript("OnUpdate", function(self, elapsed)
        if not InstancesUI.TickerShouldRun(self:IsVisible(), P._meterModels) then return end
        P._tickAccum = P._tickAccum + (elapsed or 0)
        if P._tickAccum < 1 then return end
        P._tickAccum = 0
        ns:SafeCall(P.Tick)
    end)
    P._ticker = ticker

    function P.SyncTicker()
        if InstancesUI.AnyAtCap(P._meterModels) then
            if not ticker:IsShown() then P._tickAccum = 0; ticker:Show() end
        else
            ticker:Hide()
        end
    end

    -- Recent-entries scroll list below the meters (name · instance · dur · gold · xp · ago).
    local recLbl = microLabel(host, "RECENT")
    P.recLbl = recLbl

    -- Column captions, riding the RECENT label line (no extra row height). They
    -- use the SAME right-anchored chain and widths as the row cells, so the
    -- caption sits exactly over its column. INSTANCES view only.
    local cols = CreateFrame("Frame", nil, host)
    cols:SetHeight(12)
    cols:SetPoint("RIGHT", host, "RIGHT", -PAD, 0)   -- TOP set per-refresh
    tag(cols, "instances.recentcols")
    local function caption(text, w, anchorTo)
        local f = fstr(cols, "microLabel", "RIGHT")
        if anchorTo then f:SetPoint("RIGHT", anchorTo, "LEFT", -COL_GAP, 0)
        else f:SetPoint("RIGHT", cols, "RIGHT", 0, 0) end
        f:SetWidth(w); f:SetTextColor(UI.Color("faint")); f:SetText(text)
        return f
    end
    local capAgo  = caption("AGO",  COL_AGO)
    local capXP   = caption("XP",   COL_XP,   capAgo)
    local capGold = caption("GOLD", COL_GOLD, capXP)
    local capDur  = caption("DUR",  COL_DUR,  capGold)
    cols:SetWidth(COL_AGO + COL_XP + COL_GOLD + COL_DUR + 3 * COL_GAP)
    P.cols = cols

    local scroll = CreateFrame("ScrollFrame", nil, host)
    scroll:SetClipsChildren(true); scroll:EnableMouseWheel(true)
    local child = CreateFrame("Frame", nil, scroll); child:SetSize(1, 1); scroll:SetScrollChild(child)
    scroll:SetScript("OnMouseWheel", function(self, delta)
        local maxs = math.max(0, child:GetHeight() - self:GetHeight())
        local cur = self:GetVerticalScroll()
        self:SetVerticalScroll(math.max(0, math.min(maxs, cur - delta * 30)))
    end)
    P._scroll, P._child = scroll, child
    tag(scroll, "instances.recent")
    local emptyFS = fstr(child, "muted"); emptyFS:SetPoint("TOPLEFT", child, "TOPLEFT", 2, -2)
    emptyFS:SetText("No instance entries recorded."); emptyFS:Hide()
    P._empty = emptyFS

    -- One RECENT row: name · instance (flex) · DUR · GOLD · XP · AGO. The four
    -- right columns are fixed-width and right-aligned so the numerals form hard
    -- column edges down the list; the instance name flexes into what remains and
    -- ellipsises. Hovering a row shows the exact (un-abbreviated) figures.
    local function makeRecRow()
        local r = CreateFrame("Frame", nil, child)
        r:SetHeight(REC_H)
        r:EnableMouse(true)   -- tooltip only; the wheel still reaches the scroll frame
        r.name = fstr(r, "small"); r.name:SetPoint("LEFT", r, "LEFT", 0, 0)
        r.name:SetWidth(COL_NAME); r.name:SetWordWrap(false); r.name:SetJustifyH("LEFT")
        r.ago = fstr(r, "microLabel", "RIGHT"); r.ago:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        r.ago:SetWidth(COL_AGO); r.ago:SetWordWrap(false); r.ago:SetTextColor(UI.Color("muted"))
        r.xp = fstr(r, "small", "RIGHT"); r.xp:SetPoint("RIGHT", r.ago, "LEFT", -COL_GAP, 0)
        r.xp:SetWidth(COL_XP); r.xp:SetWordWrap(false)
        r.gold = fstr(r, "small", "RIGHT"); r.gold:SetPoint("RIGHT", r.xp, "LEFT", -COL_GAP, 0)
        r.gold:SetWidth(COL_GOLD); r.gold:SetWordWrap(false)
        r.dur = fstr(r, "small", "RIGHT"); r.dur:SetPoint("RIGHT", r.gold, "LEFT", -COL_GAP, 0)
        r.dur:SetWidth(COL_DUR); r.dur:SetWordWrap(false)
        r.inst = fstr(r, "small"); r.inst:SetPoint("LEFT", r.name, "RIGHT", COL_PAD, 0)
        r.inst:SetPoint("RIGHT", r.dur, "LEFT", -COL_PAD, 0); r.inst:SetWordWrap(false); r.inst:SetJustifyH("LEFT")
        r.inst:SetTextColor(UI.Color("muted"))
        r:SetScript("OnEnter", function(self)
            local tip = self._tip
            if not (tip and GameTooltip) then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")   -- SetOwner clears the tooltip
            GameTooltip:AddLine(tip.title, UI.Color("accent"))
            if tip.character then GameTooltip:AddLine(tip.character, UI.Color("muted")) end
            local tr, tg, tb = UI.Color("muted")
            local vr, vg, vb = UI.Color("text")
            local hr, hg, hb = UI.Color("accent")
            for _, ln in ipairs(tip.lines) do
                GameTooltip:AddDoubleLine(ln[1], ln[2], tr, tg, tb, vr, vg, vb)
            end
            -- Roster: a two-column name list, one AddDoubleLine per pair.
            if tip.groupPairs then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(tip.groupHeader, hr, hg, hb)
                for _, pr in ipairs(tip.groupPairs) do
                    GameTooltip:AddDoubleLine(pr[1], pr[2], vr, vg, vb, vr, vg, vb)
                end
            end
            if tip.tradeLines then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(tip.tradeHeader, hr, hg, hb)
                for _, ln in ipairs(tip.tradeLines) do
                    GameTooltip:AddLine(ln, vr, vg, vb)
                end
            end
            if tip.visitLines then
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(tip.visitHeader, hr, hg, hb)
                for _, ln in ipairs(tip.visitLines) do
                    GameTooltip:AddLine(ln, tr, tg, tb)
                end
            end
            GameTooltip:Show()
        end)
        r:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
        return r
    end
    local function getRec(i)
        local r = P._rows[i]; if not r then r = makeRecRow(); P._rows[i] = r end; return r
    end

    -- EXP rows (round-10 item 2): class-colored name · level · xp cur/total · rested%.
    P._expRows = {}
    local function makeExpRow()
        local r = CreateFrame("Frame", nil, child)
        r:SetHeight(REC_H)
        r.name = fstr(r, "small"); r.name:SetPoint("LEFT", r, "LEFT", 0, 0); r.name:SetWordWrap(false)
        r.rested = fstr(r, "numeral", "RIGHT"); r.rested:SetPoint("RIGHT", r, "RIGHT", 0, 0)
        r.xp = fstr(r, "numeral", "RIGHT"); r.xp:SetPoint("RIGHT", r.rested, "LEFT", -12, 0)
        r.lvl = fstr(r, "microLabel"); r.lvl:SetPoint("LEFT", r.name, "RIGHT", 8, 0); r.lvl:SetTextColor(UI.Color("muted"))
        return r
    end
    local function getExp(i)
        local r = P._expRows[i]; if not r then r = makeExpRow(); P._expRows[i] = r end; return r
    end

    -- Resolve a character record (for xp/rested fields) across all account buckets.
    local function resolveRec(data, nameRealm)
        local accounts = data and data.accounts
        if type(accounts) ~= "table" then return nil end
        for _, b in pairs(accounts) do
            local rec = (b.characters and b.characters[nameRealm]) or (b.homeless and b.homeless[nameRealm])
            if rec then return rec end
        end
    end

    local function nowEpoch()
        return (Dashboard and Dashboard.Now and Dashboard.Now()) or (GetServerTime and GetServerTime()) or 0
    end

    -- Paint JUST the meter rows (one per account, numerically sorted, then the
    -- ALL total row). Idempotent in position, so the ticker can call it without
    -- disturbing the recent list or the scroll offset. Returns the row count;
    -- caches the models for the ticker gate and re-syncs the ticker.
    function P.PaintMeters(nowE)
        nowE = nowE or nowEpoch()
        local Inst = ns.Instances
        local view = (Inst and Inst.AllAccounts and Inst.AllAccounts(nowE)) or { accounts = {}, total = {} }
        local aids = InstancesUI.SortedAccountIDs(view.accounts)
        local n, prev, models = 0, nil, {}
        -- `total` = the cross-account sum: no cap, no state colour, no countdown.
        local function placeMeter(label, counts, total)
            if n >= MAX_METERS then return end
            n = n + 1
            local r = getMeter(n)
            r:ClearAllPoints()
            if prev then r:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, -METER_GAP); r:SetPoint("TOPRIGHT", prev, "BOTTOMRIGHT", 0, -METER_GAP)
            else r:SetPoint("TOPLEFT", metersTop, "TOPLEFT", 0, 0); r:SetPoint("TOPRIGHT", metersTop, "TOPRIGHT", 0, 0) end
            local m = total and InstancesUI.TotalModel(counts)
                            or InstancesUI.MeterModel(counts, nowE, Inst)
            models[#models + 1] = m
            r.label:SetText(label); r.label:SetTextColor(UI.Color(total and "muted" or "text"))
            r.hour:SetText(InstancesUI.MeterText("Hr", m.hour))
            r.hour:SetTextColor(UI.Color(m.hour.token))
            r.day:SetText(InstancesUI.MeterText("Day", m.day))
            r.day:SetTextColor(UI.Color(m.day.token))
            r:Show()
            prev = r
        end
        for _, aid in ipairs(aids) do placeMeter("Acct " .. aid, view.accounts[aid]) end
        placeMeter("All", view.total, true)
        for j = n + 1, #P._meters do P._meters[j]:Hide() end
        P._meterModels, P._meterCount = models, n
        P.SyncTicker()
        return n
    end

    -- One tick: repaint the meters only. A CHANGE in the number of meter rows
    -- moves the list below them, so that (rare) case escalates to a full Refresh.
    function P.Tick()
        local before = P._meterCount
        if P.PaintMeters(nowEpoch()) ~= before then P.Refresh() end
    end

    function P.Refresh()
        local nowE = nowEpoch()
        local Inst = ns.Instances
        local data = ns.Store and ns.Store.GetData and ns.Store.GetData()

        -- Meta caps line.
        local hCap = (Inst and Inst.HOURLY_CAP) or 5
        local dCap = (Inst and Inst.DAILY_CAP) or 30
        meta:SetText(("caps %d/hr \194\183 %d/day"):format(hCap, dCap))

        local n = P.PaintMeters(nowE)

        -- Toggle + dropdown repaint.
        -- ROUND-24: repaint the three dropdown captions from the live selections.
        P.ddView.label:SetText(P.view == "rest" and "Rest" or "Logs")
        P.ddAcct.label:SetText(P.selectedAcct and ("Account " .. (tonumber(P.selectedAcct) or P.selectedAcct)) or "All")
        P.ddChar.label:SetText(P.selectedChar and (P.selectedChar:match("^([^%-]+)") or P.selectedChar) or "All")

        -- List label + scroll region, positioned below the (global) meters.
        local metersH = n * METER_H + math.max(0, n - 1) * METER_GAP
        local listTop = P._metersTop + metersH + 8
        local isExp = (P.view == "rest")   -- round-24: "logs" | "rest"
        recLbl:SetText(isExp and "RESTED" or "RECENT")
        recLbl:ClearAllPoints(); recLbl:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -listTop)
        -- Column captions ride the label line; they describe the INSTANCES columns only.
        cols:ClearAllPoints(); cols:SetPoint("TOPRIGHT", host, "TOPRIGHT", -PAD, -listTop)
        cols:SetShown(not isExp)
        scroll:ClearAllPoints()
        scroll:SetPoint("TOPLEFT", host, "TOPLEFT", PAD, -(listTop + 15))
        scroll:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -PAD, PAD)

        local classMap = InstancesUI.ClassLookup(data or {})
        local W = scroll:GetWidth(); if W < 1 then W = host:GetWidth() - 2 * PAD end
        child:SetWidth(W)
        for _, r in ipairs(P._rows) do r:Hide() end
        for _, r in ipairs(P._expRows) do r:Hide() end
        local y, shown = 0, 0

        if isExp then
            -- ROUND-24 REST view: per-character XP / rested, NON-60s ONLY (a 60 has no
            -- rested progression to report, so it is excluded outright rather than shown
            -- as a bare "Level 60" row like the old EXP view did). Account + character
            -- filters both apply, and the model layer owns the rule.
            for _, m in ipairs(InstancesUI.RestRows(data, P.selectedAcct, P.selectedChar)) do
                shown = shown + 1
                local r = getExp(shown)
                r:ClearAllPoints(); r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y); r:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -y)
                local cr, cg, cb = Dashboard.ClassColor(m.classTag)
                r.name:SetText(m.name or "?")
                if cr then r.name:SetTextColor(cr, cg, cb) else r.name:SetTextColor(UI.Color("text")) end
                r.lvl:SetText(m.levelText)
                r.xp:SetText(m.xpText or ""); r.xp:SetTextColor(UI.Color("muted"))
                r.rested:SetText(m.restedText or ""); r.rested:SetTextColor(UI.Color("muted"))
                r:Show()
                y = y + REC_H + REC_GAP
            end
            -- Empty copy names the rule, so an all-60s account does not look broken.
            P._empty:SetText("No characters below 60."); P._empty:SetShown(shown == 0)
        else
            -- INSTANCES view: recent runs (newest first), filtered by the dropdown.
            -- ONE ROW PER PHYSICAL INSTANCE: re-entries into the same live
            -- instance (corpse run, summon back, relog inside) fold into the row
            -- of the run they belong to; a reset-and-rerun keeps its own row.
            local all = InstancesUI.GatherEntries((data and data.instances) or {})
            local groups = InstancesUI.GroupVisits(all)
            for i = 1, #groups do
                local item = groups[i]
                if shown >= MAX_REC then break end
                -- ROUND-24: BOTH the account and character dropdowns filter the log.
                local acctOK = (not P.selectedAcct) or (item.aid == P.selectedAcct)
                if acctOK and ((not P.selectedChar) or (item.nameRealm == P.selectedChar)) then
                    local model = InstancesUI.RowModel(item.primary, item.nameRealm,
                        classMap[item.nameRealm], nowE, false, item.visits)
                    shown = shown + 1
                    local r = getRec(shown)
                    r:ClearAllPoints(); r:SetPoint("TOPLEFT", child, "TOPLEFT", 0, -y); r:SetPoint("TOPRIGHT", child, "TOPRIGHT", 0, -y)
                    local cr, cg, cb = Dashboard.ClassColor(model.classTag)
                    r.name:SetText(model.name or "?")
                    if cr then r.name:SetTextColor(cr, cg, cb) else r.name:SetTextColor(UI.Color("text")) end
                    r.inst:SetText(model.instanceText or model.instance)
                    -- Computed columns (owner round-15 item 1), compact form.
                    local cells = InstancesUI.RecentCells(model)
                    r.dur:SetText(cells.dur);  r.dur:SetTextColor(UI.Color("muted"))
                    r.gold:SetText(cells.gold); r.gold:SetTextColor(UI.Color(cells.goldToken))
                    r.xp:SetText(cells.xp or ""); r.xp:SetTextColor(UI.Color("muted"))
                    r.ago:SetText(cells.ago)
                    r._tip = InstancesUI.RowTooltip(model, nowE)
                    r:Show()
                    y = y + REC_H + REC_GAP
                end
            end
            P._empty:SetText("No instance entries recorded."); P._empty:SetShown(shown == 0)
        end
        child:SetHeight(math.max(y, 1))
    end

    P.Refresh()
    return P
end

-- ════════════════════════════════════════════════════════════════════════════
--  SELF-TEST  (suite "instancesui"): the view-model matrix, re-housed verbatim.
-- ════════════════════════════════════════════════════════════════════════════

local function testInstancesUI(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local IU = ns.InstancesUI

    ck(IU.MeterState(0, 5, 4) == "ok",   "0/5 -> ok")
    ck(IU.MeterState(3, 5, 4) == "ok",   "3/5 -> ok (below warn)")
    ck(IU.MeterState(4, 5, 4) == "warn", "4/5 -> warn (== warn threshold)")
    ck(IU.MeterState(5, 5, 4) == "cap",  "5/5 -> cap (== cap)")
    ck(IU.MeterState(6, 5, 4) == "cap",  "6/5 -> cap (over)")
    ck(IU.MeterState(26, 30, 27) == "ok",   "26/30 -> ok")
    ck(IU.MeterState(27, 30, 27) == "warn", "27/30 -> warn")
    ck(IU.MeterState(30, 30, 27) == "cap",  "30/30 -> cap")

    ck(IU.StateToken("ok")   == "muted",  "ok  -> calm (muted)")
    ck(IU.StateToken("warn") == "warn",   "warn -> amber")
    ck(IU.StateToken("cap")  == "danger", "cap -> danger")

    local caps = { HOURLY_CAP = 5, WARN_HOURLY = 4, DAILY_CAP = 30, WARN_DAILY = 27 }
    local T = 1000000
    local m1 = IU.MeterModel({ hour = 2, day = 10, nextHourSlotAt = T + 100 }, T, caps)
    ck(m1.hour.state == "ok" and m1.hour.token == "muted", "model: hour ok calm")
    ck(m1.hour.countdown == nil, "model: no countdown under cap")
    local m2 = IU.MeterModel({ hour = 5, day = 10, nextHourSlotAt = T + 293 }, T, caps)
    ck(m2.hour.atCap == true and m2.hour.token == "danger", "model: hour capped danger")
    ck(m2.hour.countdown == 293, "model: hourly countdown = nextHourSlotAt - now")
    local m3 = IU.MeterModel({ hour = 4, day = 28 }, T, caps)
    ck(m3.hour.state == "warn" and m3.day.state == "warn", "model: warn band hour + day")
    local m4 = IU.MeterModel({ hour = 3, day = 30, nextDaySlotAt = T + 60 }, T, caps)
    ck(m4.day.atCap == true and m4.day.countdown == 60, "model: daily cap countdown")

    -- A6.2 -- the cross-account TOTAL row has no cap semantics. Two accounts at
    -- 5/5 each sum to 9-10 in an hour; run through MeterModel that reads as a
    -- permanent red "Hr 9/5". TotalModel must stay neutral.
    local tm = IU.TotalModel({ hour = 9, day = 41 })
    ck(tm.neutral == true, "total: flagged neutral")
    ck(tm.hour.count == 9 and tm.day.count == 41, "total: carries the raw sums")
    ck(tm.hour.cap == nil and tm.day.cap == nil, "total: no cap denominator")
    ck(tm.hour.token == "muted" and tm.day.token == "muted",
        "total: neutral token even far over a per-account cap")
    ck(tm.hour.atCap == false and tm.day.atCap == false, "total: never reads at-cap")
    ck(tm.hour.countdown == nil and tm.day.countdown == nil, "total: no countdown")
    local overCap = IU.MeterModel({ hour = 9 }, T, caps)
    ck(overCap.hour.token == "danger" and tm.hour.token == "muted",
        "total: same count that reddens an ACCOUNT row stays calm on the total")
    local tm0 = IU.TotalModel(nil)
    ck(tm0.hour.count == 0 and tm0.day.count == 0, "total: nil counts -> zeroes")

    -- Meter row text: capped rows keep the denominator, the total drops it.
    ck(IU.MeterText("Hr", { count = 3, cap = 5 }) == "Hr 3/5", "meter text: account row")
    ck(IU.MeterText("Hr", { count = 9 }) == "Hr 9", "meter text: total row has no denominator")
    ck(IU.MeterText("Hr", { count = 5, cap = 5, countdown = 293 }) == "Hr 5/5 4:53",
        "meter text: countdown appended at cap")
    ck(IU.MeterText("Day", tm.day) == "Day 41", "meter text: total day row")

    ck(IU.NextSlotSeconds(T + 125, T) == 125, "next-slot seconds")
    ck(IU.NextSlotSeconds(T - 10, T) == 0, "past slot clamps to 0")
    ck(IU.NextSlotSeconds(nil, T) == nil, "no slot time -> nil")
    ck(IU.FormatMSS(293) == "4:53", "293s -> 4:53")
    ck(IU.FormatMSS(5) == "0:05", "5s -> 0:05")
    ck(IU.FormatMSS(0) == "0:00", "0s -> 0:00")

    ck(IU.FormatMoney(12345) == "1g 23s", "positive gold -> g/s")
    ck(IU.FormatMoney(-5000) == "-50s 0c", "negative gold shows sign")
    ck(IU.FormatMoney(0) == "0c", "zero copper")

    local rN = IU.RowModel({ t = T - 120, name = "Molten Core", dur = 3600, gold = 25000, xp = 1500, merged = false }, "Alt-Realm", "MAGE", T)
    ck(rN.instance == "Molten Core", "row: instance name")
    ck(rN.merged == false, "row: non-merged flag false")
    ck(rN.goldToken == "muted", "row: positive gold reads calm")
    ck(rN.classTag == "MAGE", "row: carries class for colouring")
    ck(rN.xpText == "+1500 xp", "row: positive xp cell")
    ck(rN.agoText:find("ago") ~= nil, "row: ago text formatted")
    local rM = IU.RowModel({ t = T - 30, name = "Zul'Gurub", dur = 60, gold = -1200, xp = 0, merged = true }, "Alt-Realm", "WARLOCK", T)
    ck(rM.merged == true, "row: merged flag true")
    ck(rM.goldToken == "danger", "row: negative gold reads danger")
    ck(rM.xpText == nil, "row: zero xp -> no xp cell")
    ck(rM.agoText == "just now", "row: sub-60s -> just now")

    -- A6.3 -- a run that spanned a relog has no in-memory dur, only the PERSISTED
    -- exit epoch. It used to render 0s forever.
    local rRelog = IU.RowModel({ t = T - 5000, name = "Stratholme", dur = 0, exitT = T - 3200 }, "Alt-Realm", "PALADIN", T)
    ck(rRelog.dur == 1800, "row: duration recovered from the persisted exit epoch (got " .. rRelog.dur .. ")")
    local rNoExit = IU.RowModel({ t = T - 900, name = "Scholomance", dur = 0 }, "Alt-Realm", "PRIEST", T)
    ck(rNoExit.dur == 900, "row: bounded now-entry fallback for an unclosed run")
    local rAncient = IU.RowModel({ t = T - 400000, name = "Old", dur = 0 }, "Alt-Realm", "PRIEST", T)
    ck(rAncient.dur == 0, "row: an ancient unclosed run reports 0, not days")
    local rOpen = IU.RowModel({ t = T - 300, name = "Live", dur = 0 }, "Alt-Realm", "DRUID", T, true)
    ck(rOpen.dur == 300, "row: the live open run reports elapsed")

    -- A6.4 -- gold prefers the loot-only total; the wallet delta is the fallback.
    local rLoot = IU.RowModel({ t = T - 60, name = "Blackrock Depths", goldLoot = 48000, gold = -12000 }, "Alt-Realm", "ROGUE", T)
    ck(rLoot.gold == 48000, "row: loot total beats the wallet delta")
    ck(rLoot.goldFromLoot == true, "row: flagged as loot-sourced")
    ck(rLoot.goldToken == "muted", "row: a profitable run that repaired no longer reads danger")
    local rWallet = IU.RowModel({ t = T - 60, name = "Dire Maul", goldLoot = 0, gold = 7000 }, "Alt-Realm", "ROGUE", T)
    ck(rWallet.gold == 7000 and rWallet.goldFromLoot == false, "row: falls back to the wallet delta")

    -- A6.5 -- XP is never negative in the cell, whatever the entry carries.
    local rNeg = IU.RowModel({ t = T - 60, name = "Maraudon", xp = -38000 }, "Alt-Realm", "HUNTER", T)
    ck(rNeg.xp == 0 and rNeg.xpText == nil, "row: a legacy negative xp entry renders no cell")

    -- ── round-15 item 1: the COMPACT register cells for the RECENT columns ──
    ck(IU.CompactMoney(48000) == "4g",   "compact gold: 4g 80s -> 4g")
    ck(IU.CompactMoney(-120000) == "-12g", "compact gold: keeps the sign")
    ck(IU.CompactMoney(9999) == "99s",   "compact gold: sub-gold -> silver")
    ck(IU.CompactMoney(35) == "35c",     "compact gold: sub-silver -> copper")
    ck(IU.CompactMoney(0) == "0c",       "compact gold: a zero-loot run still renders a cell")
    ck(IU.CompactMoney(-35) == "-35c",   "compact gold: negative copper keeps the sign")

    ck(IU.CompactXP(950) == "+950",      "compact xp: under 1k is exact")
    ck(IU.CompactXP(1500) == "+1.5k",    "compact xp: 1500 -> +1.5k")
    ck(IU.CompactXP(12400) == "+12.4k",  "compact xp: 12400 -> +12.4k")
    ck(IU.CompactXP(123456) == "+123k",  "compact xp: six figures drop the decimal")
    ck(IU.CompactXP(0) == nil,           "compact xp: zero -> no cell")
    ck(IU.CompactXP(-5) == nil,          "compact xp: negative -> no cell")

    ck(IU.CompactAgo(0) == "now",        "compact ago: sub-minute -> now")
    ck(IU.CompactAgo(59) == "now",       "compact ago: 59s -> now")
    ck(IU.CompactAgo(2820) == "47m",     "compact ago: 47m")
    ck(IU.CompactAgo(4320) == "1h12m",   "compact ago: compact hour+minute, no space (got " ..
        tostring(IU.CompactAgo(4320)) .. ")")

    -- Cells over a real RowModel: the numbers RowModel computes, in column form.
    local rCells = IU.RowModel({ t = T - 4320, name = "Blackrock Depths", dur = 4320,
                                 goldLoot = 48000, xp = 12400 }, "Alt-Realm", "ROGUE", T)
    ck(rCells.ago == 4320, "row: exposes raw age seconds for the cell layer")
    local cells = IU.RecentCells(rCells)
    ck(cells.dur == "1h12m", "cells: duration compact (got " .. tostring(cells.dur) .. ")")
    ck(cells.gold == "4g", "cells: gold compact from the LOOT total")
    ck(cells.xp == "+12.4k", "cells: xp compact")
    ck(cells.ago == "1h12m", "cells: ago compact")
    ck(cells.goldToken == "muted", "cells: positive gold carries the calm token")
    local negCells = IU.RecentCells(IU.RowModel({ t = T - 30, name = "Dire Maul", dur = 30,
                                                  gold = -12000, xp = 0 }, "Alt-Realm", "ROGUE", T))
    ck(negCells.goldToken == "danger", "cells: negative gold carries danger, per RowModel")
    ck(negCells.gold == "-1g", "cells: negative gold cell")
    ck(negCells.xp == nil, "cells: a zero-xp run renders no xp cell")
    ck(negCells.ago == "now", "cells: a fresh run reads now")
    local emptyCells = IU.RecentCells(nil)
    ck(emptyCells.gold == "0c" and emptyCells.ago == "now" and emptyCells.xp == nil,
        "cells: nil model degrades to zeroes, never errors")

    -- Column budget: the four numeral columns must still leave the instance name
    -- a readable flex inside the panel's 344px of content.
    local RCOL = IU.RECENT_COLS
    ck(RCOL.content == 344, "cols: budget is the 364 panel minus 10px padding a side")
    ck(IU.InstanceFlexWidth() == 105,
        "cols: instance name flexes to 105px (got " .. IU.InstanceFlexWidth() .. ")")
    ck(IU.InstanceFlexWidth() >= 90,
        "cols: the instance name keeps at least 90px -- 'Blackrock Depths' must fit")
    local fixedSum = RCOL.name + 2 * RCOL.pad + RCOL.dur + RCOL.gold + RCOL.xp + RCOL.ago
                     + 3 * RCOL.gap + IU.InstanceFlexWidth()
    ck(fixedSum == RCOL.content, "cols: the columns exactly consume the content width")

    -- ── The NIT-parity row hover ────────────────────────────────────────────
    -- A label lookup keeps these assertions independent of line ORDER, which is
    -- presentation and will keep moving.
    local function tipVal(tip, label)
        for _, ln in ipairs((tip and tip.lines) or {}) do
            if ln[1] == label then return ln[2] end
        end
        return nil
    end

    local tip = IU.RowTooltip(rCells, T)
    ck(tip.title == "Blackrock Depths", "tooltip: titled with the instance")
    ck(tipVal(tip, "Time inside") == rCells.durText, "tooltip: full duration text")
    ck(tipVal(tip, "Gold from mobs") == "4g 80s 0c (looted)",
        "tooltip: exact coin + source (got " .. tostring(tipVal(tip, "Gold from mobs")) .. ")")
    ck(tipVal(tip, "XP") == "+12400 xp", "tooltip: exact xp")
    ck(tipVal(tip, "When") == rCells.agoText, "tooltip: full ago text")
    ck(tipVal(tip, "Left") == "still inside", "tooltip: an unclosed run says so")
    ck(tipVal(tip, "Entered") ~= nil, "tooltip: entered clock time present")
    ck(tipVal(tip, "Instance ID") == nil, "tooltip: no serial line when there is no serial")
    ck(tipVal(tip, "Mobs killed") == nil, "tooltip: no mob line on a run that killed nothing")
    ck(tip.groupPairs == nil and tip.tradeLines == nil and tip.visitLines == nil,
        "tooltip: a detail-less run renders no detail sections")

    local rFull = IU.RowModel({
        t = T - 7200, exitT = T - 3600, name = "Stratholme", mapID = 329, serial = 5501,
        goldLoot = 482310, xp = 9400, mobXP = 312, mobKill = 318, enteredLevel = 58,
        group = "*Tester:58|Bramble:57|Cera:60", groupAvg = 58.3,
        trades = { { t = T - 5000, who = "Bramble", gave = 500000, got = 0 },
                   { t = T - 4000, who = "Cera", gave = 0, got = 120000 } },
    }, "Tester-Realm", "MAGE", T)
    ck(rFull.mobCount == 312, "row: mob count prefers the XP-derived counter")
    ck(#rFull.group == 3, "row: group decoded from the stored snapshot")
    local tipF = IU.RowTooltip(rFull, T)
    ck(tipVal(tipF, "Instance ID") == "5501", "tooltip: the serial the row is grouped on")
    ck(tipVal(tipF, "Mobs killed") == "312", "tooltip: mob count")
    ck(tipVal(tipF, "Gold from mobs") == "48g 23s 10c (looted)",
        "tooltip: raw mob coin in full (got " .. tostring(tipVal(tipF, "Gold from mobs")) .. ")")
    ck(tipVal(tipF, "Entered level") == "58", "tooltip: level walked in at")
    ck(tipVal(tipF, "Average group level") == "58.3", "tooltip: average group level")
    ck(tipVal(tipF, "Left") ~= "still inside", "tooltip: a closed run reports its exit clock")
    ck(tipF.groupHeader == "Group (3)", "tooltip: roster header carries the count")
    ck(#tipF.groupPairs == 2, "tooltip: 3 members -> 2 two-column rows")
    ck(tipF.groupPairs[1][1] == "Tester 58 (you)", "tooltip: the character's own row is annotated")
    ck(tipF.groupPairs[1][2] == "Bramble 57", "tooltip: second column filled")
    ck(tipF.groupPairs[2][2] == "", "tooltip: an odd member count leaves the last cell empty")
    ck(#tipF.tradeLines == 2, "tooltip: both trades listed")
    ck(tipF.tradeLines[1]:find("Gave 50g 0s 0c to Bramble", 1, true) ~= nil,
        "tooltip: trade phrasing (got " .. tostring(tipF.tradeLines[1]) .. ")")
    ck(tipF.tradeLines[2]:find("Received 12g 0s 0c from Cera", 1, true) ~= nil,
        "tooltip: a received trade reads the other way")
    ck(tipF.tradeLines[1]:find("ago") ~= nil, "tooltip: trades carry when they happened")

    -- A boosted run: every mob grey, no XP at all, so the kill counter carries it.
    local rBoost = IU.RowModel({ t = T - 600, name = "Scholomance", mobXP = 0, mobKill = 210 },
                               "Alt-Realm", "PRIEST", T)
    ck(rBoost.mobCount == 210, "row: the kill counter carries a boosted grey run")
    ck(IU.MobCount({ mobXP = 5, mobKill = 99 }) == 5, "mob count: XP-derived wins when non-zero")
    ck(IU.MobCount({}) == 0, "mob count: nothing recorded -> 0")

    -- Full coin form + the wallet-source label.
    ck(IU.FormatMoneyFull(482310) == "48g 23s 10c", "full coin: g/s/c")
    ck(IU.FormatMoneyFull(9905) == "99s 5c", "full coin: sub-gold")
    ck(IU.FormatMoneyFull(7) == "7c", "full coin: copper only")
    ck(IU.FormatMoneyFull(-12000) == "-1g 20s 0c", "full coin: keeps the sign")
    ck(IU.FormatMoneyFull(0) == "0c", "full coin: zero")
    local tipW = IU.RowTooltip(IU.RowModel({ t = T - 60, name = "Zul'Gurub", gold = 7000 },
                                            "Alt-Realm", "ROGUE", T), T)
    ck(tipW.lines and tipVal(tipW, "Gold from mobs"):find("wallet delta") ~= nil,
        "tooltip: wallet-sourced coin is labelled as such")

    -- Clock text: shape only (the value is the harness machine's timezone).
    ck(IU.ClockText(1660972435, 1660972435):match("^%d+:%d%d") ~= nil,
        "clock: renders as H:MM (got " .. tostring(IU.ClockText(1660972435, 1660972435)) .. ")")
    ck(IU.ClockText(nil) == nil, "clock: nil epoch -> nil")
    ck(IU.ClockText(0) == nil, "clock: a zero exit epoch is not a time")
    local older = IU.ClockText(1660972435, 1660972435 + 3 * 86400)
    ck(older and #older > #(IU.ClockText(1660972435, 1660972435) or ""),
        "clock: an entry from another day carries its date")

    -- Roster capping: a 40-man raid must not grow an unbounded tooltip.
    local raid = {}
    for i = 1, 40 do raid[i] = { name = "Raider" .. i, level = 60 } end
    local capped = IU.GroupPairs(raid, 20)
    ck(#capped == 11, "roster: 20 shown as 10 pair-rows + a '+20 more' tail (got " .. #capped .. ")")
    ck(capped[11][1] == "+20 more", "roster: overflow tail")
    ck(#IU.GroupPairs({}, 20) == 0, "roster: no members -> no rows")
    ck(IU.GroupPairs({ { name = "Solo" } }, 20)[1][1] == "Solo",
        "roster: a member with no level renders bare")

    -- ── ONE ROW PER PHYSICAL INSTANCE: the display-grouping matrix ──────────
    -- Owner: "if i leave and re-enter the same instance, without resetting it,
    -- then that should show as a single line, rather than 2."
    local function gitem(aid, nr, e) return { aid = aid, nameRealm = nr, entry = e, t = e.t } end
    local function newestFirst(...)
        local l = { ... }
        table.sort(l, function(a, b) return a.t > b.t end)
        return l
    end

    -- 1. Corpse run: two visits, ONE serial -> ONE row. This is the headline.
    local surv  = { t = T - 3000, exitT = T - 2400, name = "Stratholme", mapID = 329,
                    serial = 5501, goldLoot = 90000, xp = 900, mobXP = 40, merged = false }
    local corpse = { t = T - 2100, name = "Stratholme", mapID = 329, serial = 5501,
                     goldLoot = 30000, xp = 300, mobXP = 12, merged = true }
    local gA = IU.GroupVisits(newestFirst(gitem("1", "A-R", surv), gitem("1", "A-R", corpse)))
    ck(#gA == 1, "grouping: a corpse run folds into ONE row (got " .. #gA .. ")")
    ck(gA[1].count == 2, "grouping: …that knows it holds 2 visits")
    ck(gA[1].primary == surv, "grouping: the survivor is the row's primary entry")
    ck(gA[1].visits[1].entry == surv and gA[1].visits[2].entry == corpse,
        "grouping: visits listed oldest-first")

    -- 2. Reset + rerun: same dungeon, DIFFERENT serial -> two rows, as the owner
    --    wants (they billed two slots and must stay visible as two).
    local rerun = { t = T - 1200, exitT = T - 600, name = "Stratholme", mapID = 329,
                    serial = 5502, goldLoot = 50000, merged = false }
    local gB = IU.GroupVisits(newestFirst(gitem("1", "A-R", surv), gitem("1", "A-R", corpse),
                                          gitem("1", "A-R", rerun)))
    ck(#gB == 2, "grouping: a reset+rerun keeps its OWN row (got " .. #gB .. ")")
    ck(gB[1].primary == rerun, "grouping: rows are newest-first")

    -- 3. Same serial, DIFFERENT character -> never the same row.
    local other = { t = T - 2900, name = "Stratholme", mapID = 329, serial = 5501, merged = false }
    local gC = IU.GroupVisits(newestFirst(gitem("1", "A-R", surv), gitem("1", "B-R", other)))
    ck(#gC == 2, "grouping: one row per CHARACTER, even on a shared serial")
    local gD = IU.GroupVisits(newestFirst(gitem("1", "A-R", surv), gitem("2", "A-R", other)))
    ck(#gD == 2, "grouping: one row per ACCOUNT too")

    -- 4. Aggregates. The engine ALREADY folded the corpse run's takings into the
    --    survivor, so the row must not add them a second time.
    local mA = IU.RowModel(gA[1].primary, "A-R", "ROGUE", T, false, gA[1].visits)
    ck(mA.gold == 90000, "grouped row: engine-folded totals are NOT double-counted (got "
        .. mA.gold .. ")")
    ck(mA.xp == 900, "grouped row: xp likewise taken from the survivor")
    ck(mA.mobCount == 40, "grouped row: mob count likewise")
    ck(mA.visitCount == 2 and mA.folded == true, "grouped row: flagged as an engine fold")
    ck(mA.ago == T - corpse.t, "grouped row: AGO reads from the NEWEST visit")
    ck(mA.instanceText == "Stratholme \195\1512",
        "grouped row: the cell marks the fold (got " .. tostring(mA.instanceText) .. ")")
    local tipA = IU.RowTooltip(mA, T)
    ck(tipA.visitHeader == "Visits (2)", "grouped tooltip: a visits section appears")
    ck(#tipA.visitLines == 2, "grouped tooltip: one line per constituent visit")
    ck(tipA.visitLines[1]:find("Entered") ~= nil, "grouped tooltip: visits list entry times")
    ck(tipA.visitLines[2]:find("(re-entry)", 1, true) ~= nil,
        "grouped tooltip: the re-entry is marked (got " .. tostring(tipA.visitLines[2]) .. ")")

    -- 5. A single-visit row carries no visits section and reports its own numbers.
    local gSolo = IU.GroupVisits(newestFirst(gitem("1", "A-R", rerun)))
    local mSolo = IU.RowModel(gSolo[1].primary, "A-R", "ROGUE", T, false, gSolo[1].visits)
    ck(mSolo.visitCount == 1 and mSolo.visits == nil, "single-visit row: no visits section")
    ck(mSolo.instanceText == "Stratholme", "single-visit row: bare instance name, no fold marker")
    ck(IU.RowTooltip(mSolo, T).visitLines == nil, "single-visit tooltip: no visits block")
    ck(mSolo.dur == 600, "single-visit row: its own duration (got " .. mSolo.dur .. ")")
    -- The LIVE run still reports live elapsed through the grouped path.
    local live = { t = T - 420, name = "Dire Maul", mapID = 429, serial = 8800 }
    local gLive = IU.GroupVisits(newestFirst(gitem("1", "A-R", live)))
    local mLive = IU.RowModel(gLive[1].primary, "A-R", "ROGUE", T, true, gLive[1].visits)
    ck(mLive.dur == 420, "grouped row: an open run reports live elapsed (got " .. mLive.dur .. ")")
    local gLiveFold = IU.GroupVisits(newestFirst(gitem("1", "A-R", surv), gitem("1", "A-R", corpse)))
    local mLiveFold = IU.RowModel(gLiveFold[1].primary, "A-R", "ROGUE", T, true, gLiveFold[1].visits)
    ck(mLiveFold.dur == 3000, "grouped row: a still-open folded run measures from the survivor's entry")

    -- 6. SERIAL-LESS LEGACY rows. Conservative by construction: same character,
    --    same instance, the earlier visit recorded an exit, and the re-entry
    --    inside the join gap. Anything else stays two rows.
    local lg1 = { t = T - 5000, exitT = T - 4700, name = "Uldaman", mapID = 70 }
    local lg2 = { t = T - 4500, name = "Uldaman", mapID = 70 }              -- 200s later
    ck(#IU.GroupVisits(newestFirst(gitem("1", "A-R", lg1), gitem("1", "A-R", lg2))) == 1,
        "legacy: a prompt re-entry into the same instance folds")
    local far = { t = T - 4700 + IU.LEGACY_JOIN_GAP + 1, name = "Uldaman", mapID = 70 }
    ck(#IU.GroupVisits(newestFirst(gitem("1", "A-R", lg1), gitem("1", "A-R", far))) == 2,
        "legacy: beyond the join gap they stay separate")
    local noExit = { t = T - 5000, name = "Uldaman", mapID = 70 }           -- never closed
    ck(#IU.GroupVisits(newestFirst(gitem("1", "A-R", noExit), gitem("1", "A-R", lg2))) == 2,
        "legacy: no exit epoch on the earlier run -> do NOT fold")
    local elsewhere = { t = T - 4500, name = "Maraudon", mapID = 349 }
    ck(#IU.GroupVisits(newestFirst(gitem("1", "A-R", lg1), gitem("1", "A-R", elsewhere))) == 2,
        "legacy: a different instance never folds")
    local serialled = { t = T - 4500, name = "Uldaman", mapID = 70, serial = 77 }
    ck(#IU.GroupVisits(newestFirst(gitem("1", "A-R", lg1), gitem("1", "A-R", serialled))) == 2,
        "legacy: a run that DID observe a serial is judged on identity, not the gap")
    -- Imported rows are never folded: the source deleted its merged runs already.
    local imp1 = { t = T - 5000, exitT = T - 4700, name = "Uldaman", mapID = 70, src = "nit" }
    local imp2 = { t = T - 4500, name = "Uldaman", mapID = 70, src = "nit" }
    ck(#IU.GroupVisits(newestFirst(gitem("1", "A-R", imp1), gitem("1", "A-R", imp2))) == 2,
        "legacy: imported runs are already distinct entries and never fold")
    -- A chain of three legacy visits collapses into one row.
    local ch1 = { t = T - 9000, exitT = T - 8800, name = "Maraudon", mapID = 349, goldLoot = 100 }
    local ch2 = { t = T - 8700, exitT = T - 8500, name = "Maraudon", mapID = 349, goldLoot = 200 }
    local ch3 = { t = T - 8400, exitT = T - 8000, name = "Maraudon", mapID = 349, goldLoot = 300 }
    local gChain = IU.GroupVisits(newestFirst(gitem("1", "A-R", ch1), gitem("1", "A-R", ch2),
                                              gitem("1", "A-R", ch3)))
    ck(#gChain == 1 and gChain[1].count == 3, "legacy: a 3-visit chain is one row")
    local mChain = IU.RowModel(gChain[1].primary, "A-R", "ROGUE", T, false, gChain[1].visits)
    ck(mChain.gold == 600, "legacy row: takings ARE summed (nothing folded them) (got "
        .. mChain.gold .. ")")
    ck(mChain.dur == 800, "legacy row: durations summed across the visits (got " .. mChain.dur .. ")")

    -- 7. Legacy rows union their roster + trades across the visits.
    local lr1 = { t = T - 9000, exitT = T - 8800, name = "Maraudon", mapID = 349,
                  group = "*Tester:40|Bramble:41", groupAvg = 40.5,
                  trades = { { t = T - 8900, who = "Bramble", gave = 100, got = 0 } } }
    local lr2 = { t = T - 8700, name = "Maraudon", mapID = 349,
                  group = "*Tester:41|Cera:42",
                  trades = { { t = T - 8600, who = "Cera", gave = 0, got = 200 } } }
    local gR = IU.GroupVisits(newestFirst(gitem("1", "A-R", lr1), gitem("1", "A-R", lr2)))
    local mR = IU.RowModel(gR[1].primary, "A-R", "ROGUE", T, false, gR[1].visits)
    ck(#mR.group == 3, "legacy row: rosters unioned across visits (got " .. #mR.group .. ")")
    ck(mR.group[1].level == 41, "legacy row: a level that changed between visits updates")
    ck(mR.trades and #mR.trades == 2, "legacy row: trades gathered from every visit")

    -- 8. Empty / degenerate input never errors.
    ck(#IU.GroupVisits({}) == 0, "grouping: an empty list yields no rows")
    ck(#IU.GroupVisits(nil) == 0, "grouping: nil yields no rows")

    -- ── round-15 item 2: the cap-countdown ticker gate ──────────────────────
    local mOK  = IU.MeterModel({ hour = 2, day = 10 }, T, caps)
    local mCapH = IU.MeterModel({ hour = 5, day = 10, nextHourSlotAt = T + 60 }, T, caps)
    local mCapD = IU.MeterModel({ hour = 1, day = 30, nextDaySlotAt = T + 60 }, T, caps)
    ck(IU.AnyAtCap({ mOK }) == false, "ticker: nothing at cap -> no ticker")
    ck(IU.AnyAtCap({ mOK, mCapH }) == true, "ticker: an hourly cap arms the ticker")
    ck(IU.AnyAtCap({ mOK, mCapD }) == true, "ticker: a daily cap arms the ticker")
    ck(IU.AnyAtCap({}) == false, "ticker: no meters -> no ticker")
    ck(IU.AnyAtCap(nil) == false, "ticker: nil model list -> no ticker")
    -- The neutral TOTAL row must never hold the ticker open, however large the sum.
    ck(IU.AnyAtCap({ IU.TotalModel({ hour = 99, day = 999 }) }) == false,
        "ticker: the cross-account total never counts as at-cap")
    ck(IU.TickerShouldRun(true,  { mCapH }) == true,  "ticker: visible + capped -> runs")
    ck(IU.TickerShouldRun(false, { mCapH }) == false, "ticker: hidden panel -> stopped even at cap")
    ck(IU.TickerShouldRun(true,  { mOK })   == false, "ticker: visible + under cap -> stopped")
    ck(IU.TickerShouldRun(false, { mOK })   == false, "ticker: hidden + under cap -> stopped")
    ck(IU.TickerShouldRun(nil,   { mCapH }) == false, "ticker: nil visibility -> stopped")
    -- And the countdown it repaints must actually advance with the clock.
    local t0 = IU.MeterModel({ hour = 5, nextHourSlotAt = T + 125 }, T, caps)
    local t1 = IU.MeterModel({ hour = 5, nextHourSlotAt = T + 125 }, T + 1, caps)
    ck(IU.MeterText("Hr", t0.hour) == "Hr 5/5 2:05", "ticker: countdown at t0")
    ck(IU.MeterText("Hr", t1.hour) == "Hr 5/5 2:04", "ticker: countdown advances one second later")

    local data = { accounts = {
            ["1"] = { characters = { ["A-R"] = { classTag = "ROGUE" } }, homeless = { ["H-R"] = { classTag = "PRIEST" } } },
        }, instances = {
            ["1"] = { ["A-R"] = { entries = { { t = T - 10, name = "MC" }, { t = T - 50, name = "MC" } } } },
            ["2"] = { ["B-R"] = { entries = { { t = T - 5, name = "BWL" } } } },
        } }
    local all = IU.GatherEntries(data.instances)
    ck(#all == 3, "gather: 3 entries across accounts (got " .. #all .. ")")
    ck(all[1].entry.name == "BWL", "gather: newest first (BWL t-5 leads)")
    ck(all[#all].entry.t == T - 50, "gather: oldest last")
    ck(#IU.FilterEntries(all, { aid = "1" }, "A-R") == 2, "filter: scope acct 1 -> 2")
    local fc = IU.FilterEntries(all, { thisChar = true }, "B-R")
    ck(#fc == 1 and fc[1].nameRealm == "B-R", "filter: this-character")
    local ids = IU.SortedAccountIDs({ ["10"] = {}, ["2"] = {}, ["1"] = {} })
    ck(ids[1] == "1" and ids[2] == "2" and ids[3] == "10", "account ids sorted numerically")
    local cl = IU.ClassLookup(data)
    ck(cl["A-R"] == "ROGUE" and cl["H-R"] == "PRIEST", "class lookup maps nameRealm -> class")

    -- ExpRow (round-10 item 2): guards absent engine fields; level-60 = just Level 60.
    local EM = "\226\128\148"
    local r60 = IU.ExpRow({ level = 60, xp = 1, xpMax = 2, restedXP = 3 }, "Max-R", "WARRIOR")
    ck(r60.maxed == true and r60.levelText == "Level 60", "exp: level 60 -> maxed / Level 60")
    ck(r60.xpText == nil and r60.restedText == nil, "exp: level 60 has no xp/rested")
    local rMid = IU.ExpRow({ level = 40, xp = 8000, xpMax = 16000, restedXP = 24000 }, "Mid-R", "MAGE")
    ck(rMid.levelText == "Level 40", "exp: level text")
    ck(rMid.xpText == "8000/16000", "exp: xp cur/total")
    ck(rMid.restedText == "150% (Max)", "exp: rested 24000/16000 = 150% (Max)")
    local rLow = IU.ExpRow({ level = 20, xp = 500, xpMax = 4000, restedXP = 800 }, "Low-R", "ROGUE")
    ck(rLow.restedText == "20%", "exp: rested 800/4000 = 20%")
    local rNone = IU.ExpRow({ level = 30 }, "None-R", "PRIEST")   -- engine fields absent
    ck(rNone.xpText == EM and rNone.restedText == EM, "exp: absent engine fields -> em-dash")

    -- CharList (round-10 item 3): level desc, then name asc, "All" sentinel at top.
    local cdata = { accounts = {
        ["1"] = { characters = { ["Bee-R"] = { classTag = "MAGE", level = 60 },
                                 ["Ann-R"] = { classTag = "ROGUE", level = 60 },
                                 ["Cee-R"] = { classTag = "PRIEST", level = 42 } } },
    } }
    local list = IU.CharList(cdata)
    ck(list[1].all == true and list[1].label == "All", "charlist: All sentinel at top")
    ck(list[2].nameRealm == "Ann-R" and list[3].nameRealm == "Bee-R",
        "charlist: level 60 block ordered by name asc (Ann before Bee)")
    ck(list[4].nameRealm == "Cee-R" and list[4].level == 42, "charlist: lower level last")

    -- ── ROUND-24: the three-dropdown model ──────────────────────────────────────
    local d24 = { accounts = {
        ["1"] = { characters = {
            ["Ann-R"] = { level = 60, classTag = "MAGE" },
            ["Cee-R"] = { level = 42, classTag = "ROGUE", xp = 100, xpMax = 400, restedXP = 600 },
        } },
        ["2"] = { characters = {
            ["Bee-R"] = { level = 60, classTag = "PRIEST" },
            ["Dee-R"] = { level = 15, classTag = "DRUID", xp = 50, xpMax = 200, restedXP = 100 },
        }, homeless = { ["Eee-R"] = { level = 7, classTag = "WARRIOR" } } },
        ["x9"] = { characters = { ["Zed-R"] = { level = 30, classTag = "MAGE" } } },
    } }

    -- ACCOUNT dropdown: All sentinel, then numeric accounts as "Account N". A non-numeric
    -- id gets no entry (no sensible label), matching the round-23 header rule.
    local accts = IU.AccountList(d24)
    ck(accts[1].all == true and accts[1].label == "All", "accountlist: All sentinel first")
    ck(accts[2].label == "Account 1" and accts[2].aid == "1", "accountlist: 'Account 1'")
    ck(accts[3].label == "Account 2", "accountlist: numeric order")
    ck(#accts == 3, "accountlist: non-numeric account id excluded (got " .. #accts .. ")")

    -- CHARACTER dropdown cascades off the account.
    local all1 = IU.CharList(d24, "1")
    ck(#all1 == 3, "charlist(aid=1): All + 2 chars")
    ck(all1[2].nameRealm == "Ann-R" and all1[3].nameRealm == "Cee-R", "charlist(aid=1): level desc")
    local all2 = IU.CharList(d24, "2")
    local names = {}; for i = 2, #all2 do names[#names + 1] = all2[i].nameRealm end
    ck(#all2 == 4, "charlist(aid=2): All + characters AND homeless")
    ck(table.concat(names, ",") == "Bee-R,Dee-R,Eee-R", "charlist(aid=2): homeless included, level desc")
    ck(#IU.CharList(d24) == 7, "charlist(nil): every account (All + 6)")

    -- REST view: NON-60s ONLY, 60s excluded entirely.
    local rest = IU.RestRows(d24)
    local rnames = {}; for _, r in ipairs(rest) do rnames[#rnames + 1] = r.nameRealm end
    -- Cee-R 42 > Zed-R 30 > Dee-R 15 > Eee-R 7.
    ck(table.concat(rnames, ",") == "Cee-R,Zed-R,Dee-R,Eee-R",
        "rest: non-60s only, level desc (got " .. table.concat(rnames, ",") .. ")")
    for _, r in ipairs(rest) do ck(r.level < 60, "rest: no level-60 row (" .. r.nameRealm .. ")") end
    ck(#IU.RestRows(d24, "1") == 1 and IU.RestRows(d24, "1")[1].nameRealm == "Cee-R",
        "rest: account filter applies")
    ck(#IU.RestRows(d24, "2", "Dee-R") == 1, "rest: character filter applies")
    ck(#IU.RestRows(d24, "1", "Dee-R") == 0, "rest: char not in the account -> empty")
    -- The rest row still carries the NIT information set.
    local cee = IU.RestRows(d24, "1")[1]
    ck(cee.levelText == "Level 42" and cee.xpText == "100/400", "rest: level + XP cur/max")
    ck(cee.restedText == "150% (Max)", "rest: rested percent with the (Max) marker")

    -- CASCADE: changing account resets the character unless it belongs to the new account.
    ck(IU.ResolveCharSelection(d24, "1", "Cee-R") == "Cee-R", "cascade: char kept when it belongs")
    ck(IU.ResolveCharSelection(d24, "2", "Cee-R") == nil, "cascade: char RESET when it does not")
    ck(IU.ResolveCharSelection(d24, nil, "Cee-R") == "Cee-R", "cascade: All accounts keeps any char")
    ck(IU.ResolveCharSelection(d24, "1", nil) == nil, "cascade: All char stays All")
    ck(IU.ResolveCharSelection(d24, "2", "Eee-R") == "Eee-R", "cascade: homeless char counts as belonging")
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("instancesui", function(verbose)
        local fails = {}
        local ok = pcall(testInstancesUI, fails)
        local passed = ok and #fails == 0
        if verbose and ns and ns.Print then
            if passed then ns:Print("  PASS instancesui/view model")
            elseif not ok then ns:Print("  FAIL instancesui/view model :: error in test")
            else for _, f in ipairs(fails) do ns:Print("  FAIL instancesui/view model :: " .. f) end end
        end
        return passed
    end)
end
