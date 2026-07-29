-- Daseeki Nexus — ui_ledgerpage.lua
-- The OPEN LEDGER PAGE (BRAND_SPEC §7 open-entry): one character's full ledger,
-- rendered IN PLACE of its register row (row hides while open, returns on close).
-- WAVE R1-B. Sibling R1-A owns ui_roster.lua (the register/grid engine); this file
-- NEVER touches it — it codes against the ns.Roster contract, guarded so it parses
-- and self-tests green even before ui_roster.lua exists in the tree.
--
-- Clean-room build: no third-party code or identifiers. No ShadowNetwork /
-- NovaWorldBuffs source was read while authoring this file.
--
-- ── EXTERNAL API CATALOG (every symbol this file consumes, + its source) ────────
--   Core Phase-0 kit (Daseeki-Core/ledgerkit.lua, published R1 surface):
--     UI.Animate.ScaleReveal / .FadeOut / .Stop     — 120ms reveal (page frame ONLY)
--     UI.Hairline(parent,opts)                       — 1px pixel-snapped rule
--     UI.PaintLedgerGround(frame,opts)               — grain+vignette+keyline (bg layers)
--   DaseekiUI framework (Daseeki-Core/daseekiui.lua + theme.lua):
--     UI.FlatFrame / UI.Skin / UI.Color / UI.Token / UI.MakeButton / UI.FLAT_BACKDROP
--     UI.fonts.{body,muted,small,microLabel,numeral}
--   Nexus shared model (ui_shell.lua ns.Dashboard — loads BEFORE this file):
--     Dashboard.AURA_META / AURA_DISPLAY_ORDER / AuraIcon(slot)
--     Dashboard.AuraRequirement / ClassRuleState / GetThreshold / AuraColorToken
--     Dashboard.DecayRemaining(stored,lastUpdate,nowE)  — reused decay helper
--     Dashboard.FormatDuration / ColoredName / Colored / HexColor / Now
--     Dashboard.RAID_FULLNAME / FreshnessText / IsOnline / FactionCrest / MakeDiamond
--   Store (store.lua):
--     ns.Store.GetNote / SetNote(nameRealm[,text])
--     ns.Store.GetData()          — record lookup by nameRealm
--     ns.Store.AURA_SOURCE.BOON   — (Boon) source sentinel
--     ns.Store.DMFCooldownRemaining(rec,nowE)  — preferred DMF-CD accessor (fallback below)
--   Engine bus (core.lua):  ns:On(name,fn) / ns:Fire(name,...)
--   R1-A roster contract (ns.Roster, guarded):
--     Roster.HostOpenEntry(nameRealm, pageFrame, pageHeight) / Roster.ReleaseOpenEntry()
--     event "ROSTER_ROW_CLICKED"(nameRealm, rowFrame)
--   Blizzard:  C_PartyInfo.InviteUnit(nameRealm) · InCombatLockdown() · UISpecialFrames
--   Cancel-buffs secure popup launcher (hud.lua):  ns.HUD.ShowCancelBuffs()
--
-- ── BRAND_SPEC SELF-AUDIT ───────────────────────────────────────────────────────
--   §3 fonts: names/values = FRIZQT (body) class-colored, never MORPHEUS; eyebrows =
--     ARIALN microLabel (uppercased by caller); numerals = ARIALN+OUTLINE. No <16 MORPHEUS.
--   §4/§5 diamond budget: exactly ONE diamond on the page — the wax seal (online=lit
--     brand / offline=idle). Buff tiles are plain SQUARE icon tiles (never masked-diamond,
--     never repeated diamonds). Raid tally = ruled text initials, NO raid diamonds (§7 L3).
--   §5 attention inversion: owned+healthy buff = calm idle tile; only missing/expiring tints.
--   §6 copy: plain + concise ("4 held · 5 missing", "Updated 2m ago", "Invite", "Cancel buffs").
--   §8 interaction: reveal ≤120ms (page frame only); WoW-native top-right ✕ + ESC(UISpecialFrames)
--     + GameTooltip; single-character Invite is a plain click (NOT mass-invite). ONE hairline (header rule).

local ADDON, ns = ...
local UI = DaseekiUI

local LedgerPage = {}
ns.LedgerPage = LedgerPage

-- ── layout tokens ───────────────────────────────────────────────────────────────
local PAD        = 12
local MAIN_W     = 300          -- left column inner width (tiles wrap within it)
local SIDE_W     = 172          -- right column inner width
local COL_GAP    = 16
local DESIGN_W   = PAD + MAIN_W + COL_GAP + SIDE_W + PAD   -- 512
local TILE       = 34
local TILE_GAP   = 6
local TILE_LABEL = 13           -- duration line height under a tile
local ROW_GAP    = 8
local STALE_SECS = 30 * 60      -- ink cools past this (freshness)

-- Open-page raid tally order + labels (BRAND_SPEC §7 L3: MC BWL ZG AQ40 Naxx Ony AQ20;
-- keys match Store.RAID_KEYS). Locked = bold cream, open = faint. No raid diamonds.
local TALLY_ORDER = { "MC", "BWL", "ZG", "AQ40", "Naxx", "Ony", "AQ20" }

local function Dash() return ns.Dashboard end
local function nowE() local D = Dash(); return (D and D.Now and D.Now()) or (GetServerTime and GetServerTime()) or (time and time()) or 0 end

-- ════════════════════════════════════════════════════════════════════════════
--  PURE DISPLAY LOGIC  (frame-free → fully unit-testable under the headless harness)
-- ════════════════════════════════════════════════════════════════════════════

-- DMF cooldown remaining (mirrors ui_shell's private helper; prefers the Store
-- accessor if present, else the 8h resting-offline auto-clear rule). ⚠ duplicated
-- 8h constant — clean end state is Store.DMFCooldownRemaining everywhere.
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

-- DMF READY / remaining-CD parenthetical (load-bearing; mirrors ui_shell 1698-1708).
--   not on cooldown            -> "READY", "ok"     (green)
--   on cooldown, rem > 0       -> "<dur>", "danger" (red)
--   on cooldown, rem == 0      -> "on CD", "danger" (red)
function LedgerPage.DMFParenthetical(rec, e)
    local D = Dash()
    if not rec.dmfCooldownActive then return "READY", "ok" end
    local rem = dmfCooldownRemaining(rec, e)
    if rem > 0 then return (D and D.FormatDuration(rem)) or tostring(rem), "danger" end
    return "on CD", "danger"
end

-- Display state for one buff slot (attention-inverted). Returns a table:
--   { shown, slot, missing, boon, calm, tint, durText, durTok, spellID }
-- shown=false  -> hide the tile (ignored class-rule slot / collapsing tail slot, absent).
-- Mirrors ui_shell's buff-row logic: class-rule severity via AuraRequirement,
-- (Boon) via Store.AURA_SOURCE.BOON, threshold color via AuraColorToken, and the
-- DMF slot's READY/CD parenthetical folded onto the tile.
function LedgerPage.BuffTileState(slot, rec, faction, e)
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
        local tok
        if booned then
            tok = "ok"
        else
            local th = D.GetThreshold(faction, meta.thresholdKey)
            tok = D.AuraColorToken(st.duration, th)
        end
        local calm = (tok == "ok")               -- owned + healthy/boon = calm idle tile
        local durText = D.FormatDuration(st.duration) .. (booned and " (Boon)" or "")
        return { shown = true, slot = slot, missing = false, boon = booned,
                 calm = calm, tint = tok, durText = durText, durTok = tok, spellID = meta.spellID }
    end

    -- Absent DMF still renders, surfacing its re-acquire window (READY / on-CD).
    if isDMF then
        local par, ptok = LedgerPage.DMFParenthetical(rec, e)
        return { shown = true, slot = slot, missing = true, boon = false, calm = false,
                 tint = ptok, durText = "(" .. par .. ")", durTok = ptok, spellID = meta.spellID }
    end

    -- Missing but applicable: required = danger, optional = warn (attention pops).
    local tok = (requirement == "optional") and "warn" or "danger"
    return { shown = true, slot = slot, missing = true, boon = false, calm = false,
             tint = tok, durText = nil, durTok = tok, spellID = meta.spellID }
end

-- Raid tally rows + counts. locked when expiry > now.
--   -> list { {key, full, locked, remaining} }, lockedN, openN
function LedgerPage.RaidTally(rec, e)
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
function LedgerPage.Resolve(nameRealm)
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
--  STATE MACHINE  (one-open-max; frame-free so it drives green with no DaseekiUI)
-- ════════════════════════════════════════════════════════════════════════════
LedgerPage.openKey = nil

function LedgerPage.GetOpen() return LedgerPage.openKey end

-- Release the current open page (restore the register row). Guarded against the
-- OnHide → Close re-entrancy the async fade-out would otherwise trigger.
function LedgerPage._release()
    if LedgerPage._closing then return end
    LedgerPage._closing = true
    if ns.Roster and ns.Roster.ReleaseOpenEntry then ns.Roster.ReleaseOpenEntry() end
    local f = LedgerPage.frame
    if f then
        if UI and UI.Animate then UI.Animate.FadeOut(f) else f:Hide() end
    end
    LedgerPage._closing = false
end

function LedgerPage.Close()
    if not LedgerPage.openKey then return end
    LedgerPage._release()
    LedgerPage.openKey = nil
end

-- Open a character's page. Clicking the OPEN character closes; clicking ANOTHER
-- switches (close previous + open new) — one page open at a time, always.
function LedgerPage.Open(nameRealm)
    if not nameRealm then return end
    if LedgerPage.openKey == nameRealm then LedgerPage.Close(); return end
    if LedgerPage.openKey then LedgerPage._release() end   -- one-open-max
    LedgerPage.openKey = nameRealm
    LedgerPage._render(nameRealm)
end

-- ESC / top-right ✕ path. Kept separate so the headless test can drive it.
function LedgerPage._handleHide()
    if LedgerPage._closing then return end
    if LedgerPage.openKey then LedgerPage.Close() end
end

-- Render (visuals only): builds the pooled frame on demand (never in combat),
-- repaints values in place, hosts into the roster slot, and reveals ≤120ms.
-- If the frame can't exist yet (combat lockdown / Core absent) the state is still
-- tracked and visuals defer — the state machine never depends on a live frame.
function LedgerPage._render(nameRealm)
    local f = LedgerPage.EnsureFrame()
    if not f then return end
    local h = LedgerPage.Populate(nameRealm) or f.uiHeight or 0
    if ns.Roster and ns.Roster.HostOpenEntry then
        ns.Roster.HostOpenEntry(nameRealm, f, h)
    end
    if UI and UI.Animate then UI.Animate.ScaleReveal(f) else f:Show() end
end

-- ════════════════════════════════════════════════════════════════════════════
--  FRAME BUILD  (ONE persistent pooled frame, built once out of combat)
-- ════════════════════════════════════════════════════════════════════════════
function LedgerPage.EnsureFrame()
    if LedgerPage.frame then return LedgerPage.frame end
    if not UI then return nil end                                   -- Core absent (harness)
    if InCombatLockdown and InCombatLockdown() then return nil end  -- never build in lockdown
    LedgerPage.frame = LedgerPage.Build()
    return LedgerPage.frame
end

local function microFS(parent)
    local t = parent:CreateFontString(nil, "OVERLAY")
    t:SetFontObject(UI.fonts.microLabel or UI.fonts.small)
    return t
end
local function numFS(parent)
    local t = parent:CreateFontString(nil, "OVERLAY")
    t:SetFontObject(UI.fonts.numeral or UI.fonts.body)
    return t
end

-- Build the singleton page frame + its pooled children. No per-open allocation.
function LedgerPage.Build()
    local f = UI.FlatFrame(UIParent, "raised", "border")
    f:SetSize(DESIGN_W, 120)
    f:Hide()
    UI.PaintLedgerGround(f, { grainToken = "raised", keyline = false })

    -- WoW-native ESC close + a discoverable top-right ✕ (§8).
    f:SetFrameStrata("HIGH")
    local GNAME = "DaseekiNexusLedgerPage"
    _G[GNAME] = f
    if type(UISpecialFrames) == "table" then
        local seen = false
        for _, n in ipairs(UISpecialFrames) do if n == GNAME then seen = true break end end
        if not seen then table.insert(UISpecialFrames, GNAME) end
    end
    f:SetScript("OnHide", function() LedgerPage._handleHide() end)

    local closeX = CreateFrame("Button", nil, f)
    closeX:SetSize(18, 18)
    closeX:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)
    local cxT = closeX:CreateFontString(nil, "OVERLAY"); cxT:SetFontObject(UI.fonts.body)
    cxT:SetPoint("CENTER"); cxT:SetText("x")
    UI.Skin(closeX, function() cxT:SetTextColor(UI.Color("muted")) end)
    closeX:SetScript("OnEnter", function() cxT:SetTextColor(UI.Color("danger")) end)
    closeX:SetScript("OnLeave", function() cxT:SetTextColor(UI.Color("muted")) end)
    closeX:SetScript("OnClick", function() LedgerPage.Close() end)
    f.closeX = closeX

    -- Header: wax seal (THE one diamond) · faction crest · class-colored name · subhead · freshness.
    local seal = Dash().MakeDiamond(f, 12)
    seal:SetPoint("TOPLEFT", f, "TOPLEFT", PAD, -PAD - 1)
    f.seal = seal

    local crest = f:CreateTexture(nil, "ARTWORK")
    crest:SetSize(15, 15)
    crest:SetPoint("LEFT", seal, "RIGHT", 7, 0)
    f.crest = crest

    local nameFS = f:CreateFontString(nil, "OVERLAY")
    nameFS:SetFontObject(UI.fonts.body)                 -- FRIZQT class-colored, never MORPHEUS (§3)
    nameFS:SetPoint("LEFT", crest, "RIGHT", 7, 0)
    f.nameFS = nameFS

    local freshFS = numFS(f)
    freshFS:SetPoint("RIGHT", closeX, "LEFT", -8, 0)
    freshFS:SetJustifyH("RIGHT")
    f.freshFS = freshFS

    local subFS = f:CreateFontString(nil, "OVERLAY")
    subFS:SetFontObject(UI.fonts.small)                 -- "Level 60 Warlock · account A1 · online"
    subFS:SetPoint("TOPLEFT", seal, "BOTTOMLEFT", 0, -5)
    subFS:SetPoint("RIGHT", f, "RIGHT", -PAD, 0)
    subFS:SetJustifyH("LEFT")
    f.subFS = subFS

    -- ONE hairline: the header rule (§8 one-per-section).
    local rule = UI.Hairline(f, { token = "border" })
    rule:SetPoint("TOPLEFT", subFS, "BOTTOMLEFT", 0, -6)
    rule:SetPoint("TOPRIGHT", f, "TOPRIGHT", -PAD, 0)
    f.rule = rule

    -- LEFT column: World-buffs eyebrow + tile grid + Note.
    local bEyebrow = microFS(f)
    bEyebrow:SetPoint("TOPLEFT", rule, "BOTTOMLEFT", 0, -8)
    bEyebrow:SetText("WORLD BUFFS")
    f.bEyebrow = bEyebrow
    local bSay = microFS(f)
    bSay:SetPoint("LEFT", bEyebrow, "RIGHT", 8, 0)
    f.bSay = bSay

    f._tileHost = CreateFrame("Frame", nil, f)
    f._tileHost:SetPoint("TOPLEFT", bEyebrow, "BOTTOMLEFT", 0, -6)
    f._tileHost:SetSize(MAIN_W, TILE + TILE_LABEL)

    -- Buff tile pool (10 slots). A tile = square bg + real spell icon + border + dur line.
    f.tiles = {}
    for i = 1, 10 do
        local t = CreateFrame("Frame", nil, f._tileHost, "BackdropTemplate")
        t:SetSize(TILE, TILE)
        t.icon = t:CreateTexture(nil, "ARTWORK")
        t.icon:SetPoint("TOPLEFT", t, "TOPLEFT", 2, -2)
        t.icon:SetPoint("BOTTOMRIGHT", t, "BOTTOMRIGHT", -2, 2)
        t.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        t.dur = numFS(t)
        t.dur:SetPoint("TOP", t, "BOTTOM", 0, -2)
        t.dur:SetJustifyH("CENTER")
        t:EnableMouse(true)
        t:SetScript("OnEnter", function(self)
            if not self._name then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(self._name)
            if self._tipLine then GameTooltip:AddLine(self._tipLine, 0.66, 0.61, 0.52) end
            GameTooltip:Show()
        end)
        t:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.tiles[i] = t
    end

    -- Note label + inline edit box (Store.GetNote/SetNote).
    local noteLbl = microFS(f)
    noteLbl:SetText("NOTE")
    f.noteLbl = noteLbl
    local noteBox = CreateFrame("EditBox", nil, f, "BackdropTemplate")
    noteBox:SetHeight(22); noteBox:SetAutoFocus(false)
    noteBox:SetFontObject(UI.fonts.body); noteBox:SetTextInsets(8, 8, 0, 0)
    UI.Skin(noteBox, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset"))
        self:SetBackdropBorderColor(UI.Color("controlBorder"))
    end)
    noteBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    noteBox:SetScript("OnEscapePressed", function(self)
        self:SetText((ns.Store and ns.Store.GetNote and ns.Store.GetNote(LedgerPage.openKey or "")) or "")
        self:ClearFocus()
    end)
    noteBox:SetScript("OnEditFocusLost", function(self)
        if LedgerPage.openKey and ns.Store and ns.Store.SetNote then
            local txt = self:GetText()
            ns.Store.SetNote(LedgerPage.openKey, (txt ~= "" and txt) or nil)
        end
    end)
    f.noteBox = noteBox

    -- RIGHT column: raid-lockout eyebrow + big ruled tally + cooldown telemetry + actions.
    local sideX = PAD + MAIN_W + COL_GAP
    local rEyebrow = microFS(f)
    rEyebrow:SetPoint("TOPLEFT", f, "TOPLEFT", sideX, 0)   -- y re-anchored in Populate
    rEyebrow:SetText("RAID LOCKOUTS")
    f.rEyebrow = rEyebrow
    local rSay = microFS(f)
    rSay:SetPoint("LEFT", rEyebrow, "RIGHT", 8, 0)
    f.rSay = rSay

    local tallyFS = f:CreateFontString(nil, "OVERLAY")
    tallyFS:SetFontObject(UI.fonts.body)                  -- ruled initials (color per lock state)
    tallyFS:SetPoint("TOPLEFT", rEyebrow, "BOTTOMLEFT", 0, -6)
    tallyFS:SetWidth(SIDE_W); tallyFS:SetJustifyH("LEFT")
    tallyFS:SetWordWrap(true)
    tallyFS:EnableMouse(true)
    tallyFS:SetScript("OnEnter", function(self)
        if not self._tip then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        for _, ln in ipairs(self._tip) do GameTooltip:AddLine(ln[1], ln[2], ln[3], ln[4]) end
        GameTooltip:Show()
    end)
    tallyFS:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.tallyFS = tallyFS

    -- Cooldown telemetry: chrono + hearth real item icons + red remaining numerals.
    local function cdRow()
        local r = CreateFrame("Frame", nil, f)
        r:SetSize(SIDE_W, 18)
        r.icon = r:CreateTexture(nil, "ARTWORK")
        r.icon:SetSize(16, 16); r.icon:SetPoint("LEFT", r, "LEFT", 0, 0)
        r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        r.lbl = microFS(r); r.lbl:SetPoint("LEFT", r.icon, "RIGHT", 6, 0)
        r.val = numFS(r); r.val:SetPoint("RIGHT", r, "RIGHT", 0, 0); r.val:SetJustifyH("RIGHT")
        return r
    end
    f.chronoRow = cdRow(); f.chronoRow.lbl:SetText("Chrono")
    f.hearthRow = cdRow(); f.hearthRow.lbl:SetText("Hearth")
    f.shardFS   = numFS(f)                                -- warlock soul-shard parity line

    -- Actions: single-character Invite (plain click, §8) + Cancel-buffs launcher.
    f.inviteBtn = UI.MakeButton(f, { text = "Invite", variant = "normal", width = 80, height = 22,
        onClick = function()
            local key = LedgerPage.openKey
            if key and C_PartyInfo and C_PartyInfo.InviteUnit then C_PartyInfo.InviteUnit(key) end
        end })
    f.cancelBtn = UI.MakeButton(f, { text = "Cancel buffs", variant = "quiet", width = 96, height = 22,
        onClick = function()
            if ns.HUD and ns.HUD.ShowCancelBuffs then ns.HUD.ShowCancelBuffs() end
        end })

    return f
end

-- ════════════════════════════════════════════════════════════════════════════
--  POPULATE  (repaint values in place — NO rebuild; returns the page height)
-- ════════════════════════════════════════════════════════════════════════════
function LedgerPage.Populate(nameRealm)
    local f = LedgerPage.frame
    if not f then return end
    local D = Dash()
    local rec, aid = LedgerPage.Resolve(nameRealm)
    if not rec then return f.uiHeight or 120 end
    local faction = rec.faction
    local e = nowE()
    local online = D.IsOnline and D.IsOnline(rec, nameRealm)

    -- Header ---------------------------------------------------------------------
    D.SetDiamondColor(f.seal, online and "brand" or "idle")
    f.crest:SetTexture(D.FactionCrest and D.FactionCrest(faction) or nil)
    f.nameFS:SetText(D.ColoredName(nameRealm, rec.classTag))

    local lvl = rec.level and ("Level " .. rec.level .. " ") or ""
    local sub = lvl .. (rec.className or rec.classTag or "?")
        .. "  \194\183  account " .. (aid or "?")
        .. "  \194\183  " .. (online and "online" or "offline")
    if rec.pvpFlagged then sub = sub .. "  \194\183  " .. D.Colored("PvP flagged", "danger") end
    f.subFS:SetText(sub)

    -- Location + freshness on the freshness line; ink cools when stale / no data.
    local age = e - (rec.lastDataUpdate or 0)
    local stale = (not rec.lastDataUpdate) or rec.lastDataUpdate <= 0 or age > STALE_SECS
    local loc = rec.location and (rec.location .. "  \194\183  ") or ""
    f.freshFS:SetText(loc .. (D.FreshnessText and D.FreshnessText(rec.lastDataUpdate) or ""))
    f.freshFS:SetTextColor(UI.Color(stale and "faint" or "muted"))

    -- LEFT: buff tiles -----------------------------------------------------------
    local order = D.AURA_DISPLAY_ORDER or {}
    local states = {}
    for _, slot in ipairs(order) do
        local s = LedgerPage.BuffTileState(slot, rec, faction, e)
        if s.shown then states[#states + 1] = s end
    end
    local held, missing = 0, 0
    for _, s in ipairs(states) do if s.missing then missing = missing + 1 else held = held + 1 end end
    f.bSay:SetText(("%d held \194\183 %d missing"):format(held, missing))

    -- Centered wrapping tile flow within MAIN_W.
    local perRow = math.max(1, math.floor((MAIN_W + TILE_GAP) / (TILE + TILE_GAP)))
    local rowStride = TILE + TILE_LABEL + ROW_GAP
    local shownN = #states
    local rows = math.max(1, math.ceil(shownN / perRow))
    for i, t in ipairs(f.tiles) do
        local s = states[i]
        if not s then t:Hide()
        else
            t:Show()
            local idx0 = i - 1
            local row = math.floor(idx0 / perRow)
            local inRow = idx0 - row * perRow
            -- how many tiles live in THIS row (last row may be short) -> center them
            local rowCount = math.min(perRow, shownN - row * perRow)
            local rowW = rowCount * TILE + (rowCount - 1) * TILE_GAP
            local startX = math.floor((MAIN_W - rowW) / 2)
            local x = startX + inRow * (TILE + TILE_GAP)
            local y = -row * rowStride
            t:ClearAllPoints()
            t:SetPoint("TOPLEFT", f._tileHost, "TOPLEFT", x, y)
            t.icon:SetTexture(D.AuraIcon(s.slot))
            t.icon:SetDesaturated(s.missing and true or false)
            local meta = D.AURA_META[s.slot]
            t._name = meta and meta.name
            t._tipLine = s.missing and "missing" or (s.durText)
            -- attention inversion: calm owned = idle border/no-pop; else tint pops
            t:SetBackdrop(UI.FLAT_BACKDROP)
            t:SetBackdropColor(UI.Color("inset"))
            t:SetBackdropBorderColor(UI.Color(s.calm and "idle" or s.tint))
            if s.missing and not s.durText then
                t.dur:SetText("")
            else
                t.dur:SetText(s.durText or "")
                t.dur:SetTextColor(UI.Color(s.calm and "muted" or s.durTok))
            end
        end
    end
    local tileBlockH = rows * rowStride
    f._tileHost:SetHeight(tileBlockH)

    -- Note box under the tiles.
    f.noteLbl:ClearAllPoints()
    f.noteLbl:SetPoint("TOPLEFT", f._tileHost, "BOTTOMLEFT", 0, -6)
    f.noteBox:ClearAllPoints()
    f.noteBox:SetPoint("TOPLEFT", f.noteLbl, "BOTTOMLEFT", 0, -4)
    f.noteBox:SetWidth(MAIN_W)
    if not f.noteBox:HasFocus() then
        f.noteBox:SetText((ns.Store and ns.Store.GetNote and ns.Store.GetNote(nameRealm)) or "")
    end
    local mainH = (select(2, f.bEyebrow:GetCenter()) and 0 or 0)  -- (no-op; kept explicit below)
    -- main column consumed height, measured from the eyebrow down:
    local mainBlockH = 6 + tileBlockH + 6 + TILE_LABEL + 4 + 22   -- eyebrow gap + tiles + note lbl + box

    -- RIGHT: raid tally + counts + cooldowns + actions --------------------------
    local rowsList, locked, open = LedgerPage.RaidTally(rec, e)
    f.rSay:SetText(("%d locked \194\183 %d open"):format(locked, open))
    local parts, tip = {}, {}
    for _, r in ipairs(rowsList) do
        parts[#parts + 1] = D.Colored(r.key, r.locked and "text" or "faint")
        if r.locked then
            tip[#tip + 1] = { r.full .. ": locked \194\183 " .. D.FormatDuration(r.remaining), 0.9, 0.9, 0.85 }
        else
            tip[#tip + 1] = { r.full .. ": open", 0.66, 0.61, 0.52 }
        end
    end
    f.tallyFS:SetText(table.concat(parts, "  "))
    f.tallyFS._tip = tip

    -- anchor the right column's y to the buff eyebrow's y so both columns align at top
    f.rEyebrow:ClearAllPoints()
    f.rEyebrow:SetPoint("TOPLEFT", f.bEyebrow, "TOPLEFT", MAIN_W + COL_GAP, 0)

    local chronoRem = D.DecayRemaining(rec.itemCooldown, rec.lastDataUpdate, e)
    local hearthRem = D.DecayRemaining(rec.hearthstoneCD, rec.lastDataUpdate, e)
    f.chronoRow:ClearAllPoints()
    f.chronoRow:SetPoint("TOPLEFT", f.tallyFS, "BOTTOMLEFT", 0, -10)
    f.chronoRow.icon:SetTexture(D.ItemIcon(184937))
    if chronoRem > 0 then
        f.chronoRow.val:SetText(D.FormatDuration(chronoRem)); f.chronoRow.val:SetTextColor(UI.Color("danger"))
    elseif (rec.boonCount or 0) > 0 or rec.chronoboonActive then
        f.chronoRow.val:SetText(rec.chronoboonActive and "Active" or "Ready")
        f.chronoRow.val:SetTextColor(UI.Color("ok"))
    else
        f.chronoRow.val:SetText("\226\128\148"); f.chronoRow.val:SetTextColor(UI.Color("faint"))
    end
    f.hearthRow:ClearAllPoints()
    f.hearthRow:SetPoint("TOPLEFT", f.chronoRow, "BOTTOMLEFT", 0, -4)
    f.hearthRow.icon:SetTexture(D.ItemIcon(6948))
    if hearthRem > 0 then
        f.hearthRow.val:SetText(D.FormatDuration(hearthRem)); f.hearthRow.val:SetTextColor(UI.Color("danger"))
    else
        f.hearthRow.val:SetText("Ready"); f.hearthRow.val:SetTextColor(UI.Color("ok"))
    end

    local sideCursor = f.hearthRow
    if rec.classTag == "WARLOCK" then
        f.shardFS:ClearAllPoints()
        f.shardFS:SetPoint("TOPLEFT", f.hearthRow, "BOTTOMLEFT", 0, -4)
        f.shardFS:SetText("Soul shards: " .. (rec.shardCount or 0))
        f.shardFS:SetTextColor(UI.Color("muted"))
        f.shardFS:Show()
        sideCursor = f.shardFS
    else
        f.shardFS:Hide()
    end

    f.inviteBtn:ClearAllPoints()
    f.inviteBtn:SetPoint("TOPLEFT", sideCursor, "BOTTOMLEFT", 0, -10)
    f.cancelBtn:ClearAllPoints()
    f.cancelBtn:SetPoint("LEFT", f.inviteBtn, "RIGHT", 8, 0)

    -- Height = header + max(left block, right block) + pad.
    local headerH = PAD + 12 + 5 + 14 + 6 + 1 + 8   -- pad + seal + gap + subhead + gap + rule + gap
    local rightBlockH = 14 + 6 + (rows > 0 and 0 or 0)  -- eyebrow + gap
    -- right block: eyebrow(14)+gap(6)+tally(~2 lines 32)+gap(10)+chrono(18)+hearth(18)+[shard 20]+gap(10)+actions(22)
    local tallyLines = math.max(1, math.ceil(#rowsList / 5))
    local rightH = 14 + 6 + tallyLines * 16 + 10 + 18 + 4 + 18
        + (rec.classTag == "WARLOCK" and 24 or 0) + 10 + 22
    local leftH = 14 + mainBlockH
    local body = math.max(leftH, rightH)
    local H = headerH + body + PAD
    f:SetHeight(H); f.uiHeight = H
    f._shownFor = nameRealm
    return H
end

-- ════════════════════════════════════════════════════════════════════════════
--  WIRING  (top-level: subscribe only — NO frame work at file load, harness-safe)
-- ════════════════════════════════════════════════════════════════════════════

-- Roster row click / auto-open: one entry point, one-open-max enforced by Open().
if ns.On then
    ns:On("ROSTER_ROW_CLICKED", function(nameRealm) LedgerPage.Open(nameRealm) end)

    -- Live repaint in place while open (no rebuild → no scroll reset).
    local function repaint()
        if LedgerPage.openKey and LedgerPage.frame and LedgerPage.frame:IsShown() then
            LedgerPage.Populate(LedgerPage.openKey)
        end
    end
    ns:On("STATE_CHANGED",   repaint)
    ns:On("STORE_REFRESHED", repaint)
    ns:On("TIMER_UPDATED",   repaint)
    ns:On("NODE_UPDATED",    repaint)
    ns:On("CD_WARNING",      repaint)

    -- Build the singleton once, at login, out of combat (Expert-C condition 1).
    ns:On("LOGIN", function()
        if not (InCombatLockdown and InCombatLockdown()) then LedgerPage.EnsureFrame() end
    end)
end

-- If login happened in combat, build on the next combat exit.
if type(CreateFrame) == "function" then
    local driver = CreateFrame("Frame")
    if driver.RegisterEvent then
        driver:RegisterEvent("PLAYER_REGEN_ENABLED")
        driver:SetScript("OnEvent", function()
            if not LedgerPage.frame and UI then LedgerPage.EnsureFrame() end
        end)
    end
end

-- ════════════════════════════════════════════════════════════════════════════
--  SELF-TEST  (state machine · one-open-max · ESC · auto-open · DMF · buff matrix)
-- ════════════════════════════════════════════════════════════════════════════
local function testStateMachine(fails)
    -- Install a counting fake roster so host/release calls are observable, and a
    -- fake frame so _render() has visuals to drive without DaseekiUI.
    local savedRoster, savedFrame = ns.Roster, LedgerPage.frame
    local hostN, relN = 0, 0
    ns.Roster = {
        HostOpenEntry = function() hostN = hostN + 1 end,
        ReleaseOpenEntry = function() relN = relN + 1 end,
        RowPitch = function() return 26 end,
    }
    LedgerPage.frame = setmetatable({ uiHeight = 100 },
        { __index = function() return function() return false end end })
    LedgerPage.openKey = nil

    LedgerPage.Open("A-R")
    if LedgerPage.GetOpen() ~= "A-R" then fails[#fails + 1] = "Open A did not set open" end
    -- switch to B: one-open-max (previous released, exactly one open)
    LedgerPage.Open("B-R")
    if LedgerPage.GetOpen() ~= "B-R" then fails[#fails + 1] = "switch to B failed" end
    if relN < 1 then fails[#fails + 1] = "switch did not release the previous page (one-open-max)" end
    -- clicking the OPEN char closes (toggle)
    LedgerPage.Open("B-R")
    if LedgerPage.GetOpen() ~= nil then fails[#fails + 1] = "re-click open char did not close" end
    -- ESC / OnHide path
    LedgerPage.Open("C-R")
    LedgerPage._handleHide()
    if LedgerPage.GetOpen() ~= nil then fails[#fails + 1] = "ESC (_handleHide) did not close" end
    -- explicit Close is idempotent
    LedgerPage.Close()
    if LedgerPage.GetOpen() ~= nil then fails[#fails + 1] = "Close on empty broke state" end

    ns.Roster, LedgerPage.frame = savedRoster, savedFrame
    LedgerPage.openKey = nil
end

local function testAutoOpenEvent(fails)
    local savedRoster, savedFrame = ns.Roster, LedgerPage.frame
    ns.Roster = { HostOpenEntry = function() end, ReleaseOpenEntry = function() end }
    LedgerPage.frame = setmetatable({ uiHeight = 100 },
        { __index = function() return function() return false end end })
    LedgerPage.openKey = nil

    -- Roster fires the event for a click AND for auto-open (highest online / self first).
    ns:Fire("ROSTER_ROW_CLICKED", "Auto-R", nil)
    if LedgerPage.GetOpen() ~= "Auto-R" then fails[#fails + 1] = "auto-open event did not open" end
    ns:Fire("ROSTER_ROW_CLICKED", "Auto-R", nil)   -- same row -> close
    if LedgerPage.GetOpen() ~= nil then fails[#fails + 1] = "event re-click did not close" end
    ns:Fire("ROSTER_ROW_CLICKED", "Other-R", nil)  -- different row -> switch/open
    if LedgerPage.GetOpen() ~= "Other-R" then fails[#fails + 1] = "event switch did not open other" end

    LedgerPage.Close()
    ns.Roster, LedgerPage.frame = savedRoster, savedFrame
    LedgerPage.openKey = nil
end

local function testDMFParenthetical(fails)
    local base = 1000000
    -- not on cooldown -> READY / ok
    local t, tok = LedgerPage.DMFParenthetical({ dmfCooldownActive = false }, base)
    if t ~= "READY" or tok ~= "ok" then fails[#fails + 1] = "DMF not-CD should be READY/ok" end
    -- on cooldown, remaining > 0 -> duration / danger
    local rec = { dmfCooldownActive = true, dmfCooldown = { offlineSince = base } }
    t, tok = LedgerPage.DMFParenthetical(rec, base + 3600)   -- 8h clear, 1h elapsed -> 7h left
    if tok ~= "danger" or t == "on CD" then fails[#fails + 1] = "DMF mid-CD should be a red duration" end
    -- on cooldown, elapsed past the clear -> on CD / danger
    t, tok = LedgerPage.DMFParenthetical(rec, base + 9 * 3600)
    if t ~= "on CD" or tok ~= "danger" then fails[#fails + 1] = "DMF elapsed should be on CD/danger" end
end

local function testBuffMatrix(fails)
    local D = ns.Dashboard
    if not (D and D.AURA_META) then fails[#fails + 1] = "Dashboard.AURA_META unavailable"; return end
    -- Deterministic class-rule settings: rend required for WARRIOR, dmtSP optional for
    -- MAGE + ignored for ROGUE. Stub GetFactionSettings so ClassRuleState resolves.
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

    -- helper: find a slot by AURA_META key
    local function slotOf(key)
        for s, m in pairs(D.AURA_META) do if m.key == key then return s end end
    end
    local onySlot  = slotOf("ony")        -- required-by-default, has threshold
    local rendSlot = slotOf("rend")       -- class-ruled
    local spSlot   = slotOf("dmtsp")      -- class-ruled (dmtSP)
    local boonSlot = slotOf("boon")       -- tail optional (collapses when absent)

    -- owned + healthy Ony -> shown, calm, not missing
    local rec = { classTag = "WARRIOR", auraStates = { [onySlot] = { duration = 3600 } } }
    local st = LedgerPage.BuffTileState(onySlot, rec, "Horde", e)
    if not (st.shown and st.calm and not st.missing) then fails[#fails + 1] = "owned healthy buff should be shown+calm" end

    -- (Boon) source -> ok/green + boon flag + calm + "(Boon)" text
    rec.auraStates[onySlot] = { duration = 1200, source = BOON }
    st = LedgerPage.BuffTileState(onySlot, rec, "Horde", e)
    if not (st.boon and st.tint == "ok" and st.durText:find("%(Boon%)")) then
        fails[#fails + 1] = "boon buff should be ok/green with (Boon) annotation"
    end

    -- required class-rule slot MISSING (rend on WARRIOR) -> shown + danger
    local warr = { classTag = "WARRIOR", auraStates = {} }
    st = LedgerPage.BuffTileState(rendSlot, warr, "Horde", e)
    if not (st.shown and st.missing and st.tint == "danger") then
        fails[#fails + 1] = "required missing buff should be shown+danger"
    end

    -- ignored class-rule slot MISSING (dmtSP on ROGUE) -> hidden
    local rogue = { classTag = "ROGUE", auraStates = {} }
    st = LedgerPage.BuffTileState(spSlot, rogue, "Horde", e)
    if st.shown then fails[#fails + 1] = "ignored class-rule slot should collapse (hidden) when absent" end

    -- optional class-rule slot MISSING (dmtSP on MAGE) -> shown + warn
    local mage = { classTag = "MAGE", auraStates = {} }
    st = LedgerPage.BuffTileState(spSlot, mage, "Horde", e)
    if not (st.shown and st.missing and st.tint == "warn") then
        fails[#fails + 1] = "optional class-rule slot should be shown+warn when absent"
    end

    -- tail optional slot MISSING (boon) -> hidden (collapses)
    st = LedgerPage.BuffTileState(boonSlot, { classTag = "MAGE", auraStates = {} }, "Horde", e)
    if st.shown then fails[#fails + 1] = "absent tail slot (boon) should collapse (hidden)" end

    if ns.Store then ns.Store.GetFactionSettings = savedGFS end
end

local function testRaidTally(fails)
    local e = 1000000
    local rec = { raidLockouts = { MC = e + 3600, BWL = e - 10, Ony = e + 7200 } }
    local list, locked, open = LedgerPage.RaidTally(rec, e)
    if #list ~= #TALLY_ORDER then fails[#fails + 1] = "tally should list all 7 raids" end
    if locked ~= 2 then fails[#fails + 1] = "expected 2 locked (MC, Ony), got " .. locked end
    if open ~= 5 then fails[#fails + 1] = "expected 5 open, got " .. open end
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("ledgerpage", function(verbose)
        local cases = {
            { name = "state machine",     fn = testStateMachine },
            { name = "auto-open event",   fn = testAutoOpenEvent },
            { name = "dmf parenthetical", fn = testDMFParenthetical },
            { name = "buff display matrix", fn = testBuffMatrix },
            { name = "raid tally",        fn = testRaidTally },
        }
        local allPass = true
        for _, c in ipairs(cases) do
            local f2 = {}
            local ok = pcall(c.fn, f2)
            local passed = ok and #f2 == 0
            if not passed then allPass = false end
            if verbose and ns and ns.Print then
                if passed then ns:Print("  PASS ledgerpage/" .. c.name)
                elseif not ok then ns:Print("  FAIL ledgerpage/" .. c.name .. " :: error in test")
                else for _, m in ipairs(f2) do ns:Print("  FAIL ledgerpage/" .. c.name .. " :: " .. m) end end
            end
        end
        return allPass
    end)
end
