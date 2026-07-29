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
local BUFF_COLS = 3           -- buff grid columns
local BUFF_GAP  = 6
local BUFF_TILE = 20          -- detail buff tile edge (mockup .ct-tile.big)
local BUFF_CELL_H = 24
local TILE_RIM  = "controlBorder"

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

-- microLabel eyebrow (ARIALN, uppercase, faint) — the control-panel section label.
local function microLabel(parent, text)
    local l = fstr(parent, "microLabel")
    l:SetTextColor(UI.Color("faint"))
    if text then l:SetText(text) end
    return l
end

-- A framed buff tile (icon inside a flat inset square) reused across the grid.
local function makeBuffCell(parent)
    local cell = CreateFrame("Frame", nil, parent)
    cell:SetHeight(BUFF_CELL_H)
    -- Flat inset backing (mockup .wbcell: inset fill + border).
    local box = CreateFrame("Frame", nil, cell, "BackdropTemplate")
    box:SetAllPoints(cell)
    UI.Skin(box, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("border"))
    end)
    cell.box = box
    -- The icon tile (its own bordered square so the missing edge reads).
    local tile = CreateFrame("Frame", nil, cell, "BackdropTemplate")
    tile:SetSize(BUFF_TILE, BUFF_TILE)
    tile:SetPoint("LEFT", cell, "LEFT", 3, 0)
    local ic = tile:CreateTexture(nil, "ARTWORK")
    ic:SetPoint("TOPLEFT", tile, "TOPLEFT", 1, -1)
    ic:SetPoint("BOTTOMRIGHT", tile, "BOTTOMRIGHT", -1, 1)
    ic:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    tile.icon = ic
    cell.tile = tile
    cell.name = fstr(cell, "small"); cell.name:SetPoint("LEFT", tile, "RIGHT", 6, 0)
    cell.name:SetWordWrap(false)
    cell.dur = fstr(cell, "numeral", "RIGHT"); cell.dur:SetPoint("RIGHT", cell, "RIGHT", -6, 0)
    cell:EnableMouse(true)
    cell:SetScript("OnEnter", function(self)
        if not self._tipFull then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(self._tipName or "", UI.Color("text"))
        GameTooltip:AddLine(self._tipFull, UI.Color("muted"))
        GameTooltip:Show()
    end)
    cell:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return cell
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
    local statusDot = header:CreateTexture(nil, "OVERLAY")
    statusDot:SetSize(8, 8); statusDot:SetPoint("RIGHT", statusFS, "LEFT", -6, 0)
    D.nameFS, D.subFS, D.statusFS, D.statusDot = nameFS, subFS, statusFS, statusDot

    -- Header bottom hairline (one sharp rule, §9 UI.Hairline).
    local hrule = UI.Hairline(parent, { token = "border" })
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

    D._cells = {}
    for i = 1, 10 do D._cells[i] = makeBuffCell(leftCol) end

    -- Right column (fixed 214): tally · cooldowns · note · actions.
    local rightCol = CreateFrame("Frame", nil, parent)
    rightCol:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -PAD_H, gridTop)
    rightCol:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -PAD_H, PAD_V)
    rightCol:SetWidth(COL_R_W)
    D.rightCol = rightCol

    local raidLbl = microLabel(rightCol, "RAID LOCKOUTS")
    raidLbl:SetPoint("TOPLEFT", rightCol, "TOPLEFT", 0, 0)
    local tallyFS = fstr(rightCol, "numeral"); tallyFS:SetPoint("TOPLEFT", raidLbl, "BOTTOMLEFT", 0, -6)
    tallyFS:SetPoint("RIGHT", rightCol, "RIGHT", 0, 0); tallyFS:SetJustifyH("LEFT"); tallyFS:SetWordWrap(true)
    D.tallyFS = tallyFS

    local cdLbl = microLabel(rightCol, "COOLDOWNS")
    cdLbl:SetPoint("TOPLEFT", tallyFS, "BOTTOMLEFT", 0, -12)
    -- Two telemetry columns (chrono / hearth): microLabel key + outlined numeral.
    local function teleCol(anchorLeft, x)
        local c = CreateFrame("Frame", nil, rightCol)
        c:SetSize(96, 34)
        c:SetPoint("TOPLEFT", anchorLeft, x and "TOPLEFT" or "TOPLEFT", x or 0, x and 0 or -6)
        c.k = fstr(c, "microLabel"); c.k:SetPoint("TOPLEFT", c, "TOPLEFT", 0, 0); c.k:SetTextColor(UI.Color("faint"))
        c.v = fstr(c, "numeral"); c.v:SetPoint("TOPLEFT", c, "TOPLEFT", 0, -13)
        return c
    end
    local chronoCol = teleCol(cdLbl); chronoCol.k:SetText("CHRONO")
    local hearthCol = CreateFrame("Frame", nil, rightCol); hearthCol:SetSize(96, 34)
    hearthCol:SetPoint("TOPLEFT", chronoCol, "TOPRIGHT", 14, 0)
    hearthCol.k = fstr(hearthCol, "microLabel"); hearthCol.k:SetPoint("TOPLEFT", hearthCol, "TOPLEFT", 0, 0)
    hearthCol.k:SetTextColor(UI.Color("faint")); hearthCol.k:SetText("HEARTH")
    hearthCol.v = fstr(hearthCol, "numeral"); hearthCol.v:SetPoint("TOPLEFT", hearthCol, "TOPLEFT", 0, -13)
    D.chronoCol, D.hearthCol = chronoCol, hearthCol

    local noteLbl = microLabel(rightCol, "NOTE")
    noteLbl:SetPoint("TOPLEFT", chronoCol, "BOTTOMLEFT", 0, -10)
    local noteBox = CreateFrame("EditBox", nil, rightCol, "BackdropTemplate")
    noteBox:SetPoint("TOPLEFT", noteLbl, "BOTTOMLEFT", 0, -5)
    noteBox:SetPoint("RIGHT", rightCol, "RIGHT", 0, 0)
    noteBox:SetHeight(22); noteBox:SetAutoFocus(false)
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

    -- Action chips (Invite + Cancel buffs), pinned to the column bottom. (Invite is
    -- the mockup's accent chip; the kit exposes normal/quiet/danger variants, so we
    -- use "normal" and let the button's own accent-on-hover carry emphasis.)
    local function chip(text, accent, onClick)
        local b = UI.MakeButton(rightCol, {
            text = text, variant = "normal",
            width = accent and 84 or 96, height = 24, onClick = onClick,
        })
        return b
    end
    local inviteBtn = chip("Invite", true, function()
        if D._current and C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(D._current) end
    end)
    inviteBtn:SetPoint("BOTTOMLEFT", rightCol, "BOTTOMLEFT", 0, 0)
    local cancelBtn = chip("Cancel buffs", false, function()
        if ns.HUD and ns.HUD.ShowCancelBuffs then ns.HUD.ShowCancelBuffs()
        else ns:Print("Cancel-Buffs popup arrives in a later update.") end
    end)
    cancelBtn:SetPoint("BOTTOMLEFT", inviteBtn, "BOTTOMRIGHT", 8, 0)
    D.inviteBtn, D.cancelBtn = inviteBtn, cancelBtn

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

        -- Header.
        nameFS:SetText(Dd.ColoredName(entry.nameRealm, rec.classTag))
        local acct = (entry.aid and entry.aid ~= "" and ("#" .. entry.aid)) or ""
        subFS:SetText(("Level %s %s  %s"):format(rec.level or 60, rec.className or rec.classTag or "?", acct))
        local online = entry.online
        statusDot:SetColorTexture(UI.Color(online and "ok" or "faint"))
        statusFS:SetText((online and "ONLINE" or "OFFLINE") .. "  \194\183  " .. Dd.FreshnessText(rec.lastDataUpdate))
        statusFS:SetTextColor(UI.Color("muted"))

        -- Buff grid (3-col flow of the SHOWN tiles; §5a lit/desat).
        local order = Dd.AURA_DISPLAY_ORDER or {}
        local shown, held = 0, 0
        local colW = (leftCol:GetWidth() - (BUFF_COLS - 1) * BUFF_GAP) / BUFF_COLS
        if colW < 1 then colW = 96 end
        local gy = 20   -- below the eyebrow label
        local idx = 0
        for _, cell in ipairs(D._cells) do cell:Hide() end
        for _, slot in ipairs(order) do
            local s = Detail.BuffTileState(slot, rec, faction, e)
            if s.shown then
                idx = idx + 1
                shown = shown + 1
                if not s.missing then held = held + 1 end
                local cell = D._cells[idx]
                local col = (idx - 1) % BUFF_COLS
                local row = math.floor((idx - 1) / BUFF_COLS)
                cell:ClearAllPoints()
                cell:SetPoint("TOPLEFT", leftCol, "TOPLEFT", col * (colW + BUFF_GAP), -(gy + row * (BUFF_CELL_H + BUFF_GAP)))
                cell:SetWidth(colW)
                local meta = Dd.AURA_META[slot]
                cell.tile.icon:SetTexture(Dd.AuraIcon(slot))
                cell.tile.icon:SetDesaturated(s.missing and true or false)
                cell.tile.icon:SetAlpha(s.missing and 0.55 or 1)
                cell.tile:SetBackdrop(UI.FLAT_BACKDROP)
                cell.tile:SetBackdropColor(UI.Color("inset"))
                cell.tile:SetBackdropBorderColor(UI.Color(s.missing and s.tint or (s.boon and "ok" or TILE_RIM)))
                cell.name:SetText(meta.short or "?")
                cell.name:SetTextColor(UI.Color(s.missing and "faint" or "muted"))
                cell.dur:SetText(s.durText or (s.missing and "\226\128\148" or ""))
                cell.dur:SetTextColor(UI.Color(s.durTok or "muted"))
                cell._tipName = meta.name
                cell._tipFull = s.fullText or (s.missing and "Missing" or nil)
                cell:Show()
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

        -- Telemetry (chrono / hearth). Ready = green; on CD = numeral countdown.
        local chronoRem = Dd.DecayRemaining(rec.itemCooldown, rec.lastDataUpdate, e)
        if rec.chronoboonActive then
            chronoCol.v:SetText("BOON"); chronoCol.v:SetTextColor(UI.Color((rec.boonCount or 0) == 0 and "danger" or "ok"))
        elseif chronoRem > 0 then
            chronoCol.v:SetText(Dd.FormatDuration(chronoRem)); chronoCol.v:SetTextColor(UI.Color("warn"))
        else
            chronoCol.v:SetText("Ready"); chronoCol.v:SetTextColor(UI.Color("ok"))
        end
        local hearthRem = Dd.DecayRemaining(rec.hearthstoneCD, rec.lastDataUpdate, e)
        if hearthRem > 0 then
            hearthCol.v:SetText(Dd.FormatDuration(hearthRem)); hearthCol.v:SetTextColor(UI.Color("warn"))
        else
            hearthCol.v:SetText("Ready"); hearthCol.v:SetTextColor(UI.Color("ok"))
        end

        -- Note.
        if not noteBox:HasFocus() then noteBox:SetText(noteGet(entry.nameRealm) or "") end

        -- Invite only enabled for a different, online character (self-invite is inert).
        local canInvite = online and not (entry.isSelf)
        if inviteBtn.SetEnabledState then inviteBtn:SetEnabledState(canInvite) end
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

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("detail", function(verbose)
        local cases = {
            { name = "dmf parenthetical",   fn = testDMFParenthetical },
            { name = "buff display matrix", fn = testBuffMatrix },
            { name = "caption compact",     fn = testCaptionCompact },
            { name = "raid tally",          fn = testRaidTally },
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
