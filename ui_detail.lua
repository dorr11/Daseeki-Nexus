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
local PAD_V     = 12
local PAD_H     = 14
local HEADER_H  = 40          -- header band height (name row + border-bottom)
local COL_R_W   = 214         -- right column fixed width (mockup dgrid 1fr / 214px)
local COL_GAP   = 14
-- Buff display (owner round-3 verdict): a LABELED ROW LIST (return to the pre-rebuild
-- detail panel's row pattern) — one row per tracked buff: small cropped/framed icon ·
-- buff name (tinted by its family hue) · right-aligned STATE status. NOT a tile grid
-- (that's the compact CARD strip, §5b). The name carries buff IDENTITY; the status
-- column carries STATE color (Missing / duration / Boon / DMF parenthetical).
local BUFF_ICON   = 16        -- row icon edge (cropped/framed)
local BUFF_ROW_H  = 18        -- buff row height (round-4: 18 so all 10 slots fit the
local BUFF_ROW_GAP = 2        -- shorter 284 pane — pitch 20, 10 rows = 200px)
local BUFF_TOP    = 18        -- list top offset below the eyebrow label
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
    silithyst  = { 0.788, 0.702, 0.478 },   -- Silithyst — desert tan
    boon       = { 0.247, 0.663, 0.722 },   -- Blackfathom — deep teal
}

-- Open-page raid tally order + labels (BRAND_SPEC §7 L3: MC BWL ZG AQ40 Naxx Ony AQ20;
-- keys match Store.RAID_KEYS). Locked = cream ("text"), open = faint. No raid diamonds.
local TALLY_ORDER = { "MC", "BWL", "ZG", "AQ40", "Naxx", "Ony", "AQ20" }

local function Dash() return ns.Dashboard end
local function nowE()
    local D = Dash()
    return (D and D.Now and D.Now()) or (GetServerTime and GetServerTime()) or (time and time()) or 0
end

-- ════════════════════════════════════════════════════════════════════════════
--  PURE DISPLAY LOGIC (frame-free → unit-testable under the headless harness).
--  Re-housed verbatim from ui_ledgerpage.lua (the proven, owner-approved model).
-- ════════════════════════════════════════════════════════════════════════════

-- DMF cooldown remaining (prefers the Store accessor if present, else the 8h
-- resting-offline auto-clear rule). Clean end state is Store.DMFCooldownRemaining.
local DMF_OFFLINE_CLEAR = 8 * 3600
local function dmfCooldownRemaining(rec, e)
    if ns.Store and ns.Store.DMFCooldownRemaining then
        return ns.Store.DMFCooldownRemaining(rec, e) or 0
    end
    if not (rec and rec.dmfCooldownActive and rec.dmfCooldown) then return 0 end
    local since = rec.dmfCooldown.offlineSince or 0
    if since <= 0 then return 0 end
    local rem = (since + DMF_OFFLINE_CLEAR) - (e or nowE())
    return rem > 0 and math.floor(rem) or 0
end

-- DMF READY / remaining-CD parenthetical.
--   not on cooldown      -> "READY", "ok"     (green)
--   on cooldown, rem > 0 -> "<dur>", "danger" (red)
--   on cooldown, rem = 0 -> "on CD", "danger" (red)
function Detail.DMFParenthetical(rec, e)
    local D = Dash()
    if not rec.dmfCooldownActive then return "READY", "ok" end
    local rem = dmfCooldownRemaining(rec, e)
    if rem > 0 then return (D and D.FormatDuration(rem)) or tostring(rem), "danger" end
    return "on CD", "danger"
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
function Detail.BuffTileState(slot, rec, faction, e)
    local D = Dash()
    local meta = D and D.AURA_META and D.AURA_META[slot]
    if not meta then return { shown = false } end
    local st = rec.auraStates and rec.auraStates[slot]
    local present = st and (st.duration or 0) > 0
    local applicable, requirement = D.AuraRequirement(slot, rec, faction)
    local isDMF = meta.key == "dmf"

    if not (present or applicable or isDMF) then
        return { shown = false, slot = slot, spellID = meta.spellID }
    end

    if present then
        local BOON = (ns.Store and ns.Store.AURA_SOURCE and ns.Store.AURA_SOURCE.BOON) or 2
        local booned = (st.source == BOON or st.source == "boon")
        local full = D.FormatDuration(st.duration)
        if booned then
            -- Booned tile: FROZEN duration in GREEN (the ok color carries "boon");
            -- "(Boon)" surfaces once in the eyebrow + the tile hover tooltip.
            return { shown = true, slot = slot, missing = false, boon = true,
                     calm = true, tint = "ok",
                     durText = Detail.CompactDuration(st.duration), durTok = "ok",
                     fullText = full .. " (Boon)", spellID = meta.spellID }
        end
        local th  = D.GetThreshold(faction, meta.thresholdKey)
        local tok = D.AuraColorToken(st.duration, th)    -- ok / warn / danger
        return { shown = true, slot = slot, missing = false, boon = false,
                 calm = (tok == "ok"), tint = tok,
                 durText = Detail.CompactDuration(st.duration), durTok = tok,
                 fullText = full, spellID = meta.spellID }
    end

    -- Absent DMF still renders, surfacing its re-acquire window (READY / on-CD).
    if isDMF then
        local par, ptok = Detail.DMFParenthetical(rec, e)
        return { shown = true, slot = slot, missing = true, boon = false, calm = false,
                 tint = ptok, durText = par, durTok = ptok,
                 fullText = "(" .. par .. ")", spellID = meta.spellID }
    end

    -- Missing but applicable: required = danger, optional = warn.
    local tok = (requirement == "optional") and "warn" or "danger"
    return { shown = true, slot = slot, missing = true, boon = false, calm = false,
             tint = tok, durText = nil, durTok = tok, fullText = nil, spellID = meta.spellID }
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
        out[#out + 1] = {
            key = key,
            full = (D and D.RAID_FULLNAME and D.RAID_FULLNAME[key]) or key,
            locked = isLocked,
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
function Detail.RowStatus(s, isDMF)
    if not s or not s.shown then return "", "faint" end
    if s.missing then
        if isDMF then return (s.durText or "READY"), (s.durTok or "ok") end
        return "Missing", (s.tint or "danger")
    end
    return (s.fullText or s.durText or ""), (s.boon and "ok" or (s.durTok or "ok"))
end

-- Resolve a character record by nameRealm across all account buckets.
function Detail.Resolve(nameRealm)
    local data = ns.Store and ns.Store.GetData and ns.Store.GetData()
    if not data or not data.accounts then return nil end
    for aid, bucket in pairs(data.accounts) do
        local rec = (bucket.characters and bucket.characters[nameRealm])
                 or (bucket.homeless and bucket.homeless[nameRealm])
        if rec then return rec, aid end
    end
    return nil
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

-- ════════════════════════════════════════════════════════════════════════════
--  FRAME BUILD + INSTANT SWAP  (in-game only; UI is non-nil there)
-- ════════════════════════════════════════════════════════════════════════════

local function tag(frame, id)
    if ns.Audit and ns.Audit.Tag and frame then ns.Audit.Tag(frame, id) end
    return frame
end

local function fstr(parent, fontKey, justify)
    local f = parent:CreateFontString(nil, "OVERLAY")
    f:SetFontObject(UI.fonts[fontKey] or UI.fonts.body)
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
    row.status = fstr(row, "body", "RIGHT")
    row.status:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    -- Buff name (family-hue tinted), between the icon and the status column.
    row.name = fstr(row, "body"); row.name:SetJustifyH("LEFT"); row.name:SetWordWrap(false)
    row.name:SetPoint("LEFT", tile, "RIGHT", 8, 0)
    row.name:SetPoint("RIGHT", row.status, "LEFT", -8, 0)
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
    header:SetHeight(HEADER_H - 6)
    tag(header, "detail.header")
    D.header = header

    local nameFS = fstr(header, "header"); nameFS:SetPoint("BOTTOMLEFT", header, "BOTTOMLEFT", 0, 2)
    nameFS:SetWordWrap(false)
    local subFS = fstr(header, "small"); subFS:SetPoint("LEFT", nameFS, "RIGHT", 10, 0)
    subFS:SetTextColor(UI.Color("muted"))
    -- Status cluster (right): dot + Online/Offline · freshness.
    local statusFS = fstr(header, "microLabel", "RIGHT")
    statusFS:SetPoint("BOTTOMRIGHT", header, "BOTTOMRIGHT", 0, 3)
    -- Status pip: a DIAMOND with pop (round-8 item 2), matching the card pips.
    local statusDot, statusHalo = Dash().MakeStatusPip(header, 9)
    statusDot:SetPoint("RIGHT", statusFS, "LEFT", -8, 0)
    D.nameFS, D.subFS, D.statusFS, D.statusDot, D.statusHalo = nameFS, subFS, statusFS, statusDot, statusHalo

    -- Header bottom hairline (one sharp rule, §9 UI.Hairline). Pop pass: borderLite.
    local hrule = UI.Hairline(parent, { token = "borderLite" })
    hrule:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -6)
    hrule:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, -6)

    -- ── Two-column grid below the header ────────────────────────────────────
    local gridTop = -(PAD_V + HEADER_H)
    -- Left column (1fr): buff grid.
    local leftCol = CreateFrame("Frame", nil, parent)
    leftCol:SetPoint("TOPLEFT", parent, "TOPLEFT", PAD_H, gridTop)
    leftCol:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -(PAD_H + COL_R_W + COL_GAP), PAD_V)
    D.leftCol = leftCol

    local buffLbl = microLabel(leftCol, "WORLD BUFFS")
    buffLbl:SetPoint("TOPLEFT", leftCol, "TOPLEFT", 0, 0)
    D.buffLbl = buffLbl

    -- Buff ROW-LIST container (tagged for the geometry checker) below the eyebrow.
    local buffRows = CreateFrame("Frame", nil, leftCol)
    buffRows:SetPoint("TOPLEFT", leftCol, "TOPLEFT", 0, -BUFF_TOP)
    buffRows:SetPoint("BOTTOMRIGHT", leftCol, "BOTTOMRIGHT", 0, 0)
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

    -- Right column layout (owner round-3): the top rail is a SIDE-BY-SIDE pair —
    -- COOLDOWNS on the LEFT, RAID LOCKOUTS on the RIGHT (both labels share the
    -- rightCol top edge). NOTE moves to the BOTTOM where the buttons used to be.
    -- The Invite + Cancel-buffs buttons are DELETED (owner crossed them out; those
    -- actions stay on the minimap right-click menu). Split: cooldowns 92 · gap 12 ·
    -- lockouts 110 within the 214-wide column.
    local CD_W, LOCK_X = 92, 104

    -- COOLDOWNS block (top-left). Owner round-5: the CHRONO / HEARTH micro-labels are
    -- replaced by the ITEM ICONS (chronoboon 184937 / hearthstone 6948) — same
    -- cropped/framed treatment + item IDs the cards' right-edge stack uses — each
    -- followed by its colored state value. The icon IS the label; the full item name
    -- lives on the hover tooltip.
    local cdLbl = microLabel(rightCol, "COOLDOWNS")
    cdLbl:SetPoint("TOPLEFT", rightCol, "TOPLEFT", 0, 0)
    tag(cdLbl, "detail.cdlabel")
    local CD_ICON = 16
    local function cdIconRow(itemID, fullName, y)
        local f = CreateFrame("Frame", nil, rightCol, "BackdropTemplate")
        f:SetSize(CD_ICON, CD_ICON)
        f:SetPoint("TOPLEFT", rightCol, "TOPLEFT", 0, y)
        UI.Skin(f, function(self)
            self:SetBackdrop(UI.FLAT_BACKDROP)
            self:SetBackdropColor(UI.Color("inset"))
            self:SetBackdropBorderColor(UI.Color("borderLite"))
        end)
        local ic = f:CreateTexture(nil, "ARTWORK")
        ic:SetPoint("TOPLEFT", f, "TOPLEFT", 1, -1)
        ic:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -1, 1)
        ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        ic:SetTexture(Detail.ItemIconTex(itemID))
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
        -- Colored state value, right-aligned to CD_W, vertically centered on the icon.
        local vf = fstr(rightCol, "numeral", "RIGHT")
        vf:SetPoint("LEFT", f, "RIGHT", 6, 0)
        vf:SetPoint("RIGHT", rightCol, "TOPLEFT", CD_W, y - CD_ICON / 2)
        return f, vf
    end
    local chronoIcon, chronoVal = cdIconRow(184937, "Chronoboon Displacer", -16)
    local hearthIcon, hearthVal = cdIconRow(6948, "Hearthstone", -37)
    tag(chronoIcon, "detail.cdicon1")   -- 16px item-icon square (geometry assertion)
    D.chronoVal, D.hearthVal = chronoVal, hearthVal
    D.chronoIcon, D.hearthIcon = chronoIcon, hearthIcon

    -- RAID LOCKOUTS block (top-right), sharing the top rail.
    local raidLbl = microLabel(rightCol, "RAID LOCKOUTS")
    raidLbl:SetPoint("TOPLEFT", rightCol, "TOPLEFT", LOCK_X, 0)
    tag(raidLbl, "detail.raidlabel")
    local tallyFS = fstr(rightCol, "numeral"); tallyFS:SetPoint("TOPLEFT", raidLbl, "BOTTOMLEFT", 0, -6)
    tallyFS:SetPoint("RIGHT", rightCol, "RIGHT", 0, 0); tallyFS:SetJustifyH("LEFT"); tallyFS:SetWordWrap(true)
    D.tallyFS = tallyFS

    -- NOTE block — PINNED TO THE PANE BOTTOM (owner round-4 item 2): the editbox sits
    -- flush at the right column's bottom (just above the dock divider), the label rides
    -- above it. Full column width.
    local noteBox = CreateFrame("EditBox", nil, rightCol, "BackdropTemplate")
    noteBox:SetPoint("BOTTOMLEFT", rightCol, "BOTTOMLEFT", 0, 0)
    noteBox:SetPoint("RIGHT", rightCol, "RIGHT", 0, 0)
    noteBox:SetHeight(22); noteBox:SetAutoFocus(false)
    local noteLbl = microLabel(rightCol, "NOTE")
    noteLbl:SetPoint("BOTTOMLEFT", noteBox, "TOPLEFT", 0, 4)
    tag(noteLbl, "detail.notelabel")
    noteBox:SetFontObject(UI.fonts.body); noteBox:SetTextInsets(7, 7, 0, 0)
    UI.Skin(noteBox, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("controlBorder"))
    end)
    local function noteGet(nr) if ns.Store and ns.Store.GetNote then return ns.Store.GetNote(nr) end end
    local function noteSet(nr, t) if ns.Store and ns.Store.SetNote then ns.Store.SetNote(nr, t) end end
    noteBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    noteBox:SetScript("OnEscapePressed", function(self) self:SetText(noteGet(D._current or "") or ""); self:ClearFocus() end)
    noteBox:SetScript("OnEditFocusLost", function(self)
        if D._current then local t = self:GetText(); noteSet(D._current, (t ~= "" and t) or nil) end
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
            entry = rec and { nameRealm = entry, rec = rec, aid = aid,
                              online = Dash().IsOnline(rec, entry) } or nil
        end
        if not entry or not entry.rec then
            D._current, D._entry = nil, nil
            emptyFS:Show(); header:Hide(); hrule:Hide()
            leftCol:Hide(); rightCol:Hide()
            return
        end
        emptyFS:Hide(); header:Show(); hrule:Show(); leftCol:Show(); rightCol:Show()
        D._current, D._entry = entry.nameRealm, entry
        local rec = entry.rec
        local Dd = Dash()
        local e = nowE()
        local faction = entry.faction or rec.faction

        -- Header. Name = short (realm stripped) in the brightened class hue (pop pass).
        nameFS:SetText(Dd.ShortName(entry.nameRealm))
        nameFS:SetTextColor(brightClass(rec.classTag))
        local acct = (entry.aid and entry.aid ~= "" and ("#" .. entry.aid)) or ""
        subFS:SetText(("Level %s %s  %s"):format(rec.level or 60, rec.className or rec.classTag or "?", acct))
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
            local s = Detail.BuffTileState(slot, rec, faction, e)
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
                local statusText, statusTok = Detail.RowStatus(s, meta.key == "dmf")
                if meta.key == "dmf" and not s.missing then
                    local par, ptok = Detail.DMFParenthetical(rec, e)
                    statusText = statusText .. "  " .. Dd.Colored("(" .. par .. ")", ptok)
                end
                row.status:SetText(statusText)
                row.status:SetTextColor(UI.Color(statusTok))
                row._tipName = meta.name
                row._tipFull = s.fullText or (s.missing and "Missing" or nil)
                row:Show()
            end
        end
        buffLbl:SetText(("WORLD BUFFS  \194\183  %d/%d HELD"):format(held, shown))

        -- Raid tally line.
        local list = Detail.RaidTally(rec, e)
        local parts = {}
        for _, r in ipairs(list) do
            parts[#parts + 1] = Dd.Colored(r.key, r.locked and "text" or "faint")
        end
        tallyFS:SetText(table.concat(parts, "  "))

        -- Telemetry (chrono / hearth item icons + colored state value). The icon desats
        -- while on cooldown (mirrors the card stack); the tooltip carries the state.
        local chronoRem = Dd.DecayRemaining(rec.itemCooldown, rec.lastDataUpdate, e)
        if rec.chronoboonActive then
            chronoVal:SetText("BOON"); chronoVal:SetTextColor(UI.Color((rec.boonCount or 0) == 0 and "danger" or "ok"))
            D.chronoIcon.icon:SetDesaturated(false)
            D.chronoIcon._state = ("Booned \194\183 %d in bags"):format(rec.boonCount or 0); D.chronoIcon._stateTok = "ok"
        elseif chronoRem > 0 then
            chronoVal:SetText(Dd.FormatDuration(chronoRem)); chronoVal:SetTextColor(UI.Color("warn"))
            D.chronoIcon.icon:SetDesaturated(true)
            D.chronoIcon._state = "Cooldown " .. Dd.FormatDuration(chronoRem); D.chronoIcon._stateTok = "warn"
        else
            chronoVal:SetText("Ready"); chronoVal:SetTextColor(UI.Color("ok"))
            D.chronoIcon.icon:SetDesaturated(false)
            D.chronoIcon._state = "Ready"; D.chronoIcon._stateTok = "ok"
        end
        local hearthRem = Dd.DecayRemaining(rec.hearthstoneCD, rec.lastDataUpdate, e)
        if hearthRem > 0 then
            hearthVal:SetText(Dd.FormatDuration(hearthRem)); hearthVal:SetTextColor(UI.Color("warn"))
            D.hearthIcon.icon:SetDesaturated(true)
            D.hearthIcon._state = "Cooldown " .. Dd.FormatDuration(hearthRem); D.hearthIcon._stateTok = "warn"
        else
            hearthVal:SetText("Ready"); hearthVal:SetTextColor(UI.Color("ok"))
            D.hearthIcon.icon:SetDesaturated(false)
            D.hearthIcon._state = "Ready"; D.hearthIcon._stateTok = "ok"
        end

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

local function testDMFParenthetical(fails)
    local base = 1000000
    local t, tok = Detail.DMFParenthetical({ dmfCooldownActive = false }, base)
    if t ~= "READY" or tok ~= "ok" then fails[#fails + 1] = "DMF not-CD should be READY/ok" end
    local rec = { dmfCooldownActive = true, dmfCooldown = { offlineSince = base } }
    t, tok = Detail.DMFParenthetical(rec, base + 3600)
    if tok ~= "danger" or t == "on CD" then fails[#fails + 1] = "DMF mid-CD should be a red duration" end
    t, tok = Detail.DMFParenthetical(rec, base + 9 * 3600)
    if t ~= "on CD" or tok ~= "danger" then fails[#fails + 1] = "DMF elapsed should be on CD/danger" end
end

local function testBuffMatrix(fails)
    local D = ns.Dashboard
    if not (D and D.AURA_META) then fails[#fails + 1] = "Dashboard.AURA_META unavailable"; return end
    local savedGFS = ns.Store and ns.Store.GetFactionSettings
    ns.Store = ns.Store or {}
    ns.Store.GetFactionSettings = function()
        return { auraOpts = {
            rend  = { required = { WARRIOR = true }, optional = {} },
            dmtSP = { required = {}, optional = { MAGE = true } },
            thresholds = {},
        } }
    end
    local BOON = (ns.Store.AURA_SOURCE and ns.Store.AURA_SOURCE.BOON) or 2
    local e = 1000000
    local function slotOf(key) for s, m in pairs(D.AURA_META) do if m.key == key then return s end end end
    local onySlot, rendSlot, spSlot, boonSlot = slotOf("ony"), slotOf("rend"), slotOf("dmtsp"), slotOf("boon")

    local rec = { classTag = "WARRIOR", auraStates = { [onySlot] = { duration = 3600 } } }
    local st = Detail.BuffTileState(onySlot, rec, "Horde", e)
    if not (st.shown and st.calm and not st.missing) then fails[#fails + 1] = "owned healthy buff should be shown+calm" end

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
    st = Detail.BuffTileState(boonSlot, { classTag = "MAGE", auraStates = {} }, "Horde", e)
    if st.shown then fails[#fails + 1] = "absent tail slot (boon) should collapse (hidden)" end

    if ns.Store then ns.Store.GetFactionSettings = savedGFS end
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
    local e = 1000000
    local rec = { raidLockouts = { MC = e + 3600, BWL = e - 10, Ony = e + 7200 } }
    local list, locked, open = Detail.RaidTally(rec, e)
    if #list ~= #TALLY_ORDER then fails[#fails + 1] = "tally should list all 7 raids" end
    if locked ~= 2 then fails[#fails + 1] = "expected 2 locked (MC, Ony), got " .. locked end
    if open ~= 5 then fails[#fails + 1] = "expected 5 open, got " .. open end
end

-- Row-list STATUS matrix (owner round-3): map a BuffTileState result -> (text, tok).
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
    -- missing DMF keeps its re-acquire state (durText/durTok), NOT "Missing"
    t, tok = Detail.RowStatus({ shown = true, missing = true, durText = "READY", durTok = "ok", tint = "danger" }, true)
    ck(t == "READY" and tok == "ok", "missing DMF -> READY/ok (re-acquire, not 'Missing')")
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
    -- BrightClass with a RESOLVABLE class color (stub the settings so ClassColor never
    -- reaches its UI.Color fallback) must return 3 numbers — the exact crash path.
    local savedGS = ns.Store and ns.Store.GetSettings
    ns.Store = ns.Store or {}
    ns.Store.GetSettings = function() return { classColors = { WARRIOR = "c69b6d" } } end
    local r, g, bl = Detail.BrightClass("WARRIOR")
    ck(type(r) == "number" and type(g) == "number" and type(bl) == "number",
        ("BrightClass must return 3 numbers (no and-chain truncation), got %s/%s/%s")
        :format(type(r), type(g), type(bl)))
    ns.Store.GetSettings = savedGS
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

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("detail", function(verbose)
        local cases = {
            { name = "dmf parenthetical",   fn = testDMFParenthetical },
            { name = "buff display matrix", fn = testBuffMatrix },
            { name = "caption compact",     fn = testCaptionCompact },
            { name = "raid tally",          fn = testRaidTally },
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
