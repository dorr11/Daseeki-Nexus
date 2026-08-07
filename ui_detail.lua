-- Daseeki Nexus — ui_detail.lua
-- The RIGHT-TOP detail pane of the control-panel dashboard (master/detail).
--
-- NEXUS DIRECTION PIVOT (BRAND_SPEC 2026-07-29): control-panel style — cool, flat,
-- sharp, precision-aligned. This pane is the always-visible detail card for the
-- character selected in the left card list (ui_cards.lua). NO open/close mechanics,
-- NO reveal animation: an instant SN-style content swap on selection. The proven
-- display logic is re-housed here from the retired ui_ledgerpage.lua (ns.LedgerPage)
-- — same buff-tile state model, raid tally, DMF parenthetical and telemetry — but
-- rendered into the mockup's FIXED geometry instead of a pooled open-entry page.
--
-- AESTHETIC (control-panel, §9/§10 + pivot): flat token fills, sharp 1px UI.Hairline
-- rules, uppercase microLabels, outlined numerals. NO PaintLedgerGround / grain /
-- serif here. All colors via theme tokens (the mockup renders Winterspring-Frost
-- token VALUES; this code names tokens so every theme skins correctly).
--
-- GEOMETRY (mockup nexus-controlpanel-notes.md, detail pane = 316 tall):
--   pad 12/14 · header band (border-bottom) · dgrid cols 1fr / 214, gutter 14 ·
--   buff grid 3 cols gap 6 (cell = 20px tile + name + duration) · raid tally ·
--   chrono/hearth telemetry · note editbox · Invite + Cancel-buffs chips.
--
-- Clean-room build on our own DaseekiUI stack. No third-party code or identifiers.

local ADDON, ns = ...
local UI = DaseekiUI                 -- nil under the headless harness; only ever
local Detail = {}                    -- dereferenced inside function bodies below.
ns.Detail = Detail

----------------------------------------------------------------------
-- Layout tokens (whole-px; mockup values).
----------------------------------------------------------------------
local PAD_V     = 10          -- round-20b: 12 -> 10, compressing the header band upward
local PAD_H     = 14
local HEADER_H  = 31          -- header band height. ROUND-20b: was 40 but the code rendered
                              -- HEADER_H-6 (34) — the mismatch my round-18 alignment modelled
                              -- wrongly. Now literal: SetHeight(HEADER_H), no hidden -6.
local COL_GAP   = 14
-- ROUND-25 (owner): the detail grid is a FIXED 60 / 40 split rather than a fixed-width
-- right column. The fractions are the owner's decision — the arithmetic below VALIDATES
-- that the content still fits them (and flags if it ever stops), it does NOT derive them.
--     inner = PANE_W 742 - 2*PAD_H 14           = 714
--     avail = inner - COL_GAP 14                = 700
--     C1    = 60% of 700                        = 420   (was 486)
--     C2    = 40% of 700                        = 280   (was 214)
local PANE_W    = 742         -- detail.pane width (LAYOUT_SPEC)
local C1_FRAC   = 0.60
local COL_SPLIT                -- assigned just below, once ColumnSplit is defined
local COL_L_W, COL_R_W        -- C1 / C2 pixel widths
-- Buff display (owner round-3 verdict): a LABELED ROW LIST (return to the pre-rebuild
-- detail panel's row pattern) — one row per tracked buff: small cropped/framed icon ·
-- buff name (tinted by its family hue) · right-aligned STATE status. NOT a tile grid
-- (that's the compact CARD strip, §5b). The name carries buff IDENTITY; the status
-- column carries STATE color (Missing / duration / Boon / DMF parenthetical).
local BUFF_ICON   = 16        -- row icon edge (cropped/framed)
local STATUS_X    = 210       -- round-18: buff-row STATUS left rail, measured from the row's
                              -- left edge — just past the longest buff name ("Rallying Cry of
                              -- the Dragonslayer") at the default font scale. Was effectively
                              -- ~486 (the left column's far edge) before the owner's fix.
local BUFF_ROW_H  = 18        -- buff row height (round-4: 18 so all 10 slots fit the pane)
local BUFF_ROW_GAP = 2        -- ROUND-19: restored 1 -> 2 (pitch 19 -> 20). Round-17 had cut
                              -- this to buy the header-rule padding, under protest; the
                              -- round-19 pane growth repays that debt. 10*18+9*2 = 198px.
-- ROUND-20 (owner): the bottom-left RAID LOCKOUTS block is STACKED — eyebrow on its own
-- line, the seven raid keys on the line below — instead of round-19's single inline row.
-- Block = LOCK_LBL_H + LOCK_LBL_GAP + LOCK_H = 31, plus LOCK_GAP above it = 37 (was 19),
-- so it costs +18, funded by the window growing 643 -> 661 on the same rule as round-19.
local LOCK_H      = 13        -- the raid-keys line
local LOCK_LBL_H  = 12        -- the "RAID LOCKOUTS" eyebrow line
local LOCK_LBL_GAP = 6        -- eyebrow -> keys (matches round-13's +6 header breathing room)
local LOCK_GAP    = 6         -- air between the buff list and the block
local LOCK_BLOCK  = LOCK_LBL_H + LOCK_LBL_GAP + LOCK_H   -- 31
-- Round-17 (owner, yellow arrow): the header's bottom hairline was OVERLAPPING the column
-- eyebrows. The rule sits HRULE_GAP below the header band, but the grid started at the
-- header's bottom edge (gridTop = -(PAD_V+HEADER_H)), i.e. 6px ABOVE the rule — so the
-- 1px line drew straight through "WORLD BUFFS · N/N HELD". The grid now starts BELOW the
-- rule with GRID_GAP of clear air, matching round-13's +6 feel under each column header.
-- ROUND-18 item 3 (owner): the header's bottom hairline must land on the SAME screen Y as
-- the TOP OF THE FIRST CARD in the left panel. Both panels share the body top rail
-- (MARGIN), so it is pure arithmetic across the two files:
--     first card top = MARGIN + CHIP_H(44) + LIST_PAD(12)          = MARGIN + 56
--     detail rule    = MARGIN + PAD_V(12) + HEADER_H(40) + HRULE_GAP
-- so PAD_V + HEADER_H + HRULE_GAP must equal 56. It was 58 (rule 2px low); HRULE_GAP goes
-- 6 -> 4 to close it, which keeps HEADER_H at 40 for the enlarged name. LAYOUT_SPEC pins
-- this with a cross-panel align assertion (detail.hrule vs cards.list).
local HRULE_GAP  = 4          -- header band bottom -> the 1px hairline (round-18: 6 -> 4)
local GRID_GAP   = 6          -- hairline -> the column eyebrow labels (round-17)
local BUFF_TOP    = 24        -- list top offset below the eyebrow label (round-13: 18->24,
                             -- +6 breathing room under the WORLD BUFFS header, even w/ CD/RAID)
local TILE_RIM  = "borderLite"   -- neutral held/boon icon rim (pop pass — visible edge)

-- Per-buff FAMILY HUE (echoes each spell icon's dominant color, reference-style) —
-- these are buff IDENTITY colors (like class/faction colors), deliberately NOT theme
-- chrome tokens: the spell art is theme-invariant, so the identity hue is too. Keys
-- match Dashboard.AURA_META[slot].key. Names fall back to the cream "text" token when
-- the hue's contrast against the active theme's ground is too low (see nameColor).
local BUFF_HUE = {
    ony        = { 0.753, 0.529, 0.227 },   -- Rallying Cry — dragon gold
    rend       = { 0.769, 0.192, 0.275 },   -- Warchief's — warchief red
    zg         = { 0.310, 0.620, 0.525 },   -- Zandalar — jungle teal
    songflower = { 0.525, 0.831, 0.169 },   -- Songflower — spring green
    dmf        = { 0.612, 0.420, 0.984 },   -- Sayge's fortune — arcane violet
    dmtap      = { 0.851, 0.541, 0.227 },   -- Fengus — ember orange
    dmtstam    = { 0.431, 0.561, 0.839 },   -- Mol'dar — steel blue
    dmtsp      = { 0.780, 0.471, 0.690 },   -- Slip'kik — savvy magenta
    battleshout= { 0.780, 0.612, 0.431 },   -- Battle Shout — warrior tan (whose buff it is)
    fff        = { 0.976, 0.478, 0.106 },   -- Fire Festival Fury — bonfire flame
}

-- Open-page raid tally order + labels (BRAND_SPEC §7 L3: MC BWL ZG AQ40 Naxx Ony AQ20;
-- keys match Store.RAID_KEYS). Round-17: locked = danger red, open+attuned = ok green,
-- not attuned = faint grey (see Detail.TallyToken). No raid diamonds.
-- ROUND-22 addendum (owner-canon): "MC BWL AQ40 NAXX | ONY ZG AQ20". The split is
-- semantic — WEEKLY-reset raids on the left, SHORT-CYCLE (Ony 5-day, ZG/AQ20 3-day) on the
-- right — so the divider marks a real boundary rather than decorating a line break.
local TALLY_ORDER = { "MC", "BWL", "AQ40", "Naxx", "Ony", "ZG", "AQ20" }
local TALLY_SPLIT = 4          -- divider sits AFTER this index (Naxx | Ony)
-- ROUND-23 BUGFIX. Round-22 emitted the divider as Colored("|", "faint"), which composes
-- |cffRRGGBB .. "|" .. |r  — and WoW's escape parser reads the resulting "||" as an ESCAPED
-- PIPE, renders one "|", then treats the trailing "r" as literal text and never closes the
-- colour. On screen: "Naxx |r Ony". The fix is to escape the pipe BEFORE colouring, so the
-- sequence becomes |cffRRGGBB .. "||" .. |r — the parser renders one grey pipe and the |r
-- still terminates the colour. This is the general hazard of composing user-visible glyphs
-- into colour-coded strings: any literal "|" must be doubled first.
local TALLY_DIVIDER = "||"     -- renders as a single "|"
Detail.TALLY_ORDER, Detail.TALLY_SPLIT = TALLY_ORDER, TALLY_SPLIT   -- for the tests

-- ROUND-25: the two-column split. PURE. The fractions are the OWNER'S FIXED DECISION;
-- this only turns them into pixels. Returns C1/C2 widths plus the intermediates, so the
-- validator and the tests can talk about the same numbers.
function Detail.ColumnSplit(paneW, padH, gap, c1Frac)
    paneW  = paneW  or PANE_W
    padH   = padH   or PAD_H
    gap    = gap    or COL_GAP
    c1Frac = c1Frac or C1_FRAC
    local inner = paneW - 2 * padH
    local avail = inner - gap
    local c1 = math.floor(avail * c1Frac + 0.5)
    return { inner = inner, avail = avail, gap = gap, c1 = c1, c2 = avail - c1 }
end

-- ROUND-25 VALIDATION (explicitly NOT derivation). Given the owner's fixed C1, check that
-- the left column still holds its widest content at a font scale, and report the shortfall
-- if it does not so the failure is loud rather than a silent overlap.
-- C1's two width-critical rows are:
--   * a buff row: the STATUS_X rail (a fixed px constant — it does NOT scale) plus the
--     widest status string, which DOES scale;
--   * the bottom raid tally: 7 keys + the weekly/short-cycle divider, all scaling.
-- `emPx` is the average glyph advance at scale 1.0 for the relevant font; the callers pass
-- the pane's own body/numeral sizes so the estimate tracks the real type.
function Detail.ColumnFits(c1, scale, opts)
    scale = scale or 1.0
    opts = opts or {}
    local bodyEm   = (opts.bodyEm or 12) * 0.52 * scale      -- status text (body)
    local numEm    = (opts.numEm  or 13) * 0.52 * scale      -- tally keys (numeral)
    local statusW  = #(opts.widestStatus or "1h 59m (Boon)") * bodyEm
    local tallyW   = #(opts.widestTally or "MC  BWL  AQ40  Naxx  |  Ony  ZG  AQ20") * numEm
    local needRow  = STATUS_X + statusW
    local need     = math.max(needRow, tallyW)
    return {
        need = math.floor(need + 0.5), have = c1,
        fits = need <= c1,
        short = math.max(0, math.floor(need - c1 + 0.5)),
        worst = (needRow >= tallyW) and "buff-row status" or "raid tally",
    }
end

COL_SPLIT = Detail.ColumnSplit()
COL_L_W, COL_R_W = COL_SPLIT.c1, COL_SPLIT.c2

local function Dash() return ns.Dashboard end
local function nowE()
    local D = Dash()
    return (D and D.Now and D.Now()) or (GetServerTime and GetServerTime()) or (time and time()) or 0
end

-- ════════════════════════════════════════════════════════════════════════════
--  PURE DISPLAY LOGIC (frame-free → unit-testable under the headless harness).
--  Re-housed verbatim from ui_ledgerpage.lua (the proven, owner-approved model).
-- ════════════════════════════════════════════════════════════════════════════

-- DMF cooldown remaining. A8 landed the real 4h online-time model in store.lua,
-- so this is now a thin delegation — the old local 8h-offline mirror is gone
-- (it returned 0 for any ONLINE character, which is why a 60 that had just taken
-- a fortune rendered READY, A8.2).
--
-- J4 / schema v3: routed through Dashboard.DMFCooldownRemaining rather than
-- straight at the store, because a REMOTE character's remaining now arrives over
-- the wire as a capture-time reading and has to be decayed against
-- rec.lastDataUpdate (frozen while booned, while offline, or with no reference
-- stamp) exactly like every other remote countdown on this pane. That decay is
-- ONE choke point in ui_shell, next to Dashboard.AuraRemaining; the store keeps
-- owning the local online-time accounting and stays the fallback there. Falls
-- back to the store directly if the shell is somehow absent (frameless load).
local function dmfCooldownRemaining(rec, e)
    local D = Dash()
    if D and D.DMFCooldownRemaining then
        return D.DMFCooldownRemaining(rec, e) or 0
    end
    if ns.Store and ns.Store.DMFCooldownRemaining then
        return ns.Store.DMFCooldownRemaining(rec, e) or 0
    end
    return 0
end

-- ROUND-22: the DMF cooldown's TRI-STATE, for the COOLDOWNS block. This replaces the old
-- DMFParenthetical that the WORLD BUFFS row used to append; the cooldown now has exactly
-- one home. Follows the SN DMFable model the engine already implements:
--   * DMFable (no active cooldown) ......... "Ready"    ok      — can take a new fortune
--   * stashed in a chronoboon .............. "In Boon"  accent  — FROZEN, not counting down
--   * on cooldown .......................... "<dur>"    warn    — ticks on ONLINE time only
--   * on cooldown, elapsed/unknown ......... "On CD"    warn
-- "In Boon" is checked FIRST because a boon freezes the cooldown: reporting a countdown
-- there would imply time is passing when it is not. It reads `accent` rather than danger —
-- per §5a a held/stashed buff is a calm, owned state, not a warning. And the cooldown reads
-- `warn` rather than `danger`: waiting for the faire is a "not yet", not a failure.
-- Store.DMFCooldownRemaining owns the offline-freeze maths (it returns ONLINE seconds
-- remaining, 0 when ready), so this stays a pure presentation mapping.
-- Remote characters take the identical three labels — the engine hands us the same fields.
function Detail.DMFCooldownState(rec, e, cellW)
    rec = rec or {}
    -- ROUND-23 (owner): a boon-stashed DMF reads GREEN, not accent. It is a HELD, owned
    -- state — the buff is safely banked — so it belongs with "Ready" in the ok family
    -- rather than looking like a warning.
    if rec.dmfInBoon then return "In Boon", "ok" end
    if not rec.dmfCooldownActive then return "Ready", "ok" end
    local rem = dmfCooldownRemaining(rec, e)
    if rem > 0 then return Detail.CdDurationText(rem, cellW), "warn" end
    return "On CD", "warn"
end

-- ROUND-23: compose the raid-tally line. Pure, so the colour-escape correctness is
-- headless-testable rather than only visible in-game (which is how the "|r" bug shipped).
-- Round-17 ink: green available / red locked / grey not-attuned. Round-22 divider: weekly
-- raids | short-cycle raids, as a glyph rather than a texture so the tally stays ONE
-- FontString (a texture needs its own frame + anchors, and round-21b's crash was an anchor
-- cycle) and inherits the line's font scaling.
function Detail.TallyText(list)
    local Dd = Dash()
    local parts = {}
    for i, r in ipairs(list or {}) do
        parts[#parts + 1] = Dd.Colored(r.key, r.token)
        if i == TALLY_SPLIT then parts[#parts + 1] = Dd.Colored(TALLY_DIVIDER, "faint") end
    end
    return table.concat(parts, "  ")
end

-- ROUND-25b (owner): the COOLDOWNS values go back to the SPACED form ("12h 30m") now that
-- round-25's 60/40 split widened the cells to ~89px. Round-23 had forced the compact form
-- purely as a width workaround at 67px cells — with the constraint gone the workaround
-- goes too. Compact is retained as an AUTOMATIC FALLBACK, chosen BY MEASUREMENT rather
-- than by a hardcoded rule: if the spaced string would not fit the cell at the given font
-- scale, the compact form is used instead. Pure, so both branches are asserted.
--   `cellW` is the value cell's px width; `emPx` the numeral font's average advance.
local CD_VALUE_EM = 13 * 0.52          -- numeral 13pt, ~0.52em average advance
function Detail.CdDurationText(secs, cellW, scale)
    local D = Dash()
    local spaced = (D and D.FormatDuration and D.FormatDuration(secs)) or tostring(secs)
    if not cellW then return spaced end
    local w = #spaced * CD_VALUE_EM * (scale or 1)
    if w <= cellW then return spaced end
    return Detail.CompactDuration(secs)
end

-- ROUND-23 (owner): the detail header's sub-line — "Level 60 · Rogue · Account 1".
-- Separator is the suite's MIDDOT, spaced exactly like the statusFS beside it in the same
-- header band ("ONLINE  ·  2m ago"), so the two halves of the band read as one rhythm.
-- "Account N" replaces the old "#N" shorthand. The account segment is OMITTED entirely
-- when the id is absent or non-numeric — dropping the segment (rather than emitting an
-- empty one) is what keeps the separators from doubling up into a trailing " · ".
-- Pure, so the copy is headless-tested.
local SUBLINE_SEP = "  \194\183  "
function Detail.HeaderSubline(rec, aid)
    rec = rec or {}
    local bits = { "Level " .. tostring(rec.level or 60),
                   rec.className or rec.classTag or "?" }
    local n = tonumber(aid)
    if n then bits[#bits + 1] = "Account " .. n end
    return table.concat(bits, SUBLINE_SEP)
end

-- Compact tile-caption duration ("1h59", "59m", "45s", "2d3h") — fits a 20px tile
-- caption on ONE line. The full "1h 59m" form stays on the hover tooltip.
function Detail.CompactDuration(secs)
    secs = math.floor(tonumber(secs) or 0)
    if secs <= 0 then return "0" end
    local d = math.floor(secs / 86400)
    local h = math.floor((secs % 86400) / 3600)
    local m = math.floor((secs % 3600) / 60)
    local s = secs % 60
    if d > 0 then return ("%dd%dh"):format(d, h) end
    if h > 0 then return ("%dh%02d"):format(h, m) end
    if m > 0 then return ("%dm"):format(m) end
    return ("%ds"):format(s)
end

-- Display state for one buff slot. Returns a table:
--   { shown, slot, missing, boon, calm, tint, durText, durTok, fullText, spellID }
-- shown=false -> hide the tile (ignored class-rule / collapsing tail slot, absent).
-- §5a: owned = full-color icon (lit); missing = desaturated icon + danger/warn edge.
--
-- `online` / `aid` come from the ROSTER ENTRY the card was built from (Detail:Show
-- passes both through). They matter: A6.8 decay is keyed on online, and the
-- online answer for a duplicate Name-Realm is only decidable with the aid that
-- says WHICH account's copy this is. Without them AuraRemaining fell back to
-- Dashboard.IsOnline(rec, rec.nameRealm) with no aid, which for a Name-Realm
-- spanning two account buckets drops to bare lastSeen recency — so the card
-- (which had the aid) could show a decaying buff while the detail pane beside
-- it showed the same buff frozen. One entry, one online answer, both surfaces.
function Detail.BuffTileState(slot, rec, faction, e, online, aid)
    local D = Dash()
    local meta = D and D.AURA_META and D.AURA_META[slot]
    if not meta then return { shown = false } end
    -- Caller did not stamp online (headless tests, a bare-string Show): resolve it
    -- ONCE here, with the aid, instead of letting each AuraRemaining call re-guess.
    if online == nil and rec and D and D.IsOnline then
        online = D.IsOnline(rec, rec.nameRealm, aid)
    end
    -- A6.8: the displayed remaining, not the raw stored number — decayed for an
    -- ONLINE character, frozen for an offline one, and ALWAYS frozen for a booned
    -- slot (A7.6). Everything below reads `remaining`, so the tile caption, the
    -- threshold colour and the "Missing" verdict can never disagree about how
    -- much time is actually left.
    local remaining, st = D.AuraRemaining(rec, slot, e, online)
    local present = remaining > 0
    local applicable, requirement = D.AuraRequirement(slot, rec, faction)
    local isDMF = meta.key == "dmf"

    if not (present or applicable or isDMF) then
        return { shown = false, slot = slot, spellID = meta.spellID }
    end

    if present then
        local BOON = (ns.Store and ns.Store.AURA_SOURCE and ns.Store.AURA_SOURCE.BOON) or 2
        local booned = (st.source == BOON or st.source == "boon")
        local full = D.FormatDuration(remaining)
        if booned then
            -- Booned tile: FROZEN duration in GREEN (the ok color carries "boon");
            -- "(Boon)" surfaces once in the eyebrow + the tile hover tooltip.
            return { shown = true, slot = slot, missing = false, boon = true,
                     calm = true, tint = "ok",
                     durText = Detail.CompactDuration(remaining), durTok = "ok",
                     fullText = full .. " (Boon)", spellID = meta.spellID }
        end
        -- SETTINGS-REWORK ITEM 4: buff-time colour is a FIXED backend rule keyed
        -- off the buff's full duration (2h -> yellow under 90m, 1h -> under 55m,
        -- Battle Shout -> under 12m; green otherwise, never red for a buff that
        -- is present). BuffTimeToken returns nil for a slot with no
        -- full-duration class — only the seasonal tail slot today — and that one
        -- keeps the legacy green/amber/red threshold path.
        local tok = D.BuffTimeToken and D.BuffTimeToken(meta.thresholdKey, remaining)
        if not tok then
            tok = D.AuraColorToken(remaining, D.GetThreshold(faction, meta.thresholdKey))
        end
        return { shown = true, slot = slot, missing = false, boon = false,
                 calm = (tok == "ok"), tint = tok,
                 durText = Detail.CompactDuration(remaining), durTok = tok,
                 fullText = full, spellID = meta.spellID }
    end

    -- ROUND-22 (owner): an absent DMF still RENDERS — the display-order contract keeps the
    -- row visible even when the buff is missing — but it now reads like every other missing
    -- row ("Missing", required/optional coloured). The READY / on-CD nuance moved to the
    -- COOLDOWNS block, so the cooldown is stated in exactly one place instead of two.
    if isDMF then
        local tok = (requirement == "optional") and "warn" or "danger"
        return { shown = true, slot = slot, missing = true, boon = false, calm = false,
                 tint = tok, durText = nil, durTok = tok, fullText = nil, spellID = meta.spellID }
    end

    -- Missing but applicable: required = danger, optional = warn.
    local tok = (requirement == "optional") and "warn" or "danger"
    return { shown = true, slot = slot, missing = true, boon = false, calm = false,
             tint = tok, durText = nil, durTok = tok, fullText = nil, spellID = meta.spellID }
end

-- Round-17 PURE geometry. GridTop is the y-offset (negative, from the pane top) where the
-- two-column grid — and therefore each column's eyebrow label — begins: below the header
-- band, below the hairline, plus GRID_GAP of clear air.
function Detail.GridTop()
    return -(PAD_V + HEADER_H + HRULE_GAP + GRID_GAP)
end

-- ROUND-18 item 3: how far BELOW the detail panel's top edge the header hairline sits.
-- The cards panel puts the first card's top at CHIP_H + LIST_PAD below ITS panel top, and
-- both panels share the body top rail — so these two numbers must be equal for the owner's
-- alignment to hold. Pure, and asserted both here and cross-panel in LAYOUT_SPEC.
function Detail.HeaderRuleOffset()
    return PAD_V + HEADER_H + HRULE_GAP
end

-- PURE fit check for the left column's 10-row buff list inside a `paneH`-tall pane. The
-- pane is tight, so this is what proves the round-17 padding is actually affordable:
--   listTop    = |GridTop| + BUFF_TOP                  (rows start below the eyebrow)
--   listH      = n*BUFF_ROW_H + (n-1)*BUFF_ROW_GAP     (no trailing gap)
--   limit      = paneH - PAD_V                         (bottom padding)
-- Returns the measurements + `fits` and the leftover slack.
-- ROUND-19: the limit now also reserves the bottom-left RAID LOCKOUTS line, so `fits`
-- means "the 10-row list AND the lockout line both clear the bottom pad".
function Detail.BuffListFit(paneH, rows)
    paneH = paneH or 320          -- detail.pane height (LAYOUT_SPEC, round-20)
    rows  = rows or 10            -- all 10 aura slots applicable = the worst case
    local listTop = -Detail.GridTop() + BUFF_TOP
    local listH   = rows * BUFF_ROW_H + (rows - 1) * BUFF_ROW_GAP
    local limit   = paneH - PAD_V - (LOCK_BLOCK + LOCK_GAP)  -- stacked lockout block reserved
    return {
        listTop = listTop, listH = listH, limit = limit,
        lockH   = LOCK_BLOCK + LOCK_GAP,
        bottom  = listTop + listH,
        slack   = limit - (listTop + listH),
        fits    = (listTop + listH) <= limit,
    }
end

-- Round-17 addendum (owner): the raid tally's THREE-STATE ink.
--   LOCKED (expiry > now) ....... danger  (red — you are saved)
--   OPEN + attuned .............. ok      (green — you can go)
--   OPEN + NOT attuned .......... faint   (grey — not attuned yet)
-- `attuned` comes from the sibling's ns.Store.RaidAttuned(rec, key) -> true/false/nil.
-- CONTRACT: nil means UNKNOWN and is treated as ATTUNED, so remote characters with no
-- attunement data render exactly as they do today and are never spuriously greyed; only an
-- explicit `false` greys a raid. LOCKED wins over attunement — a live lockout is the more
-- actionable fact, and it is how the owner's rule is ordered. Pure.
function Detail.TallyToken(isLocked, attuned)
    if isLocked then return "danger" end
    if attuned == false then return "faint" end
    return "ok"
end

-- Raid tally rows + counts. locked when expiry > now.
--   -> list { {key, full, locked, remaining} }, lockedN, openN
function Detail.RaidTally(rec, e)
    local D = Dash()
    e = e or nowE()
    local out, locked, open = {}, 0, 0
    for _, key in ipairs(TALLY_ORDER) do
        local expiry = rec.raidLockouts and rec.raidLockouts[key]
        local isLocked = expiry and expiry > e or false
        if isLocked then locked = locked + 1 else open = open + 1 end
        -- Attunement (round-17 addendum) comes from the sibling-owned Store API. Guarded so
        -- this round merges before that API lands: absent API -> nil -> treated as attuned.
        local S = ns.Store
        local attuned
        if S and S.RaidAttuned then attuned = S.RaidAttuned(rec, key) end
        out[#out + 1] = {
            key = key,
            full = (D and D.RAID_FULLNAME and D.RAID_FULLNAME[key]) or key,
            locked = isLocked,
            attuned = attuned,
            token = Detail.TallyToken(isLocked, attuned),
            remaining = isLocked and (expiry - e) or 0,
        }
    end
    return out, locked, open
end

-- Row-list STATUS text + token from a BuffTileState result (pure/testable). The
-- status column carries the STATE color; the name column carries buff identity.
--   missing (non-DMF) -> "Missing", danger (required) / warn (optional)
--   missing DMF        -> its re-acquire state ("READY"/"on CD"/dur) + token
--   present            -> the duration text (FormatDuration, or "..(Boon)" green)
-- The DMF row's PRESENT-case parenthetical is appended by the renderer (it embeds an
-- inline color escape, which would make the pure return string awkward to assert).
-- ROUND-22: `isDMF` is retained for call-site compatibility but is NO LONGER USED — a
-- missing DMF now reads "Missing" like every other row, because its re-acquire state moved
-- to the COOLDOWNS block. Keeping the parameter avoids churning the two call sites and
-- their tests for a signature change that carries no behaviour.
function Detail.RowStatus(s, isDMF)   -- luacheck: ignore isDMF
    if not s or not s.shown then return "", "faint" end
    if s.missing then
        return "Missing", (s.tint or "danger")
    end
    return (s.fullText or s.durText or ""), (s.boon and "ok" or (s.durTok or "ok"))
end

-- Resolve a character record by nameRealm across all account buckets.
--
-- Delegates to the SAME winner pick the roster uses (ui_shell's
-- ResolveRosterOwner). It used to return the first `pairs()` hit, which is a
-- lottery the moment one Name-Realm sits under two account buckets — the state
-- an account re-set-up under a new AID leaves behind. Clicking the (single,
-- deduped) card could then open a two-week-old copy of the character while the
-- card beside it showed the live one. One winner, both surfaces.
--
-- BRIEF E (NX-14). The fallback below — reached on a host where ns.Dashboard has
-- not loaded, since this file is reachable from the headless suites before the
-- shell is — was ITSELF the first-`pairs()`-hit lottery this function exists to
-- have retired. It now asks the same store-level rule the shell asks
-- (Store.ResolveOwner), so the two branches of this function can no longer
-- disagree with each other, let alone with the roster.
function Detail.Resolve(nameRealm)
    local D = ns.Dashboard
    if D and D.ResolveRosterOwner then
        local rec, aid = D.ResolveRosterOwner(nameRealm)
        if rec then return rec, aid end
        return nil
    end
    local Store = ns.Store
    if not (Store and Store.ResolveOwner and Store.GetData) then return nil end
    return Store.ResolveOwner(Store.GetData(), nameRealm)
end

-- Resolve an item's inventory-icon texture through the shared ns.Dashboard.ItemIcon
-- path. ROUND-5 HOTFIX: the COOLDOWNS icon paint used a BARE `Dashboard` global, which
-- is nil in this file (the convention is ns.Dashboard / Dash()); it parsed clean but
-- crashed at first render. This wrapper is ns-guarded and returns a question-mark
-- fallback if the engine is somehow absent, so the icon paint can never crash. Exposed
-- so the headless suite can exercise the path (a bare global would fail the assertion).
local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
function Detail.ItemIconTex(itemID)
    local D = ns.Dashboard
    if D and D.ItemIcon then return D.ItemIcon(itemID) or QUESTION_ICON end
    return QUESTION_ICON
end

-- ── NOTE COMMIT (round-29) ──────────────────────────────────────────────────
-- The ONE place the note box's text reaches the store. Both commit routes (Escape and
-- focus-loss) call it, so there is a single answer to "what does saving a note mean" and
-- a seam the headless suite can drive without an EditBox.
--
-- Store shape is UNCHANGED: this is exactly the Store.SetNote call the round-19 handler
-- made, including the empty-string-means-erase rule that Store.GetNote already mirrors on
-- read. Returns the value written (nil when erased) so a caller can assert it.
function Detail.CommitNote(nameRealm, text)
    if type(nameRealm) ~= "string" or nameRealm == "" then return nil end
    local t = (type(text) == "string" and text ~= "") and text or nil
    if ns.Store and ns.Store.SetNote then ns.Store.SetNote(nameRealm, t) end
    return t
end

-- Escape on the note box: COMMIT, then blur. Exported (rather than living inline in the
-- handler) purely so the ordering can be pinned by a test — reverting-then-blurring is
-- the exact round-28 bug this replaces, and it is invisible to any test that only checks
-- the save function. `box` needs GetText / ClearFocus and nothing else.
function Detail.NoteEscape(box, nameRealm)
    local saved = Detail.CommitNote(nameRealm, box and box.GetText and box:GetText())
    if box and box.ClearFocus then box:ClearFocus() end
    return saved
end

-- ════════════════════════════════════════════════════════════════════════════
--  FRAME BUILD + INSTANT SWAP  (in-game only; UI is non-nil there)
-- ════════════════════════════════════════════════════════════════════════════

local function tag(frame, id)
    if ns.Audit and ns.Audit.Tag and frame then ns.Audit.Tag(frame, id) end
    return frame
end

local function fstr(parent, fontKey, justify)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(ns.Dashboard.Font(fontKey))   -- round-11 item 2: ARIALN dashboard type
    if justify then f:SetJustifyH(justify) end
    return f
end

-- microLabel eyebrow (ARIALN, uppercase). Pop pass (round-4): section labels read at
-- `muted` (a tier up from faint) so headers carry.
local function microLabel(parent, text)
    local l = fstr(parent, "microLabel")
    l:SetTextColor(UI.Color("muted"))
    if text then l:SetText(text) end
    return l
end

-- Lift an r,g,b color a fraction `t` toward white (pure; returns THREE numbers).
-- Shared by the class-name and buff-name pop-pass tints; unit-tested headless.
function Detail.Lighten(r, g, b, t)
    return r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t
end

-- Brightened class color for the detail header name (pop pass) — class identity hue
-- lifted ~12% toward white. Returns r,g,b (falls back to cream if no class color).
-- NOTE (round-4 hotfix): the class-color read MUST be a plain guarded statement, not a
-- `local r,g,b = A and B and Call()` — an and-chain truncates the multi-return to ONE
-- value, so g/b came back nil and the arithmetic below crashed (BugSack ui_detail:252).
function Detail.BrightClass(classTag)
    local r, g, b
    if ns.Dashboard and ns.Dashboard.ClassColor then
        r, g, b = ns.Dashboard.ClassColor(classTag)
    end
    if not (r and g and b) then return UI.Color("text") end
    return Detail.Lighten(r, g, b, 0.12)
end
local brightClass = Detail.BrightClass

-- Resolve a buff name's tint: its family hue LIFTED a tier brighter (pop pass), unless
-- that hue's contrast against the active theme's ground is too weak (light themes), in
-- which case fall back to the cream "text" token. Returns r,g,b (0..1) for SetTextColor.
local function relLum(r, g, b) return 0.2126 * r + 0.7152 * g + 0.0722 * b end
local function nameColor(slot)
    local D = ns.Dashboard
    local meta = D and D.AURA_META and D.AURA_META[slot]
    local hue = meta and BUFF_HUE[meta.key]
    if not hue then return UI.Color("text") end
    local hr, hg, hb = Detail.Lighten(hue[1], hue[2], hue[3], 0.14)
    local gr, gg, gb = UI.Color("ground")
    if math.abs(relLum(hr, hg, hb) - relLum(gr, gg, gb)) < 0.20 then
        return UI.Color("text")   -- insufficient contrast on this theme -> cream
    end
    return hr, hg, hb
end

-- A LABELED BUFF ROW: cropped/framed ~16px icon · buff name (family-hue tinted) ·
-- right-aligned status. Full BUFF_ROW_H tall; spans the left column's width.
local function makeBuffRow(parent)
    local row = CreateFrame("Frame", nil, parent)
    row:SetHeight(BUFF_ROW_H)
    -- Framed icon (thin inset border; §5a desat is applied to the icon in Show).
    local tile = CreateFrame("Frame", nil, row, "BackdropTemplate")
    tile:SetSize(BUFF_ICON, BUFF_ICON)
    tile:SetPoint("LEFT", row, "LEFT", 0, 0)
    local ic = tile:CreateTexture(nil, "ARTWORK")
    ic:SetPoint("TOPLEFT", tile, "TOPLEFT", 1, -1)
    ic:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -1, 1)
    ic:SetTexCoord(0.06, 0.94, 0.06, 0.94)   -- crop the icon's built-in border
    tile.icon = ic
    row.tile = tile
    -- Right-aligned status (STATE color) — anchored first so the name can bound to it.
    -- ROUND-18 item 1 (owner ORANGE arrow): the status used to right-align at the LEFT
    -- COLUMN'S far edge (~486px out), leaving a huge gulf between a ~150px buff name and
    -- its status. It now LEFT-anchors at a fixed rail just past the longest buff name, so
    -- name -> status reads as one line instead of two eye-stops.
    row.status = fstr(row, "body", "LEFT")
    row.status:SetPoint("LEFT", row, "LEFT", STATUS_X, 0)
    -- Buff name (family-hue tinted), between the icon and the status column.
    row.name = fstr(row, "body"); row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false)
    row.name:SetPoint("LEFT", tile, "RIGHT", 8, 0)
    -- Name is capped just short of the status rail (it already has SetWordWrap(false), so
    -- an over-long name ellipsizes instead of colliding with the status).
    row.name:SetPoint("RIGHT", row, "LEFT", STATUS_X - 8, 0)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self)
        if not self._tipName then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self._tipName, UI.Color("text"))
        if self._tipFull then GameTooltip:AddLine(self._tipFull, UI.Color("muted")) end
        GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return row
end

-- Build the detail pane into `parent` (the tagged detail.pane host from ui_cards).
-- Returns a controller with :Show(entry) and .frame. Content is rebuilt in place
-- on every :Show — instant swap, no animation, no scroll.
function Detail.Attach(parent)
    local D = {}
    D.frame = parent

    -- ── Header band ─────────────────────────────────────────────────────────
    local header = CreateFrame("Frame", nil, parent)
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD_H, -PAD_V)
    header:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD_H, -PAD_V)
    header:SetHeight(HEADER_H)
    tag(header, "detail.header")
    D.header = header

    local nameFS = fstr(header, "header"); nameFS:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 2)
    -- ROUND-18 item 3 (owner): the character name is this pane's anchor and should read
    -- clearly bigger than a card name. +4 on the `header` base, tracking the font picker
    -- via SizedFont. No OUTLINE: the wordmark (MORPHEUS ceremonial) stays the loudest mark
    -- in the window, and an outlined 19px name would out-shout it.
    if Dash() and Dash().SizedFont then Dash().SizedFont(nameFS, "header", 4) end
    nameFS:SetWordWrap(false)
    local subFS = fstr(header, "small"); subFS:SetPoint("LEFT", nameFS, "RIGHT", 10, 0)
    subFS:SetWordWrap(false)   -- round-23: right bound set below, once statusDot exists
    subFS:SetTextColor(UI.Color("muted"))
    -- Status cluster (right): dot + Online/Offline · freshness.
    local statusFS = fstr(header, "microLabel", "RIGHT")
    statusFS:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 3)
    -- Status pip: a DIAMOND with pop (round-8 item 2), matching the card pips.
    local statusDot, statusHalo = Dash().MakeStatusPip(header, 9)
    statusDot:SetPoint("RIGHT", statusFS, "LEFT", -8, 0)
    -- ROUND-23: bound the sub-line against the status pip now that it exists. The full
    -- Name-Realm can be long (a 12-char name on "Bloodsail Buccaneers" is 33 chars) and at
    -- 1.3x font scale name + sub-line + status overruns the 714px band — measured, it does.
    -- The SUB-LINE yields and ellipsizes; the NAME never does, because it is the owner's
    -- explicit ask and the pane's identity anchor, and level/class/account are all
    -- recoverable elsewhere. Deliberately ONE-WAY: subFS already anchors LEFT to nameFS, so
    -- bounding the name against the sub-line would recreate exactly the sfHdr<->sfMeta
    -- anchor cycle that crashed round-21. The anchor gate covers this.
    subFS:SetPoint("RIGHT", statusDot, "LEFT", -10, 0)
    D.nameFS, D.subFS, D.statusFS, D.statusDot, D.statusHalo = nameFS, subFS, statusFS, statusDot, statusHalo

    -- Header bottom hairline (one sharp rule, §9 UI.Hairline). Pop pass: borderLite.
    -- NW-6: UI.Hairline arrived with the Core 2.2.0 ledger kit. Fetched through
    -- the guard so an older Core loses this rule and says so once, rather than
    -- erroring out of the whole detail build.
    -- Declared in the enclosing scope: D:Show() below toggles it with the header.
    local hrule
    local Hairline = ns:CoreAPI(ns.CORE_KIT_VERSION, "the Nexus detail pane", UI and UI.Hairline)
    if Hairline then
        hrule = Hairline(parent, { token = "borderLite" })
        tag(hrule, "detail.hrule")   -- round-18: pinned to the cards list top by LAYOUT_SPEC
        hrule:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -HRULE_GAP)
        hrule:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -HRULE_GAP)
    end

    -- ── Two-column grid below the header ────────────────────────────────────
    -- Round-17: start the grid BELOW the hairline (+GRID_GAP), not at the header's bottom
    -- edge — the rule used to cut through the eyebrow labels. See Detail.GridTop.
    local gridTop = Detail.GridTop()
    -- Left column (1fr): buff grid.
    local leftCol = CreateFrame("Frame", nil, parent)
    leftCol:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD_H, gridTop)
    -- ROUND-25: C1 is what remains after C2 + the gap, which by construction IS the 60%
    -- side of the split (714 - 14 - 280 = 420 = COL_L_W). Anchoring rather than SetWidth
    -- keeps the two columns provably complementary — they cannot drift apart.
    leftCol:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -(PAD_H + COL_R_W + COL_GAP), PAD_V)
    D.leftCol = leftCol
    -- FLAG, don't fail: if C1 ever stops holding its widest content, say so in chat rather
    -- than letting the status column silently overlap. Checked at the 1.3x font ceiling.
    local fit = Detail.ColumnFits(COL_L_W, 1.3)
    if not fit.fits and ns and ns.Print then
        ns:Print(("detail C1 is %dpx short at max font scale (%s needs %d, has %d)")
            :format(fit.short, fit.worst, fit.need, fit.have))
    end

    local buffLbl = microLabel(leftCol, "WORLD BUFFS")
    buffLbl:SetPoint("TOPLEFT", leftCol, "TOPLEFT", 0, 0)
    D.buffLbl = buffLbl

    -- Buff ROW-LIST container (tagged for the geometry checker) below the eyebrow.
    local buffRows = CreateFrame("Frame", nil, leftCol)
    buffRows:SetPoint("TOPLEFT", leftCol, "TOPLEFT", 0, -BUFF_TOP)
    -- Round-19: the list now stops above the bottom-left RAID LOCKOUTS line (offset by
    -- creation-order-independent arithmetic rather than anchoring to a later-built frame).
    buffRows:SetPoint("BOTTOMRIGHT", leftCol, "BOTTOMRIGHT", 0, LOCK_BLOCK + LOCK_GAP)
    tag(buffRows, "detail.buffrows")
    D.buffRows = buffRows

    D._rows = {}
    for i = 1, 10 do D._rows[i] = makeBuffRow(buffRows) end
    -- Stable ids for the row-list geometry assertions (height/pitch, icon size,
    -- shared left rail, right-aligned status column).
    tag(D._rows[1], "detail.buffrow1"); tag(D._rows[2], "detail.buffrow2")
    tag(D._rows[1].tile, "detail.bufficon1")
    tag(D._rows[1].status, "detail.buffstatus1"); tag(D._rows[2].status, "detail.buffstatus2")

    -- Right column (fixed 214): tally · cooldowns · note · actions.
    local rightCol = CreateFrame("Frame", nil, parent)
    rightCol:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD_H, gridTop)
    rightCol:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -PAD_H, PAD_V)
    rightCol:SetWidth(COL_R_W)
    D.rightCol = rightCol

    -- ROUND-22 (owner): NOTE and COOLDOWNS SWAP — NOTE now sits at the TOP of the right
    -- column under the header, COOLDOWNS at the BOTTOM. The cooldown icons also stop being
    -- a vertical stack: they lay out as a 2-COLUMN GRID so chrono and hearth sit next to
    -- each other, with the new DMF cooldown on the second row.
    --   column 214 - CD_GAP 10 = 204 / 2 = 102 per cell (icon 16 + 6 + ~80 of value)
    -- 2x2 rather than 3-across because 3 cells would be 71 wide, leaving only ~49 for the
    -- value — "12h 30m" already runs ~42 at the default scale and overflows at 1.3x. The
    -- column has ~120px of vertical slack after the swap, so spending one row is free.
    -- ROUND-23 (owner override): all THREE cooldowns share ONE row — chrono, hearth, DMF.
    --   cell = (COL_R_W 280 - 2 x CD_GAP 6) / 3 = 89   (icon 16 + 4 gap + ~69 of value)
    -- ROUND-25 note: the 60/40 split widened C2 from 214 to 280, so these cells grew 67 ->
    -- 89. That RELIEVES the round-23 squeeze that forced the compact duration form — ~69px
    -- now holds the spaced "12h 30m" (~42 at scale 1.0, ~55 at 1.3x). Left on the compact
    -- form regardless, because the owner did not ask to change it this round; flagged in
    -- the report so it is a decision rather than an oversight.
    -- TRADEOFF, stated plainly: 47px cannot hold the spaced "12h 30m" (~42 at scale 1.0,
    -- ~55 at 1.3x), so the three values switch to the COMPACT duration form ("12h30",
    -- "59m", "2d3h") that the pane already defines. No precision is lost — the compact form
    -- keeps the same two units, it only drops the space — and each icon's hover tooltip
    -- still carries the fully spelled-out state.
    local CD_ICON, CD_GAP, CD_ROW_H = 16, 6, 21
    local CD_CELL_W = (COL_R_W - 2 * CD_GAP) / 3
    -- round-25b: the value cell inside each pair — what the duration formatter measures against
    local CD_VALUE_W = CD_CELL_W - CD_ICON - 6

    local cdGrid = CreateFrame("Frame", nil, rightCol)
    cdGrid:SetPoint("BOTTOMLEFT", rightCol, "BOTTOMLEFT", 0, 0)
    cdGrid:SetPoint("RIGHT", rightCol, "RIGHT", 0, 0)
    cdGrid:SetHeight(CD_ICON)                     -- round-23: ONE row of three
    local cdLbl = microLabel(rightCol, "COOLDOWNS")
    cdLbl:SetPoint("BOTTOMLEFT", cdGrid, "TOPLEFT", 0, 6)
    tag(cdLbl, "detail.cdlabel")

    -- One icon+value pair at grid cell (col, row). `icon` is an item ID (number) or a
    -- ready-made texture path (string) so the DMF pair can use the aura icon.
    local function cdIconRow(icon, fullName, col, row)
        local f = CreateFrame("Frame", nil, cdGrid, "BackdropTemplate")
        f:SetSize(CD_ICON, CD_ICON)
        f:SetPoint("TOPLEFT", cdGrid, "TOPLEFT", col * (CD_CELL_W + CD_GAP), -row * CD_ROW_H)
        UI.Skin(f, function(self)
            self:SetBackdrop(UI.FLAT_BACKDROP)
            self:SetBackdropColor(UI.Color("inset"))
            self:SetBackdropBorderColor(UI.Color("borderLite"))
        end)
        local ic = f:CreateTexture(nil, "ARTWORK")
        ic:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        ic:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ic:SetTexture(type(icon) == "string" and icon or Detail.ItemIconTex(icon))
        f.icon = ic
        f._name = fullName
        f:EnableMouse(true)
        f:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self._name, UI.Color("text"))
            if self._state then GameTooltip:AddLine(self._state, UI.Color(self._stateTok or "muted")) end
            GameTooltip:Show()
        end)
        f:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- Colored state value, filling the rest of this grid cell, centred on the icon.
        local vf = fstr(cdGrid, "numeral", "LEFT")
        vf:SetPoint("LEFT", f, "RIGHT", 6, 0)
        vf:SetWidth(CD_VALUE_W); vf:SetWordWrap(false)
        return f, vf
    end
    -- Row 0: chrono | hearth side by side (owner). Row 1: the new DMF cooldown.
    local chronoIcon, chronoVal = cdIconRow(184937, "Chronoboon Displacer", 0, 0)
    local hearthIcon, hearthVal = cdIconRow(6948, "Hearthstone", 1, 0)
    -- ROUND-22: the DMF cooldown joins COOLDOWNS, using the AURA icon (Sayge's Dark
    -- Fortune, slot 5) rather than an item icon — there is no item, the cooldown is on the
    -- faire buff itself. This is also why the WORLD BUFFS row drops its CD parentheticals:
    -- the cooldown now has one home instead of being spelled out in two places.
    local dmfIcon, dmfVal = cdIconRow(Dash().AuraIcon(5), "Darkmoon Faire cooldown", 2, 0)
    tag(chronoIcon, "detail.cdicon1")   -- 16px item-icon square (geometry assertion)
    tag(hearthIcon, "detail.cdicon2")   -- round-22: shares row 0 with chrono (side by side)
    tag(dmfIcon, "detail.cdicon3")
    D.dmfSlot = 5   -- round-23: re-resolved every Refresh (see the icon-cache note below)
    D.chronoVal, D.hearthVal, D.dmfVal = chronoVal, hearthVal, dmfVal
    D.chronoIcon, D.hearthIcon, D.dmfIcon = chronoIcon, hearthIcon, dmfIcon

    -- ROUND-19 (owner, deferred from round-18): RAID LOCKOUTS moves OUT of the right
    -- column's top rail and into the detail pane's BOTTOM-LEFT, under the buff list. It is
    -- now ONE line — the eyebrow on the left, the 7-key tally beside it — so it costs
    -- LOCK_H + LOCK_GAP (19px) instead of the ~34px a stacked label+tally block would.
    -- The three-state ink (round-17: locked danger / attuned ok / not-attuned faint) and
    -- TALLY_ORDER are unchanged; only the home moved. This is what freed the right column
    -- for the NOTE box to grow.
    -- ROUND-20: STACKED — the keys sit on the column's bottom line and the eyebrow rides
    -- directly above them ("the header should be above the raids").
    local tallyFS = fstr(leftCol, "numeral")
    tallyFS:SetPoint("BOTTOMLEFT", leftCol, "BOTTOMLEFT", 0, 0)
    tallyFS:SetPoint("RIGHT", leftCol, "RIGHT", 0, 0)
    tallyFS:SetJustifyH("LEFT"); tallyFS:SetWordWrap(false)
    D.tallyFS = tallyFS
    local raidLbl = microLabel(leftCol, "RAID LOCKOUTS")
    raidLbl:SetPoint("BOTTOMLEFT", tallyFS, "TOPLEFT", 0, LOCK_LBL_GAP)
    tag(raidLbl, "detail.raidlabel")

    -- NOTE block — ROUND-22 (owner): swapped with COOLDOWNS, so NOTE now sits at the TOP of
    -- the right column, directly under the pane header, and COOLDOWNS took the bottom.
    -- (It had been pinned to the pane bottom since round-4.) The label rides above the box,
    -- so the block starts with the label on the column's top rail.
    local noteBox = CreateFrame("EditBox", nil, rightCol, "BackdropTemplate")
    noteBox:SetPoint("TOPLEFT", rightCol, "TOPLEFT", 0, -(LOCK_LBL_H + 4))
    noteBox:SetPoint("RIGHT", rightCol, "RIGHT", 0, 0)
    -- ROUND-19 priority 3: RAID LOCKOUTS vacated the right column, so NOTE claimed the
    -- space and became MULTI-LINE. (Round-28: Enter now inserts a newline rather than
    -- committing — see the handler block below for the full commit semantics.)
    -- ROUND-23 (owner's green outline): NOTE fills the right column's whole upper area
    -- instead of a fixed 66px box — from under its label down to just above the COOLDOWNS
    -- block, full column width. Anchored TOP (label) and BOTTOM (the cooldown label) rather
    -- than given a height, so it FLEXES: if the cooldown block or the pane height ever
    -- changes, the note absorbs the difference instead of needing a new magic number.
    -- One-way anchors only (noteBox -> rightCol/cdLbl); cdLbl hangs off cdGrid, which hangs
    -- off rightCol, so the graph stays acyclic — the anchor gate covers it.
    noteBox:SetPoint("BOTTOM", cdLbl, "TOP", 0, 8)
    noteBox:SetAutoFocus(false)
    noteBox:SetMultiLine(true)
    local noteLbl = microLabel(rightCol, "NOTE")
    noteLbl:SetPoint("TOPLEFT", rightCol, "TOPLEFT", 0, 0)   -- round-22: column top rail
    tag(noteLbl, "detail.notelabel")
    noteBox:SetFontObject(UI.fonts.body); noteBox:SetTextInsets(7, 7, 0, 0)
    UI.Skin(noteBox, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("controlBorder"))
    end)
    local function noteGet(nr) if ns.Store and ns.Store.GetNote then return ns.Store.GetNote(nr) end end
    -- ROUND-28 addendum (owner): Enter inserts a NEWLINE. The OnEnterPressed override that
    -- committed-and-blurred is REMOVED, not replaced — a multi-line EditBox handles Enter
    -- natively once nothing intercepts it, so removing the handler IS the feature.
    -- Commit semantics after this:
    --   Enter        -> newline (no save, no blur)
    --   focus lost   -> SAVES
    --   Escape       -> SAVES, then blurs        (ROUND-29 — see below)
    --
    -- ROUND-29 (owner: "Escape loses the typed text"). The round-28 Escape handler read
    --     self:SetText(noteGet(D._current)) ; self:ClearFocus()
    -- i.e. it REVERTED the box to the stored note and only then dropped focus — so the
    -- OnEditFocusLost save that fired a moment later saved the reverted text back over
    -- itself. Everything typed since the box gained focus was destroyed by the save path
    -- that was supposed to protect it. Escape now COMMITS and then blurs, and both routes
    -- (Escape, clicking away) go through the one Detail.CommitNote seam.
    noteBox:SetScript("OnEscapePressed", function(self) Detail.NoteEscape(self, D._current) end)
    noteBox:SetScript("OnEditFocusLost", function(self)
        Detail.CommitNote(D._current, self:GetText())
    end)
    D.noteBox = noteBox

    -- Empty-state label (no selection).
    local emptyFS = fstr(parent, "muted"); emptyFS:SetPoint("CENTER", parent, "CENTER", 0, 0)
    emptyFS:SetText("Select a character.")
    D.emptyFS = emptyFS

    -- ── Instant swap ────────────────────────────────────────────────────────
    -- entry = { nameRealm, rec, online, aid, faction } (from ui_cards). A bare
    -- nameRealm string is resolved. nil clears the pane to the empty state.
    function D:Show(entry)
        if type(entry) == "string" then
            local rec, aid = Detail.Resolve(entry)
            -- Pass the resolved aid so same-account online exclusivity can be
            -- applied even when a bare Name-Realm string was handed in (two
            -- accounts may hold the same Name-Realm; the aid disambiguates).
            entry = rec and { nameRealm = entry, rec = rec, aid = aid,
                              online = Dash().IsOnline(rec, entry, aid) } or nil
        end
        if not entry or not entry.rec then
            D._current, D._entry = nil, nil
            emptyFS:Show(); header:Hide(); if hrule then hrule:Hide() end
            leftCol:Hide(); rightCol:Hide()
            return
        end
        emptyFS:Hide(); header:Show(); leftCol:Show(); rightCol:Show()
        if hrule then hrule:Show() end
        -- ROUND-29: OnEditFocusLost reads D._current AT FIRE TIME, so swapping characters
        -- while the note box still holds focus would have saved the half-typed note onto
        -- the character just selected. Commit it to the OUTGOING one and blur first.
        if D.noteBox and D._current and D._current ~= entry.nameRealm
           and D.noteBox.HasFocus and D.noteBox:HasFocus() then
            Detail.NoteEscape(D.noteBox, D._current)
        end
        D._current, D._entry = entry.nameRealm, entry
        local rec = entry.rec
        local Dd = Dash()
        local e = nowE()
        local faction = entry.faction or rec.faction

        -- ROUND-23 (owner): the header shows the FULL "Name-Realm", not the realm-stripped
        -- short name, still in the brightened class hue. The CARDS keep ShortName — a card
        -- is a narrow list row where the realm would crowd out everything else; this pane
        -- is the place with room to name the character in full.
        nameFS:SetText(entry.nameRealm or "?")
        nameFS:SetTextColor(brightClass(rec.classTag))
        subFS:SetText(Detail.HeaderSubline(rec, entry.aid))
        local online = entry.online
        Dd.PaintStatusPip(statusDot, D.statusHalo, online)
        statusFS:SetText((online and "ONLINE" or "OFFLINE") .. "  \194\183  " .. Dd.FreshnessText(rec.lastDataUpdate))
        statusFS:SetTextColor(UI.Color("muted"))

        -- Buff ROW LIST: one row per shown buff — framed icon (§5a lit/desat) ·
        -- family-hue buff name · right-aligned STATE status (the status column carries
        -- the state color; the name carries buff identity). Rows stack at a fixed pitch.
        local order = Dd.AURA_DISPLAY_ORDER or {}
        local shown, held = 0, 0
        local idx = 0
        for _, r in ipairs(D._rows) do r:Hide() end
        for _, slot in ipairs(order) do
            -- Same online/aid the CARD used (entry.online was stamped by the roster
            -- gather; entry.aid names the owning bucket) — see BuffTileState.
            local s = Detail.BuffTileState(slot, rec, faction, e, online, entry.aid)
            if s.shown then
                idx = idx + 1
                shown = shown + 1
                if not s.missing then held = held + 1 end
                local row = D._rows[idx]
                local meta = Dd.AURA_META[slot]
                row:ClearAllPoints()
                row:SetPoint("TOPLEFT", buffRows, "TOPLEFT", 0, -((idx - 1) * (BUFF_ROW_H + BUFF_ROW_GAP)))
                row:SetPoint("RIGHT", buffRows, "RIGHT", 0, 0)
                -- Icon (§5a): held lit; missing desaturated + danger/warn edge.
                row.tile.icon:SetTexture(Dd.AuraIcon(slot))
                row.tile.icon:SetDesaturated(s.missing and true or false)
                row.tile.icon:SetAlpha(s.missing and 0.85 or 1)
                row.tile:SetBackdrop(UI.FLAT_BACKDROP)
                row.tile:SetBackdropColor(UI.Color("inset"))
                row.tile:SetBackdropBorderColor(UI.Color(s.missing and (s.tint or "danger") or (s.boon and "ok" or TILE_RIM)))
                -- Name in its family hue (falls back to cream on low-contrast themes).
                row.name:SetText(meta.name)
                row.name:SetTextColor(nameColor(slot))
                -- Status (state color). The DMF PRESENT case appends its re-acquire paren.
                -- ROUND-22: the DMF row no longer appends its re-acquire parenthetical —
                -- the cooldown lives in the COOLDOWNS block now, so this row reads exactly
                -- like the other nine (duration / "(Boon)" when held, "Missing" when not).
                local statusText, statusTok = Detail.RowStatus(s, meta.key == "dmf")
                row.status:SetText(statusText)
                row.status:SetTextColor(UI.Color(statusTok))
                row._tipName = meta.name
                row._tipFull = s.fullText or (s.missing and "Missing" or nil)
                row:Show()
            end
        end
        buffLbl:SetText(("WORLD BUFFS  \194\183  %d/%d HELD"):format(held, shown))

        -- Raid tally line.
        tallyFS:SetText(Detail.TallyText(Detail.RaidTally(rec, e)))

        -- Telemetry (chrono / hearth item icons + colored state value). The icon desats
        -- while on cooldown (mirrors the card stack); the tooltip carries the state.
        -- A9.1: derived from the stored START EPOCH, via the one shared helper.
        -- ROUND-17b (owner): the chrono row is a pure Displacer-COOLDOWN indicator. Being
        -- booned no longer replaces the readout ("BOON") nor recolours anything — the row
        -- reads Ready / countdown exactly like the hearth row, the icon rim goes green when
        -- the item is off cooldown and red while it is on cooldown (mirroring the card
        -- icons), and the BOON detail moves into the tooltip line.
        local chronoRem = Dd.ItemCdRemaining(rec, "chronoboon", e)
        local chronoOnCd = chronoRem > 0
        if chronoOnCd then
            chronoVal:SetText(Detail.CdDurationText(chronoRem, CD_VALUE_W)); chronoVal:SetTextColor(UI.Color("warn"))
            D.chronoIcon.icon:SetDesaturated(true)
        else
            chronoVal:SetText("Ready"); chronoVal:SetTextColor(UI.Color("ok"))
            D.chronoIcon.icon:SetDesaturated(false)
        end
        D.chronoIcon:SetBackdropBorderColor(UI.Color(chronoOnCd and "danger" or "ok"))
        local cBits = {}
        if rec.chronoboonActive then cBits[#cBits + 1] = "Booned" end
        if chronoOnCd then cBits[#cBits + 1] = "Cooldown " .. Dd.FormatDuration(chronoRem)
        else cBits[#cBits + 1] = ("%d in bags"):format(rec.boonCount or 0) end
        D.chronoIcon._state = table.concat(cBits, " \194\183 ")
        D.chronoIcon._stateTok = chronoOnCd and "warn" or (rec.chronoboonActive and "ok" or "muted")

        local hearthRem = Dd.ItemCdRemaining(rec, "hearthstone", e)
        if hearthRem > 0 then
            hearthVal:SetText(Detail.CdDurationText(hearthRem, CD_VALUE_W)); hearthVal:SetTextColor(UI.Color("warn"))
            D.hearthIcon.icon:SetDesaturated(true)
            D.hearthIcon._state = "Cooldown " .. Dd.FormatDuration(hearthRem); D.hearthIcon._stateTok = "warn"
        else
            hearthVal:SetText("Ready"); hearthVal:SetTextColor(UI.Color("ok"))
            D.hearthIcon.icon:SetDesaturated(false)
            D.hearthIcon._state = "Ready"; D.hearthIcon._stateTok = "ok"
        end
        -- Same green/red cooldown rim as the chrono icon above (and the card icons), so the
        -- two telemetry rows read with one language instead of one rimmed and one static.
        D.hearthIcon:SetBackdropBorderColor(UI.Color(hearthRem > 0 and "danger" or "ok"))

        -- ROUND-22: the DMF cooldown pair. Same icon+value treatment as the two above, but
        -- its state is the SN DMFable tri-state rather than a raw item cooldown, so the rim
        -- follows the state token instead of a simple on/off-CD test (a boon-frozen DMF is
        -- neither "ready" green nor "on cooldown" red).
        -- ROUND-23 BUGFIX (owner saw a red "?"): the DMF icon was resolved ONCE at build
        -- time, but Dashboard.AuraIcon returns the question-mark FALLBACK when the spell art
        -- has not been cached by the client yet — and at pane-build time it usually has not.
        -- The WORLD BUFFS rows never showed this because they re-resolve on every refresh.
        -- Do the same here: re-set the texture each paint so it self-heals once the art is in.
        D.dmfIcon.icon:SetTexture(Dd.AuraIcon(D.dmfSlot or 5))
        local dmfText, dmfTok = Detail.DMFCooldownState(rec, e, CD_VALUE_W)
        D.dmfVal:SetText(dmfText); D.dmfVal:SetTextColor(UI.Color(dmfTok))
        D.dmfIcon.icon:SetDesaturated(dmfTok == "warn")   -- desat only while actually waiting
        D.dmfIcon:SetBackdropBorderColor(UI.Color(dmfTok))
        D.dmfIcon._state = dmfText; D.dmfIcon._stateTok = dmfTok

        -- Note.
        if not noteBox:HasFocus() then noteBox:SetText(noteGet(entry.nameRealm) or "") end
    end

    D:Show(nil)   -- start on the empty state until the first selection
    return D
end

-- ════════════════════════════════════════════════════════════════════════════
--  SELF-TEST  (suite "detail"): the surviving ledgerpage display suites — buff
--  matrix, DMF parenthetical, caption compact, raid tally. The open-entry /
--  one-open-max / auto-open-event / reflow suites RETIRE with the feature.
-- ════════════════════════════════════════════════════════════════════════════

-- A8: the parenthetical now reads the real 4h ONLINE-TIME model. The UI contract
-- is unchanged (READY / a red duration / "on CD"); what changed is that a
-- character who is ONLINE and mid-cooldown finally produces a duration instead
-- of always reading READY (A8.2).
-- ROUND-22: the DMF cooldown's TRI-STATE, now rendered in the COOLDOWNS block instead of
-- appended to the WORLD BUFFS row. Mirrors the SN DMFable model the engine implements.
local function testDMFCooldownState(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local base = 1000000

    -- DMFable: no active cooldown -> can take a new fortune.
    local t, tok = Detail.DMFCooldownState({ dmfCooldownActive = false }, base)
    ck(t == "Ready" and tok == "ok", "DMFable -> Ready/ok")

    -- Mid-cooldown while ONLINE: a real duration, warn (waiting, not a failure).
    local rec = { dmfCooldownActive = true,
                  dmfCooldown = { offlineSince = 0, remainingOnlineSecs = 3600,
                                  lastTickEpoch = base } }
    t, tok = Detail.DMFCooldownState(rec, base)
    ck(tok == "warn" and t ~= "On CD" and t ~= "Ready",
       "DMF mid-CD while online -> a warn duration")

    -- STASHED IN BOON: the cooldown is FROZEN, so it must NOT read as a countdown. Checked
    -- before the cooldown branch precisely so a boon never implies time is passing.
    local booned = { dmfInBoon = true, dmfCooldownActive = true,
                     dmfCooldown = { offlineSince = 0, remainingOnlineSecs = 3600,
                                     lastTickEpoch = base } }
    t, tok = Detail.DMFCooldownState(booned, base)
    ck(t == "In Boon" and tok == "ok", "DMF stashed in a boon -> In Boon/ok GREEN (round-23: was accent)")
    -- ...and a boon outranks even a ready cooldown (the buff is held, not re-takeable).
    t = Detail.DMFCooldownState({ dmfInBoon = true, dmfCooldownActive = false }, base)
    ck(t == "In Boon", "boon outranks the ready state")

    -- REMOTE record from a v1/v2 SENDER: the wire carries the boolean and no
    -- countdown, so the row keeps the third label rather than a bogus "Ready".
    -- This is the ZERO case J4 deliberately leaves alone — a peer that has not
    -- updated must still read exactly as it did before the schema bump.
    local remote = { dmfCooldownActive = true, dmfCooldown = { offlineSince = base } }
    t, tok = Detail.DMFCooldownState(remote, base + 3600)
    ck(t == "On CD" and tok == "warn", "DMF remote/unknown-remaining -> On CD/warn")

    -- ── J4 / schema v3: THE REMOTE COUNTDOWN, through the real row ────────────
    -- The point of the whole wave: a v3 sender's frame turns that flat "On CD"
    -- into a real countdown, rendered by the SAME helper, in the SAME token, at
    -- the SAME cell width as the hearth and chrono rows beside it. Asserted
    -- against Detail.CdDurationText directly so a future divergence between the
    -- DMF row and its two neighbours fails here rather than looking odd in game.
    local D = ns.Dashboard
    local savedOnline = D and D.IsOnline
    if D then D.IsOnline = function() return true end end

    local CELL = 89                       -- the round-25 value cell width
    local v3remote = { nameRealm = "Peer-Whitemane", lastDataUpdate = base,
                       lastSeen = base, dmfCooldownActive = true,
                       dmfCooldown = { offlineSince = 0 },   -- what decode rebuilds
                       dmfCooldownRemaining = 9000 }
    t, tok = Detail.DMFCooldownState(v3remote, base, CELL)
    ck(tok == "warn", "J4: a remote countdown reads warn, exactly like the hearth row")
    ck(t == Detail.CdDurationText(9000, CELL),
       "J4: the remote countdown must render through Detail.CdDurationText like every "
       .. "other cooldown row (got " .. tostring(t) .. ")")
    ck(t ~= "On CD" and t ~= "Ready", "J4: a v3 sender must not still read as the flag alone")

    -- ...and it DECAYS against the sender's stamp, so the row moves between pushes.
    t = Detail.DMFCooldownState(v3remote, base + 600, CELL)
    ck(t == Detail.CdDurationText(8400, CELL),
       "J4: the remote countdown must decay against lastDataUpdate (got " .. tostring(t) .. ")")

    -- Decayed past zero returns to the flag-only label rather than lying "Ready":
    -- the FLAG still says the cooldown is running, we have just lost the number.
    t, tok = Detail.DMFCooldownState(v3remote, base + 99999, CELL)
    ck(t == "On CD" and tok == "warn", "J4: a countdown decayed to 0 falls back to On CD")

    -- A BOONED remote still reads In Boon — the boon branch outranks the number,
    -- because a stashed fortune's cooldown is frozen, not counting down.
    local boonedRemote = { nameRealm = "Peer-Whitemane", lastDataUpdate = base, lastSeen = base,
                           dmfInBoon = true, dmfCooldownActive = true,
                           dmfCooldown = { offlineSince = 0 }, dmfCooldownRemaining = 9000 }
    t, tok = Detail.DMFCooldownState(boonedRemote, base + 600, CELL)
    ck(t == "In Boon" and tok == "ok", "J4: a booned remote still reads In Boon, never a countdown")

    -- OFFLINE remote: frozen, not wall-clocked away (it is an ONLINE-time cooldown).
    if D then D.IsOnline = function() return false end end
    t = Detail.DMFCooldownState(v3remote, base + 600, CELL)
    ck(t == Detail.CdDurationText(9000, CELL),
       "J4: an OFFLINE peer's countdown must freeze, got " .. tostring(t))
    if D then D.IsOnline = savedOnline end

    -- Defensive: a nil record must not error (the pane paints before a selection resolves).
    t, tok = Detail.DMFCooldownState(nil, base)
    ck(t == "Ready" and tok == "ok", "nil record -> Ready/ok, no error")

    -- Cleared cooldown reads Ready again.
    if ns.Store and ns.Store.DMFCooldownClear then
        ns.Store.DMFCooldownClear(rec)
        t, tok = Detail.DMFCooldownState(rec, base)
        ck(t == "Ready" and tok == "ok", "DMF cleared -> Ready/ok")
    end
end

local function testBuffMatrix(fails)
    local D = ns.Dashboard
    if not (D and D.AURA_META) then fails[#fails + 1] = "Dashboard.AURA_META unavailable"; return end
    -- SETTINGS-REWORK ITEM 6: class rules are read from the ONE global table
    -- (Store.GetAuraRules), not from a faction block, so the stub moved with it.
    local savedGAR = ns.Store and ns.Store.GetAuraRules
    ns.Store = ns.Store or {}
    ns.Store.GetAuraRules = function()
        return {
            rend  = { required = { WARRIOR = true }, optional = {} },
            dmtSP = { required = {}, optional = { MAGE = true } },
        }
    end
    local BOON = (ns.Store.AURA_SOURCE and ns.Store.AURA_SOURCE.BOON) or 2
    local e = 1000000
    local function slotOf(key) for s, m in pairs(D.AURA_META) do if m.key == key then return s end end end
    local onySlot, rendSlot, spSlot = slotOf("ony"), slotOf("rend"), slotOf("dmtsp")
    local fffSlot = slotOf("fff")   -- the collapsing seasonal tail slot (was Blackfathom)

    -- SETTINGS-REWORK ITEM 4: "healthy" is now measured by the FIXED rule, not by
    -- an editable threshold pair. Ony is a 2h buff, so healthy means >= 90 min —
    -- 100 minutes here. (This case used to pass 3600s, which the old configurable
    -- Horde threshold called healthy and the fixed rule correctly calls yellow.)
    local rec = { classTag = "WARRIOR", auraStates = { [onySlot] = { duration = 6000 } } }
    local st = Detail.BuffTileState(onySlot, rec, "Horde", e)
    if not (st.shown and st.calm and not st.missing) then fails[#fails + 1] = "owned healthy buff should be shown+calm" end

    -- ...and the same buff one minute under the cutoff is yellow, never red.
    rec.auraStates[onySlot] = { duration = 89 * 60 }
    st = Detail.BuffTileState(onySlot, rec, "Horde", e)
    if not (st.shown and not st.missing and st.durTok ~= "danger" and st.calm == false) then
        fails[#fails + 1] = "2h buff just under 90m -> shown, not calm, and NOT danger"
    end

    rec.auraStates[onySlot] = { duration = 1200, source = BOON }
    st = Detail.BuffTileState(onySlot, rec, "Horde", e)
    if not (st.boon and st.tint == "ok" and st.durTok == "ok"
            and st.durText == Detail.CompactDuration(1200)
            and st.fullText and st.fullText:find("%(Boon%)")) then
        fails[#fails + 1] = "boon tile: frozen duration (green), (Boon) on tooltip"
    end

    st = Detail.BuffTileState(rendSlot, { classTag = "WARRIOR", auraStates = {} }, "Horde", e)
    if not (st.shown and st.missing and st.tint == "danger") then fails[#fails + 1] = "required missing -> shown+danger" end
    st = Detail.BuffTileState(spSlot, { classTag = "ROGUE", auraStates = {} }, "Horde", e)
    if st.shown then fails[#fails + 1] = "ignored class-rule slot should collapse (hidden) when absent" end
    st = Detail.BuffTileState(spSlot, { classTag = "MAGE", auraStates = {} }, "Horde", e)
    if not (st.shown and st.missing and st.tint == "warn") then fails[#fails + 1] = "optional class-rule missing -> shown+warn" end
    st = Detail.BuffTileState(fffSlot, { classTag = "MAGE", auraStates = {} }, "Horde", e)
    if st.shown then fails[#fails + 1] = "absent tail slot (FFF) should collapse (hidden)" end

    -- ---- A6.8 / A7.6 through the TILE, not just the helper -----------------
    -- An ONLINE character's tile caption ages; an offline one's does not; a
    -- booned tile never does. The tile is what the owner actually looks at, so
    -- the decay is asserted here and not only on Dashboard.AuraRemaining.
    local savedWinners = D._onlineWinners
    D._onlineWinners = { winner = { ["9"] = "Live-R" }, charAID = { ["Live-R"] = "9",
                                                                   ["Dead-R"] = "9" } }

    local liveRec = { nameRealm = "Live-R", classTag = "WARRIOR", lastDataUpdate = e,
                      lastSeen = e, auraStates = { [onySlot] = { duration = 3600, source = 0 } } }
    st = Detail.BuffTileState(onySlot, liveRec, "Horde", e + 600)
    if st.durText ~= Detail.CompactDuration(3000) then
        fails[#fails + 1] = "A6.8: an ONLINE character's tile must decay (3600 -> 3000 after 600s)"
    end

    -- Same account, NOT the winner -> offline -> frozen.
    local deadRec = { nameRealm = "Dead-R", classTag = "WARRIOR", lastDataUpdate = e,
                      lastSeen = e, auraStates = { [onySlot] = { duration = 3600, source = 0 } } }
    st = Detail.BuffTileState(onySlot, deadRec, "Horde", e + 600)
    if st.durText ~= Detail.CompactDuration(3600) then
        fails[#fails + 1] = "A6.8: an OFFLINE character's tile stays FROZEN at 3600"
    end

    -- A7.6: booned + online -> still frozen, still green, still "(Boon)".
    local boonedRec = { nameRealm = "Live-R", classTag = "WARRIOR", lastDataUpdate = e,
                        lastSeen = e,
                        auraStates = { [onySlot] = { duration = 3600, source = BOON } } }
    st = Detail.BuffTileState(onySlot, boonedRec, "Horde", e + 600)
    if not (st.boon and st.durText == Detail.CompactDuration(3600)) then
        fails[#fails + 1] = "A7.6: a BOONED tile never decays, even for an online character"
    end

    -- A buff that has fully run out on an online character reads MISSING.
    local goneRec = { nameRealm = "Live-R", classTag = "WARRIOR", lastDataUpdate = e,
                      lastSeen = e, auraStates = { [onySlot] = { duration = 300, source = 0 } } }
    st = Detail.BuffTileState(onySlot, goneRec, "Horde", e + 600)
    if not (st.shown and st.missing) then
        fails[#fails + 1] = "A6.8: a buff decayed past 0 on an online character reads MISSING"
    end

    D._onlineWinners = savedWinners
    if ns.Store then ns.Store.GetAuraRules = savedGAR end
end

-- DETAIL / CARD AGREEMENT on a DUPLICATE Name-Realm.
--
-- The regression: the detail pane called AuraRemaining with no online and no
-- aid, so it re-resolved presence from the record alone. For a Name-Realm that
-- sits under more than one account bucket the winners table cannot attribute it
-- (charAID[name] == false) and IsOnline drops to bare lastSeen recency — so the
-- CARD (which carries the roster entry's online + aid) could show a live buff
-- decaying while the DETAIL beside it showed the same buff frozen. Show() now
-- threads the entry's own online + aid into every tile.
local function testDetailCardAgreement(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local D = ns.Dashboard
    if not (D and D.AURA_META and D.AuraRemaining) then
        ck(false, "Dashboard unavailable"); return
    end
    local function slotOf(key) for s, m in pairs(D.AURA_META) do if m.key == key then return s end end end
    local onySlot = slotOf("ony")
    if not onySlot then ck(false, "ony slot missing"); return end

    local savedGAR = ns.Store and ns.Store.GetAuraRules
    ns.Store = ns.Store or {}
    ns.Store.GetAuraRules = function()
        return { rend = { required = {}, optional = {} },
                 dmtSP = { required = {}, optional = {} } }
    end
    local savedWinners = D._onlineWinners
    local savedPeers   = ns.Mesh and ns.Mesh.peers
    if ns.Mesh then ns.Mesh.peers = {} end

    -- "Dup-R" is held by accounts 1 and 2 -> unattributable by name alone
    -- (charAID == false). Account 1's copy is the live winner.
    D._onlineWinners = { winner = { ["1"] = "Dup-R", ["2"] = "Other-R" },
                         charAID = { ["Dup-R"] = false } }

    local T = 1700000000
    -- lastSeen is deliberately ANCIENT so the recency fallback says OFFLINE:
    -- only the aid-aware answer can call this character online.
    local rec = { nameRealm = "Dup-R", classTag = "WARRIOR", faction = "Horde",
                  lastDataUpdate = T, lastSeen = 0,
                  auraStates = { [onySlot] = { duration = 3600, source = 0 } } }
    local entry = { nameRealm = "Dup-R", rec = rec, aid = "1", online = true, faction = "Horde" }

    -- The CARD's answer (it has always used entry.online).
    local cardRem = D.AuraRemaining(rec, onySlot, T + 600, entry.online)
    ck(cardRem == 3000, "card: an online duplicate-name character's buff decays 3600 -> 3000")

    -- The DETAIL's answer, now threaded with the same online + aid.
    local st = Detail.BuffTileState(onySlot, rec, entry.faction, T + 600, entry.online, entry.aid)
    ck(st.durText == Detail.CompactDuration(cardRem),
       "detail tile agrees with the card (" .. tostring(st.durText) ..
       " vs " .. Detail.CompactDuration(cardRem) .. ")")

    -- Even with online UNSTAMPED, the aid alone is enough to reach the same
    -- answer — this is the path a bare-nameRealm Show() takes.
    local stAid = Detail.BuffTileState(onySlot, rec, entry.faction, T + 600, nil, entry.aid)
    ck(stAid.durText == Detail.CompactDuration(cardRem),
       "detail resolves online from the aid when the caller did not stamp it")

    -- And the proof that the plumbing is load-bearing: with NEITHER, the old
    -- code path falls to recency and freezes at 3600 — the disagreement itself.
    local stBare = Detail.BuffTileState(onySlot, rec, entry.faction, T + 600)
    ck(stBare.durText == Detail.CompactDuration(3600),
       "guard: with no online and no aid the answer really does freeze (the old bug)")

    -- An OFFLINE entry must still freeze on both surfaces (no over-correction).
    local offRem = D.AuraRemaining(rec, onySlot, T + 600, false)
    local stOff  = Detail.BuffTileState(onySlot, rec, entry.faction, T + 600, false, "2")
    ck(offRem == 3600 and stOff.durText == Detail.CompactDuration(3600),
       "an offline entry stays frozen on both card and detail")

    D._onlineWinners = savedWinners
    if ns.Mesh then ns.Mesh.peers = savedPeers end
    if ns.Store then ns.Store.GetAuraRules = savedGAR end
end

local function testCaptionCompact(fails)
    local C = Detail.CompactDuration
    local cases = { { 3600 + 59 * 60, "1h59" }, { 3600 + 5 * 60, "1h05" }, { 59 * 60, "59m" },
                    { 45, "45s" }, { 2 * 86400 + 3 * 3600, "2d3h" }, { 0, "0" } }
    for _, c in ipairs(cases) do
        local got = C(c[1])
        if got ~= c[2] then fails[#fails + 1] = ("CompactDuration(%d)=%q expected %q"):format(c[1], got, c[2]) end
        if #got > 5 then fails[#fails + 1] = ("caption %q exceeds 5-char tile budget"):format(got) end
    end
end

local function testRaidTally(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local e = 1000000
    local rec = { raidLockouts = { MC = e + 3600, BWL = e - 10, Ony = e + 7200 } }
    local list, locked, open = Detail.RaidTally(rec, e)
    if #list ~= #TALLY_ORDER then fails[#fails + 1] = "tally should list all 7 raids" end

    -- ROUND-22 addendum: the owner-canon order "MC BWL AQ40 NAXX | ONY ZG AQ20", and the
    -- divider index that splits weekly-reset from short-cycle raids.
    local want = { "MC", "BWL", "AQ40", "Naxx", "Ony", "ZG", "AQ20" }
    for i, key in ipairs(want) do
        ck(list[i] and list[i].key == key,
            ("tally slot %d should be %s (got %s)"):format(i, key, tostring(list[i] and list[i].key)))
    end
    ck(Detail.TALLY_SPLIT == 4, "divider sits after the 4th key (Naxx | Ony)")

    -- ROUND-23 BUGFIX, pinned: the composed tally must not contain an UNESCAPED pipe. The
    -- shipped bug was Colored("|") producing |cff… .. "|" .. |r — the parser ate "||" as an
    -- escaped pipe and rendered a literal "r" ("Naxx |r Ony"). Walk the string and require
    -- that every "|" is either part of |c…/|r or doubled.
    -- Walk it exactly as WoW's parser does — "||" is an escape and consumes BOTH pipes —
    -- and require the colour nesting to balance. This is the assertion that actually
    -- catches the bug: with a bare "|" divider the string is |cff… .. "|" .. "|r", whose
    -- middle pipes pair off as an escape, leaving a literal "r" and the colour NEVER
    -- CLOSED. (A naive "is there a lone pipe?" check does NOT catch it — verified by
    -- regression — because after the escape pairs up there is no lone pipe left.)
    local s = Detail.TallyText(list)
    local i, depth, bad = 1, 0, nil
    while i <= #s do
        if s:sub(i, i) == "|" then
            local nxt = s:sub(i + 1, i + 1)
            if nxt == "|" then i = i + 2                 -- escaped literal pipe
            elseif nxt == "c" then depth = depth + 1; i = i + 10
            elseif nxt == "r" then depth = depth - 1; i = i + 2
            else bad = bad or i; i = i + 1 end
            if depth < 0 then bad = bad or i end
        else i = i + 1 end
    end
    ck(bad == nil, "tally has no stray '|' escape (first at " .. tostring(bad) .. ")")
    ck(depth == 0, "every |c colour is closed by a |r (unbalanced depth " .. depth .. ")")
    -- ...and the visible divider is present exactly once, as a properly ESCAPED pipe.
    local _, n = s:gsub("||", "")
    ck(n == 1, "exactly one escaped-pipe divider in the tally (got " .. tostring(n) .. ")")
    ck(want[Detail.TALLY_SPLIT] == "Naxx" and want[Detail.TALLY_SPLIT + 1] == "Ony",
        "the split really is the weekly / short-cycle boundary")
    if locked ~= 2 then fails[#fails + 1] = "expected 2 locked (MC, Ony), got " .. locked end
    if open ~= 5 then fails[#fails + 1] = "expected 5 open, got " .. open end

    -- Round-17 addendum: the three-state ink rule (pure).
    ck(Detail.TallyToken(true,  true)  == "danger", "locked + attuned -> danger (red)")
    ck(Detail.TallyToken(true,  false) == "danger", "locked wins over not-attuned")
    ck(Detail.TallyToken(true,  nil)   == "danger", "locked + unknown -> danger")
    ck(Detail.TallyToken(false, true)  == "ok",     "open + attuned -> ok (green)")
    ck(Detail.TallyToken(false, false) == "faint",  "open + NOT attuned -> faint (grey)")
    -- The contract that keeps remote characters rendering as they do today:
    ck(Detail.TallyToken(false, nil)   == "ok",     "open + UNKNOWN(nil) -> ok, never grey")

    -- Absent Store API (this round merges before the sibling's lands) = the nil path:
    -- every open raid must stay green, nothing greys.
    local savedStore = ns.Store
    ns.Store = {}
    local l2 = Detail.RaidTally(rec, e)
    for _, r in ipairs(l2) do
        ck(r.token == (r.locked and "danger" or "ok"),
            "no RaidAttuned API -> " .. r.key .. " falls back to locked/open colours")
    end
    -- With the API present, an explicit false greys ONLY that raid.
    ns.Store = { RaidAttuned = function(_, key) if key == "Naxx" then return false end return true end }
    local l3 = Detail.RaidTally(rec, e)
    for _, r in ipairs(l3) do
        if r.key == "Naxx" then ck(r.token == "faint", "Naxx not attuned -> faint")
        elseif r.locked then ck(r.token == "danger", r.key .. " locked -> danger")
        else ck(r.token == "ok", r.key .. " open + attuned -> ok") end
    end
    ns.Store = savedStore
end

-- Round-17: the header-rule padding must not push the 10-row buff list out of the pane.
local function testDetailGeometry(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- ROUND-18: the hairline was raised 2px to line up with the first card's top rail, so
    -- the grid follows: PAD_V 12 + HEADER_H 40 + HRULE_GAP 4 + GRID_GAP 6.
    ck(Detail.GridTop() == -51, "grid top -51 (below the hairline, +6 clear air)")
    local ruleY = -(10 + 31 + 4)
    ck(Detail.GridTop() < ruleY, "eyebrows start BELOW the rule (the round-17 bug)")
    ck(ruleY - Detail.GridTop() == 6, "exactly 6px of air between rule and eyebrow")

    -- CROSS-PANEL ALIGNMENT (round-18 item 3): the detail hairline and the cards list top
    -- must share a screen Y. Both panels hang off the same body top rail (MARGIN), so the
    -- two offsets have to match exactly. cards side = CHIP_H(44) + LIST_PAD(12).
    ck(Detail.HeaderRuleOffset() == 45,
        "detail rule sits 45 below the panel top (got " .. tostring(Detail.HeaderRuleOffset()) .. ")")
    ck(Detail.HeaderRuleOffset() == 1 + 44,
        "...which is exactly the cards chip-bar RULE offset (1 + CHIP_H) — the owner reference")

    -- ROUND-19: pane grew 292 -> 315 (window 620 -> 643), the 2px row gap is restored, and
    -- the bottom-left RAID LOCKOUTS line is reserved out of the usable height.
    -- ROUND-20: the lockout block STACKED (eyebrow above the keys), so it reserves 37 not
    -- 19, and the pane grew 315 -> 333 (window 643 -> 661) to pay the +18.
    local f = Detail.BuffListFit(320, 10)
    ck(f.listH == 198, "10 rows at the RESTORED pitch 20 = 198px (got " .. tostring(f.listH) .. ")")
    ck(f.listTop == 75, "list starts at 75 (51 grid + 24 eyebrow offset)")
    ck(f.lockH == 37, "stacked lockout block reserves 37px (12 label + 6 + 13 keys + 6 gap)")
    ck(f.limit == 273, "usable bottom is 273 (320 pane - 10 pad - 37 lockout block)")
    ck(f.fits == true, "10 rows AND the stacked lockout block fit the 320px pane")
    ck(f.slack == 0, "the pane is sized EXACTLY (0 slack, got " .. tostring(f.slack) .. ")")
    -- 333 is the minimum that works: one px less and the 10th row collides with lockouts.
    ck(Detail.BuffListFit(319, 10).fits == false, "319 would NOT fit — 320 is the true minimum")
    -- Stacking cost exactly +18 over round-19's inline row; that is the window growth.
    ck(f.lockH - 19 == 18, "stacking cost +18px, which is the 643 -> 661 window growth")
    -- And the debt really is repaid: the old 1px gap is no longer what makes it fit.
    ck(198 - (10 * 18 + 9 * 1) == 9, "restoring the gap cost 9px, funded by the +23 growth")
end

-- Row-list STATUS matrix (owner round-3): map a BuffTileState result -> (text, tok).
-- ROUND-23: the detail header's sub-line copy.
local function testHeaderSubline(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local SEP = "  \194\183  "

    ck(Detail.HeaderSubline({ level = 60, className = "Rogue" }, 1)
        == "Level 60" .. SEP .. "Rogue" .. SEP .. "Account 1",
        "full sub-line -> 'Level 60 · Rogue · Account 1'")

    -- "Account N", never the old "#N".
    local s = Detail.HeaderSubline({ level = 60, className = "Rogue" }, 2)
    ck(s:find("Account 2", 1, true) ~= nil, "account reads 'Account 2'")
    ck(s:find("#", 1, true) == nil, "the old '#N' shorthand is gone")

    -- Account segment OMITTED cleanly when the id is absent or non-numeric — and crucially
    -- without leaving a dangling separator.
    for _, aid in ipairs({ "", "abc" }) do
        local t = Detail.HeaderSubline({ level = 60, className = "Rogue" }, aid)
        ck(t == "Level 60" .. SEP .. "Rogue", "aid '" .. aid .. "' -> account segment dropped")
        ck(t:sub(-#SEP) ~= SEP, "no trailing separator for aid '" .. aid .. "'")
    end
    local t = Detail.HeaderSubline({ level = 60, className = "Rogue" }, nil)
    ck(t == "Level 60" .. SEP .. "Rogue", "nil aid -> account segment dropped")
    ck(t:find("Account", 1, true) == nil, "nil aid -> no empty 'Account' text")

    -- A numeric STRING id still counts (the store keeps aids as strings).
    ck(Detail.HeaderSubline({ level = 60, className = "Rogue" }, "3"):find("Account 3", 1, true) ~= nil,
        "string aid '3' -> Account 3")

    -- Fallbacks: classTag when className is absent, default level, nil record.
    ck(Detail.HeaderSubline({ level = 55, classTag = "ROGUE" }, nil)
        == "Level 55" .. SEP .. "ROGUE", "falls back to classTag")
    ck(Detail.HeaderSubline({ className = "Mage" }, nil):find("Level 60", 1, true) ~= nil,
        "missing level defaults to 60")
    ck(Detail.HeaderSubline(nil, nil):find("Level 60", 1, true) ~= nil, "nil record -> no error")

    -- ── ROUND-25: the fixed 60 / 40 column split ────────────────────────────────
    local sp = Detail.ColumnSplit()
    ck(sp.inner == 714, "inner width 714 (pane 742 - 2*PAD_H 14)")
    ck(sp.avail == 700, "700 available after the 14px gutter")
    ck(sp.c1 == 420 and sp.c2 == 280, "60/40 -> C1 420, C2 280 (got " .. sp.c1 .. "/" .. sp.c2 .. ")")
    ck(sp.c1 + sp.c2 + sp.gap == sp.inner, "the two columns + gutter exactly fill the inner width")
    -- The fractions are the OWNER'S input, so the function must honour whatever it is given.
    local half = Detail.ColumnSplit(742, 14, 14, 0.5)
    ck(half.c1 == half.c2, "an even split really splits evenly (no baked-in bias)")

    -- VALIDATION, not derivation: C1 holds its widest content at the 1.3x font ceiling.
    local fit = Detail.ColumnFits(sp.c1, 1.3)
    ck(fit.fits == true, "C1 420 holds its widest row at 1.3x (needs " .. fit.need .. ")")
    ck(fit.short == 0, "no shortfall at 1.3x")
    ck(Detail.ColumnFits(sp.c1, 1.0).fits == true, "C1 fits at 1.0x too")
    -- ...and the validator must actually BITE: an absurdly narrow C1 has to report the gap.
    local tight = Detail.ColumnFits(240, 1.3)
    ck(tight.fits == false and tight.short > 0,
        "validator flags a too-narrow C1 (short " .. tight.short .. ")")
    ck(tight.worst == "buff-row status" or tight.worst == "raid tally",
        "validator names which row is the binding one")

    -- ── ROUND-25b: cooldown durations go back to the SPACED form, with a MEASURED
    -- compact fallback. The real cell after the 60/40 split is (280-12)/3 - 16 - 6 = ~67.
    local CELL = (280 - 12) / 3 - 16 - 6
    local spacedForm = Detail.CdDurationText(45000, CELL)          -- 12h 30m
    ck(spacedForm:find(" ", 1, true) ~= nil, "spaced form is used at the real cell width")
    ck(spacedForm == Dash().FormatDuration(45000), "spaced form matches FormatDuration")
    ck(Detail.CdDurationText(45000, CELL, 1.3):find(" ", 1, true) ~= nil,
        "spaced form still fits at the 1.3x font ceiling (that is why it could come back)")
    -- ...and the fallback genuinely triggers when the cell really is too small — this is
    -- the round-23 situation, so the workaround still exists where it is warranted.
    local narrow = Detail.CdDurationText(45000, 20)
    ck(narrow == Detail.CompactDuration(45000), "too-narrow cell falls back to compact")
    ck(narrow:find(" ", 1, true) == nil, "the compact fallback has no space")
    ck(Detail.CdDurationText(45000, nil) == Dash().FormatDuration(45000),
        "no cell width given -> spaced (measurement is opt-in, not assumed)")

    -- Separator matches the statusFS beside it in the same band (one rhythm, not two).
    ck(SEP == "  \194\183  ", "separator is the suite middot, spaced like statusFS")
end

local function testRowStatus(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- missing required -> "Missing" / danger
    local t, tok = Detail.RowStatus({ shown = true, missing = true, tint = "danger" }, false)
    ck(t == "Missing" and tok == "danger", "missing required -> Missing/danger")
    -- missing optional -> "Missing" / warn
    t, tok = Detail.RowStatus({ shown = true, missing = true, tint = "warn" }, false)
    ck(t == "Missing" and tok == "warn", "missing optional -> Missing/warn")
    -- present healthy -> duration / durTok
    t, tok = Detail.RowStatus({ shown = true, missing = false, fullText = "1h 2m", durTok = "ok" }, false)
    ck(t == "1h 2m" and tok == "ok", "present -> duration/ok")
    -- booned -> full "..(Boon)" / ok
    t, tok = Detail.RowStatus({ shown = true, missing = false, boon = true, fullText = "1h 59m (Boon)", durTok = "ok" }, false)
    ck(t == "1h 59m (Boon)" and tok == "ok", "boon -> frozen dur (Boon)/ok")
    -- ROUND-22: a missing DMF now reads "Missing" like every other row — its re-acquire
    -- state moved to the COOLDOWNS block, so the row no longer special-cases. Passing
    -- isDMF=true must make NO difference any more; that is the whole point of the change.
    t, tok = Detail.RowStatus({ shown = true, missing = true, durText = "READY", durTok = "ok", tint = "danger" }, true)
    ck(t == "Missing" and tok == "danger", "missing DMF -> Missing/danger (CD moved to COOLDOWNS)")
    local t2, tok2 = Detail.RowStatus({ shown = true, missing = true, durText = "READY", durTok = "ok", tint = "danger" }, false)
    ck(t == t2 and tok == tok2, "isDMF flag no longer changes RowStatus output")
    -- hidden slot -> empty
    t = Detail.RowStatus({ shown = false }, false)
    ck(t == "", "hidden slot -> empty status")
end

-- Pop-pass COLOR functions must return THREE numbers (round-4 hotfix regression guard).
-- The crash was `local r,g,b = A and B and Call()` truncating the multi-return so g/b
-- were nil and the brighten arithmetic threw. These assert all three components.
local function testColorFns(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    -- Pure lift preserves the multi-return.
    local a, b, c = Detail.Lighten(0.5, 0.4, 0.9, 0.12)
    ck(type(a) == "number" and type(b) == "number" and type(c) == "number",
        ("Lighten must return 3 numbers, got %s/%s/%s"):format(type(a), type(b), type(c)))
    -- BrightClass with a RESOLVABLE class color must return 3 numbers — the exact
    -- crash path. SETTINGS-REWORK ITEM 1: ClassColor no longer reads
    -- SavedVariables at all, so there is nothing left to stub — it resolves from
    -- Store.DEFAULT_CLASS_COLORS. That the palette is ALWAYS resolvable is now
    -- part of the contract, so assert it here rather than faking it.
    ck(type(ns.Store) == "table" and type(ns.Store.DEFAULT_CLASS_COLORS) == "table"
        and ns.Store.DEFAULT_CLASS_COLORS.WARRIOR ~= nil,
        "Store.DEFAULT_CLASS_COLORS is the unconditional class palette")
    local r, g, bl = Detail.BrightClass("WARRIOR")
    ck(type(r) == "number" and type(g) == "number" and type(bl) == "number",
        ("BrightClass must return 3 numbers (no and-chain truncation), got %s/%s/%s")
        :format(type(r), type(g), type(bl)))
end

-- The COOLDOWNS item-icon path must route through ns.Dashboard (round-5 hotfix guard).
-- A BARE `Dashboard` global would ignore this stub and crash on the nil global — exactly
-- the render bug (ui_detail:413). Exercising the wrapper headless catches that class.
local function testItemIconTex(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local savedD = ns.Dashboard
    ns.Dashboard = { ItemIcon = function(id) return "TEX:" .. tostring(id) end }
    local t = Detail.ItemIconTex(184937)
    ck(t == "TEX:184937", "ItemIconTex must route through ns.Dashboard.ItemIcon (got " .. tostring(t) .. ")")
    ns.Dashboard = {}   -- engine absent -> non-empty fallback texture, never nil/crash
    local f = Detail.ItemIconTex(6948)
    ck(type(f) == "string" and f ~= "", "ItemIconTex must return a fallback texture when ItemIcon absent")
    ns.Dashboard = savedD
end

-- ROUND-29 (owner: "Escape loses the typed text"). The round-28 Escape handler reverted
-- the box to the stored note and THEN dropped focus, so the focus-lost save wrote the
-- reverted text back — everything typed was destroyed by the save path itself. The bug was
-- pure ORDERING, which is why the test drives Detail.NoteEscape (commit, then blur) with a
-- fake edit box rather than only asserting that CommitNote can write.
local function testNoteCommit(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local S = ns.Store
    if not (S and S.SetNote and S.GetNote) then
        fails[#fails + 1] = "note commit: ns.Store.SetNote/GetNote must exist for the note path"
        return
    end
    local NR = "NoteTester-Realm"
    S.SetNote(NR, "stored note")

    -- A fake EditBox. SetText is provided ON PURPOSE even though the commit path must not
    -- call it: that is what makes this test sensitive to a handler that reverts the box
    -- before saving, which is exactly what round-28 did.
    local function fakeBox(text)
        return { blurred = false,
                 GetText = function(self) return self.text end,
                 SetText = function(self, t) self.text = t end,
                 ClearFocus = function(self) self.blurred = true end,
                 text = text }
    end

    -- THE REGRESSION: type over the stored note, hit Escape.
    local box = fakeBox("typed but not committed")
    Detail.NoteEscape(box, NR)
    ck(S.GetNote(NR) == "typed but not committed",
        "note escape: Escape SAVES the typed text (got " .. tostring(S.GetNote(NR)) .. ")")
    ck(box.blurred == true, "note escape: Escape still drops focus")
    ck(box.text == "typed but not committed",
        "note escape: Escape must not revert the box's own text")

    -- Focus-loss (clicking away) goes through the same seam and must behave identically.
    Detail.CommitNote(NR, "clicked away")
    ck(S.GetNote(NR) == "clicked away", "note focus-loss: saves the current text")

    -- Clearing the box erases the note. Same shape Store.GetNote already reads back as nil,
    -- so no new store shape is introduced.
    ck(Detail.CommitNote(NR, "") == nil, "note commit: an empty box commits nil, not \"\"")
    ck(S.GetNote(NR) == nil, "note commit: an emptied box erases the stored note")

    -- No selected character -> nothing is written anywhere.
    S.SetNote(NR, "keep me")
    ck(Detail.CommitNote(nil, "orphan") == nil, "note commit: no character selected -> no write")
    ck(S.GetNote(NR) == "keep me", "note commit: an orphan commit cannot touch another note")
    local orphanBox = fakeBox("orphan")
    Detail.NoteEscape(orphanBox, nil)
    ck(orphanBox.blurred == true, "note escape: Escape blurs even with nothing selected")
    ck(S.GetNote(NR) == "keep me", "note escape: ...and still writes nothing")
    S.SetNote(NR, "")
end

----------------------------------------------------------------------
-- NX-14 (CLASS 8): Detail.Resolve agrees with the roster — on BOTH branches.
--
-- The shell-present branch was fixed earlier (it delegates to the roster's own
-- winner). The FALLBACK — reached whenever ns.Dashboard has not loaded, which is
-- exactly the frameless host `_test_detail.lua` exists to model — was still the
-- first-`pairs()`-hit lottery, so the one host with no shell to disagree with
-- could disagree with the store instead. Both branches now ask
-- Store.ResolveOwner, so the two cannot diverge from each other or from the card.
----------------------------------------------------------------------
local function testResolveAgreement(fails)
    local function ck(c, m) if not c then fails[#fails + 1] = m end end
    local OF = ns.OrderFixture
    local S = ns.Store
    local NAME = "Twinned-Whitemane"

    local savedData = S.data
    local aids = {}
    for i = 1, 30 do aids[i] = tostring(i) end
    local function mkBucket(aid)
        local rec = { nameRealm = NAME, ownerEpoch = 1000, lastDataUpdate = 1000, aidTag = aid }
        if aid == "17" then
            rec = { nameRealm = NAME, ownerEpoch = 8888, lastDataUpdate = 8888, aidTag = aid }
        end
        return { characters = { [NAME] = rec }, homeless = {} }
    end
    local A1, A2, A3 = OF.Histories(aids, mkBucket)
    ck(OF.Divergent(A1, A2, A3),
        "NX-14 fixture is not divergent — the three accounts-graph insertion histories "
        .. "walked in the same pairs() order, so this row proves nothing")

    -- The FALLBACK branch, driven the way the frameless host reaches it.
    local savedDash = ns.Dashboard
    ns.Dashboard = nil
    local function fallback(accounts)
        S.data = { accounts = accounts }
        local rec = Detail.Resolve(NAME)
        return rec and rec.aidTag or "nil"
    end
    local f1, f2v, f3 = fallback(A1), fallback(A2), fallback(A3)
    ns.Dashboard = savedDash

    ck(f1 == f2v and f2v == f3,
        "NX-14: the no-shell fallback picked a different copy per insertion history")
    ck(f1 == "17",
        "NX-14: the fallback picks the freshest copy, same as the roster (got " .. f1 .. ")")

    -- And the two branches must agree with each other on the same store.
    S.data = { accounts = A1 }
    local shellRec = Detail.Resolve(NAME)
    ck(shellRec and shellRec.aidTag == "17",
        "NX-14: the shell branch picks the same copy the fallback does")
    ck(Detail.Resolve("Nobody-Whitemane") == nil, "NX-14: an unheld name resolves to nothing")

    -- RED CONTROL: the code this replaced, on the same three histories.
    local function preFix(accounts)
        for _, b in pairs(accounts) do
            local rec = (b.characters and b.characters[NAME]) or (b.homeless and b.homeless[NAME])
            if rec then return rec.aidTag end
        end
    end
    local p1, p2, p3 = preFix(A1), preFix(A2), preFix(A3)
    ck(not (p1 == p2 and p2 == p3),
        "NX-14 RED CONTROL: the pre-fix first-pairs()-hit fallback agreed with itself "
        .. "across all three histories — this fixture would not have caught the bug")

    S.data = savedData
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("detail", function(verbose)
        local cases = {
            { name = "resolve agreement (NX-14)", fn = testResolveAgreement },
            { name = "note commit/escape", fn = testNoteCommit },
            { name = "dmf cooldown state", fn = testDMFCooldownState },
            { name = "buff display matrix", fn = testBuffMatrix },
            { name = "detail/card agreement", fn = testDetailCardAgreement },
            { name = "caption compact",     fn = testCaptionCompact },
            { name = "raid tally",          fn = testRaidTally },
            { name = "pane geometry",       fn = testDetailGeometry },
            { name = "header subline",      fn = testHeaderSubline },
            { name = "row status",          fn = testRowStatus },
            { name = "color fns (rgb)",     fn = testColorFns },
            { name = "item icon path",      fn = testItemIconTex },
        }
        local allPass = true
        for _, c in ipairs(cases) do
            local f2 = {}
            local ok = pcall(c.fn, f2)
            local passed = ok and #f2 == 0
            if not passed then allPass = false end
            if verbose and ns and ns.Print then
                if passed then ns:Print("  PASS detail/" .. c.name)
                elseif not ok then ns:Print("  FAIL detail/" .. c.name .. " :: error in test")
                else for _, m in ipairs(f2) do ns:Print("  FAIL detail/" .. c.name .. " :: " .. m) end end
            end
        end
        return allPass
    end)
end
