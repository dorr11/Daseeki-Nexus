-- Daseeki Nexus — hud.lua
-- On-screen HUD: pull-timer bars (+ mover mode), screen alert banner, the
-- four-channel alert dispatcher (notify/chat/flash/sound), and the Cancel
-- Buffs popup (tracked-aura grid + Chronoboon Boon/Unboon).
--
-- Clean-room build: reimplements the *functionality* of an unlicensed source
-- addon from a functional spec only. No third-party code or identifiers.
--
-- Built on Daseeki-Core's DaseekiUI (tokens/widgets/theming). Every visual
-- reads theme tokens at render and re-skins on ThemeChanged via UI.Skin.
-- No StatusBar or banner widget exists in the framework, so those primitives
-- are assembled here from CreateFrame + UI.Skin (per style-guide token rule).

local ADDON, ns = ...

local UI    = DaseekiUI      -- guaranteed present (## Dependencies: Daseeki-Core)
local Suite = DaseekiSuite   -- hub registry (guard on Suite.available before use)

local HUD = {}
ns.HUD = HUD

-- ── Pure group-assignment logic (registered ABOVE the DaseekiUI guard so the
--    regression suite runs headless) ───────────────────────────────────────────
-- A pull bar renders in the Main group (large, centered) when its buff's zone is
-- relevant OR it is imminent (remaining <= expand threshold); otherwise the Small
-- group (idle, top-right). CRITICAL (R2-c fix): a bar must NOT physically jump
-- groups mid-countdown when the expand threshold is crossed. Group assignment is
-- FROZEN and only recomputed at a STRUCTURAL event (a new bar spawns, or a bar
-- expires): HUD._AssignGroups does that recompute; reflow reads frozen groups.

-- Buffs whose stage-1 pop raises MORE THAN ONE bar — one per landing zone — so
-- bar identity has to be buff+variant or the second fire lands on the first
-- bar's refresh path and overwrites its window. Rend is the only one today
-- (Orgrimmar 6s + Barrens 17s off a single Thrall yell; Herald is 6s/6s).
-- Zone names are stored lowercased and mirror timers.lua's REND_BARS[].zone.
-- Lives up here (rather than beside BUFF_META) so the headless suite below can
-- exercise barKeyOf without DaseekiUI.
local VARIANT_ZONES = {
    rend = { ["orgrimmar"] = true, ["barrens"] = true },
}
HUD.VARIANT_ZONES = VARIANT_ZONES

-- Bar identity. Plain buffKey, EXCEPT a multi-zone buff fired for one of its
-- own known variant zones -> "buff:zone", so both landings render at once.
-- A nil/unknown zone (e.g. the /demo path) falls back to the plain key.
local function barKeyOf(buffKey, zone)
    local variants = VARIANT_ZONES[buffKey]
    if not variants then return buffKey end
    local z = (type(zone) == "string") and zone:lower() or nil
    if z and variants[z] then return buffKey .. ":" .. z end
    return buffKey
end
HUD._BarKeyOf = barKeyOf

-- Does the player's current zone sit in a bar's variant zone? The engine emits
-- the landing NAME ("Barrens") while GetRealZoneText returns the full localized
-- zone ("The Barrens"), so containment — not equality — is the honest compare.
local function zoneMatches(playerZone, variantZone)
    if not playerZone or not variantZone or variantZone == "" then return false end
    if playerZone == variantZone then return true end
    return playerZone:find(variantZone, 1, true) ~= nil
end
HUD._ZoneMatches = zoneMatches

-- Recompute each entry's group from live state. Mutates entry.group; returns a
-- key->group map. `list` = array of { key=, rem=, zoneRelevant=bool }.
function HUD._AssignGroups(list, threshold)
    local map = {}
    for _, e in ipairs(list) do
        local g = (e.zoneRelevant or (e.rem <= threshold)) and "main" or "small"
        e.group = g
        map[e.key] = g
    end
    return map
end

-- Partition by FROZEN group (ignores rem — a mid-countdown threshold crossing
-- never moves a bar). Returns mainCount, smallCount for a list of { group= }.
function HUD._PartitionFrozen(list)
    local m, s = 0, 0
    for _, e in ipairs(list) do
        if e.group == "main" then m = m + 1 else s = s + 1 end
    end
    return m, s
end

-- Group-jump regression suite (headless — no DaseekiUI needed).
ns:RegisterSelfTest("hudgroups", function(verbose)
    local pass = true
    local function check(c, m) if not c then pass = false; if verbose then ns:Print("  FAIL: " .. m) end end end
    local threshold = 10
    local a = { key = "rend", rem = 40, zoneRelevant = false }
    HUD._AssignGroups({ a }, threshold)
    check(a.group == "small", "spawn far from expand -> small")
    -- Time passes; rem crosses the threshold with NO structural event.
    a.rem = 3
    local m, s = HUD._PartitionFrozen({ a })
    check(m == 0 and s == 1, "no mid-countdown group jump (stays small)")
    -- A new bar spawns -> structural event -> re-partition allowed.
    local b = { key = "zg", rem = 40, zoneRelevant = false }
    HUD._AssignGroups({ a, b }, threshold)
    check(a.group == "main" and b.group == "small", "regroup allowed on new-bar spawn")
    -- Zone relevance forces main regardless of remaining.
    local z = { key = "onyH", rem = 999, zoneRelevant = true }
    HUD._AssignGroups({ z }, threshold)
    check(z.group == "main", "zone-relevant -> main")

    -- Bar identity = buff + variant zone.
    check(barKeyOf("rend", "Orgrimmar") == "rend:orgrimmar", "barKeyOf rend/Orgrimmar")
    check(barKeyOf("rend", "Barrens") == "rend:barrens", "barKeyOf rend/Barrens")
    check(barKeyOf("rend", nil) == "rend", "barKeyOf rend/nil -> plain key")
    check(barKeyOf("rend", "Silithus") == "rend", "barKeyOf rend/unknown zone -> plain key")
    check(barKeyOf("zg", "Orgrimmar") == "zg", "barKeyOf non-variant buff ignores zone")
    check(zoneMatches("the barrens", "barrens"), "player 'The Barrens' matches 'Barrens'")
    check(not zoneMatches("orgrimmar", "barrens"), "Orgrimmar does not match Barrens")

    -- Two concurrent Rend bars: distinct keys, and only the bar for the PLAYER's
    -- own landing zone is forced main — the other waits on the expand threshold.
    local rOrg = { key = barKeyOf("rend", "Orgrimmar"), rem = 6,  zoneRelevant = true }
    local rBar = { key = barKeyOf("rend", "Barrens"),   rem = 17, zoneRelevant = false }
    check(rOrg.key ~= rBar.key, "two Rend variants key apart (no collapse)")
    HUD._AssignGroups({ rOrg, rBar }, threshold)
    check(rOrg.group == "main" and rBar.group == "small", "Org player: Org main, Barrens small")
    -- Same pop seen from the Barrens: relevance flips, both bars still exist.
    local oOrg = { key = barKeyOf("rend", "Orgrimmar"), rem = 40, zoneRelevant = false }
    local oBar = { key = barKeyOf("rend", "Barrens"),   rem = 17, zoneRelevant = true }
    HUD._AssignGroups({ oOrg, oBar }, threshold)
    check(oBar.group == "main" and oOrg.group == "small", "Barrens player: Barrens main, Org small")
    if verbose then ns:Print("  hudgroups selftest " .. (pass and "PASS" or "FAIL")) end
    return pass
end)

-- Hard dependency guard: if Core somehow did not load, degrade to inert stubs
-- rather than erroring on every event. The toc dependency makes this defensive.
if type(UI) ~= "table" or type(UI.Color) ~= "function" then
    ns:Print("HUD disabled: DaseekiUI (Daseeki-Core) not available.")
    function HUD.ShowCancelBuffs() end
    function HUD.ShowMover() end
    function HUD.TestAlert() end
    function HUD.Alert() end
    return
end

----------------------------------------------------------------------
-- Local helpers
----------------------------------------------------------------------

local function frameClock() return (GetTime and GetTime()) or 0 end
local function lower(s) return s and s:lower() or "" end

-- Pull-bar traffic-light "warn" amber. Core now ships a `warn` theme token, so
-- prefer it (per-theme amber, re-skins on ThemeChanged). Fall back to the
-- historical literal when running against an older Core that predates the token
-- (UI.Color returns white for an unknown token, so detect presence via UI.Token
-- rather than accept a white flash).
local WARN_RGB = { 0.96, 0.76, 0.18 }
local function warnColor()
    if UI.Token and type(UI.Token("warn")) == "table" then return UI.Color("warn") end
    return WARN_RGB[1], WARN_RGB[2], WARN_RGB[3], 1
end

-- Current real-zone name, lowercased.
local function zoneNow()
    return lower(GetRealZoneText and GetRealZoneText() or "")
end

local function inRaidInstance()
    if not IsInInstance then return false end
    local inInst, instType = IsInInstance()
    return inInst and instType == "raid"
end

----------------------------------------------------------------------
-- Settings access (defensive; every read falls back to a sane default so
-- the HUD renders even before the store applies defaults).
----------------------------------------------------------------------

local function timerSettings()
    local s = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
    return (s and s.timerSettings) or {}
end

local function pullBarCfg()
    local ts = timerSettings()
    return ts.pullBar or {}
end

-- Read a pull-bar geometry field with a fallback (settings own only a single
-- pullBar block in N1; we read additive main/small keys defensively so the
-- settings agent can add them without breaking us).
local function cfg(key, default)
    local pb = pullBarCfg()
    local v = pb[key]
    if v == nil then return default end
    return v
end

local DEFAULT_PULL_WINDOW = 40   -- seconds, when a detector supplies no duration
local RECENT_EXPIRE_BLOCK = 60   -- seconds a just-expired key is blocked from restart
local RED_PULSE_AT        = 3    -- seconds remaining -> pulsing red
local MAX_BARS            = 8

----------------------------------------------------------------------
-- Buff presentation metadata (labels / icons / zone relevance)
--
-- Keys mirror Timers.BUFF_KEYS (+ battleShout, a callback-only alert key).
-- Icon paths are Blizzard built-ins (a missing path renders blank, never an
-- error) — art is cosmetic; correctness of the exact icon is not load-bearing.
----------------------------------------------------------------------

local BUFF_META = {
    -- Rend lands in BOTH Orgrimmar and the Barrens (see VARIANT_ZONES above);
    -- the Barrens entry was missing, so a Barrens waiter's non-variant Rend bar
    -- (e.g. the /demo bar) never classified "main".
    rend        = { label = "Rend",       icon = "Interface\\Icons\\Ability_Warrior_WarCry",        zones = { ["orgrimmar"] = true, ["barrens"] = true } },
    onyH        = { label = "Horde Ony",  icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",       zones = { ["orgrimmar"] = true } },
    onyA        = { label = "Ally Ony",   icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01",       zones = { ["stormwind city"] = true } },
    nefH        = { label = "Horde Nef",  icon = "Interface\\Icons\\INV_Misc_Head_Dragon_Black",    zones = { ["orgrimmar"] = true } },
    nefA        = { label = "Ally Nef",   icon = "Interface\\Icons\\INV_Misc_Head_Dragon_Black",    zones = { ["stormwind city"] = true } },
    zg          = { label = "Zandalar",   icon = "Interface\\Icons\\INV_Jewelry_Talisman_14",       zones = { ["stranglethorn vale"] = true, ["yojamba isle"] = true } },
    battleShout = { label = "Battle Shout", icon = "Interface\\Icons\\Ability_Warrior_BattleShout", zones = {} },
    -- R3: DMF alert row (item 24) + seasonal FFF slot (item 36). Non-pull buffs,
    -- so no zone relevance. Icons are cosmetic (missing path renders blank).
    dmf         = { label = "DMF",         icon = "Interface\\Icons\\INV_Misc_Ticket_Tarot_Blessings_01", zones = {} },
    fff         = { label = "FFF",         icon = "Interface\\Icons\\INV_Misc_Food_15",                   zones = {} },
}
HUD.BUFF_META = BUFF_META

local function buffLabel(k) local m = BUFF_META[k]; return m and m.label or tostring(k) end
local function buffIcon(k)  local m = BUFF_META[k]; return m and m.icon or "Interface\\Icons\\INV_Misc_QuestionMark" end
-- Zone relevance for a NON-variant bar: the player's real zone against the
-- buff's BUFF_META zone set. Exact hit first; otherwise fall back to the
-- containment compare, because a landing name can be a substring of the real
-- zone text ("barrens" vs. GetRealZoneText's "The Barrens").
local function zoneRelevant(k)
    local m = BUFF_META[k]
    if not m or not m.zones then return false end
    local here = zoneNow()
    if m.zones[here] == true then return true end
    for z, on in pairs(m.zones) do
        if on == true and zoneMatches(here, z) then return true end
    end
    return false
end

----------------------------------------------------------------------
-- Sound catalog
--
-- SOUNDKIT is a FrameXML table (not in the API catalog), so each entry is
-- guarded: play SOUNDKIT[member] when present, else the numeric fallback id.
-- The numeric ids are the authoritative SoundKit values, so a tone plays even
-- if a member name differs on 11509.  [in-game verify — owner Test buttons]
----------------------------------------------------------------------

-- Ordered list so the settings agent can build the Sound dropdown from it.
-- key doubles as the stored soundKeys value (store defaults use these keys).
HUD.SOUNDS = {
    { key = "None",               label = "None",           member = nil,                             id = nil  },
    { key = "ReadyCheck",         label = "Ready Check",     member = "READY_CHECK",                   id = 8960 },
    { key = "RaidWarning",        label = "Raid Warning",    member = "RAID_WARNING",                  id = 8959 },
    { key = "AuctionWindowOpen",  label = "Auction Open",    member = "AUCTION_WINDOW_OPEN",           id = 5274 },
    { key = "AuctionWindowClose", label = "Auction Close",   member = "AUCTION_WINDOW_CLOSE",          id = 5275 },
    { key = "TellMessage",        label = "Whisper",         member = "TELL_MESSAGE",                  id = 3081 },
    { key = "MapPing",            label = "Map Ping",        member = "MAP_PING",                      id = 3175 },
    { key = "QuestListOpen",      label = "Quest Open",      member = "IG_QUEST_LIST_OPEN",            id = 846  },
    { key = "QuestListClose",     label = "Quest Close",     member = "IG_QUEST_LIST_CLOSE",           id = 847  },
    { key = "MainMenuOpen",       label = "Menu Open",       member = "IG_MAINMENU_OPEN",              id = 850  },
    { key = "MainMenuClose",      label = "Menu Close",      member = "IG_MAINMENU_CLOSE",             id = 851  },
    { key = "CheckboxOn",         label = "Click",           member = "IG_MAINMENU_OPTION_CHECKBOX_ON", id = 856 },
    { key = "AbilityTick",        label = "Ability Tick",    member = "IG_ABILITY_PAGE_TURN",          id = 867  },
    { key = "PvPFlag",            label = "PvP Flag",        member = "PVPFLAG",                       id = 8212 },
    { key = "LootWindow",        label = "Loot Coin",       member = "LOOTWINDOWOPENEMPTY",           id = 5274 },
}

local SOUND_BY_KEY = {}
for _, s in ipairs(HUD.SOUNDS) do SOUND_BY_KEY[s.key] = s end

-- Play a tone by its stored key on the configured channel.
local VALID_CHANNELS = { Master = true, SFX = true, Music = true, Ambience = true, Dialog = true }
local function playSoundKey(key)
    local entry = SOUND_BY_KEY[key or ""]
    if not entry or not entry.id then return end   -- "None" / unknown
    local id = (SOUNDKIT and entry.member and SOUNDKIT[entry.member]) or entry.id
    local ts = timerSettings()
    local channel = ts.soundChannel
    if not VALID_CHANNELS[channel or ""] then channel = "Master" end
    if PlaySound then
        -- PlaySound(soundKitID, channel) — legacy channel-string form (runtime fact).
        PlaySound(id, channel)
    end
end

-- Which stored sound key an event type uses (soundKeys is partial in defaults).
local DEFAULT_EVENT_SOUND = {
    questHandin  = "QuestListOpen",
    pullTimer    = "RaidWarning",
    npcDied      = "TellMessage",
    npcRespawned = "TellMessage",
    cdWarning    = "AuctionWindowOpen",
    cdExpired    = "ReadyCheck",
    buffGain     = "CheckboxOn",
}
local function soundKeyForEvent(eventType)
    local ts = timerSettings()
    local sk = ts.soundKeys or {}
    return sk[eventType] or DEFAULT_EVENT_SOUND[eventType] or "RaidWarning"
end

----------------------------------------------------------------------
-- Screen alert banner — large outlined accent text, top-center, ~5s.
----------------------------------------------------------------------

local banner
local function ensureBanner()
    if banner then return banner end
    local f = CreateFrame("Frame", "DaseekiNexusBanner", UIParent)
    f:SetSize(700, 60)
    f:SetPoint("TOP", UIParent, "TOP", 0, -170)
    f:SetFrameStrata("HIGH")
    f:Hide()

    local fs = f:CreateFontString(nil, "OVERLAY")
    -- No outlined FontObject in the framework — build the outlined face here.
    fs:SetFont("Fonts\\FRIZQT__.TTF", 30, "THICKOUTLINE")
    fs:SetPoint("CENTER", f, "CENTER", 0, 0)
    fs:SetJustifyH("CENTER")
    UI.Skin(fs, function(self) self:SetTextColor(UI.Color("accent")) end)
    f._text = fs

    f._timer = 0
    -- No hard on/off: fade out over 120ms once the hold elapses (§8). A single
    -- _fading latch stops us re-triggering the fade every frame.
    f:SetScript("OnUpdate", function(self, elapsed)
        if not self:IsShown() then return end
        self._timer = self._timer - elapsed
        if self._timer <= 0 and not self._fading then
            self._fading = true
            if UI.Animate and UI.Animate.FadeOut then
                UI.Animate.FadeOut(self, 120)   -- hides OnFinished
            else
                self:Hide()
            end
        end
    end)
    banner = f
    return f
end

-- Show banner text for `hold` seconds (default 5). `colorToken` overrides accent.
-- Reveal is a 120ms grow/fade (95%->100% + fade in), never a hard pop (§8).
function HUD.ShowBanner(text, hold, colorToken)
    local f = ensureBanner()
    f._text:SetText(text or "")
    if colorToken then
        f._text:SetTextColor(UI.Color(colorToken))
    else
        f._text:SetTextColor(UI.Color("accent"))
    end
    f._timer  = hold or 5
    f._fading = false
    if UI.Animate and UI.Animate.ScaleReveal then
        UI.Animate.ScaleReveal(f, 120)   -- shows + fades/scales in
    else
        f:SetAlpha(1)
        f:Show()
    end
end

----------------------------------------------------------------------
-- Four-channel alert dispatcher
--
-- Routes a (buffKey, eventType) alert to Screen(notify) / Chat / Flash /
-- Sound per the per-event matrix, honoring raidDisable suppression and a
-- short dedup window. Public entry points: HUD.Alert (wired to engine
-- callbacks) and HUD.TestAlert (owner Test buttons; bypasses dedup + raid).
----------------------------------------------------------------------

local DEDUP_WINDOW = 3            -- seconds
local lastAlertAt = {}           -- "buff:event" -> frameClock

-- alerts matrix lookup (EVENT-MAJOR now — item 14): alerts[eventType][buffKey].
-- All-off fallback so a missing row never errors.
local function alertRow(buffKey, eventType)
    local ts = timerSettings()
    local m = ts.alerts
    local perBuff = m and m[eventType]
    local row = perBuff and perBuff[buffKey]
    return row or {}
end

local function raidDisabled(channel)
    if not inRaidInstance() then return false end
    local ts = timerSettings()
    local rd = ts.raidDisable or {}
    return rd[channel] == true
end

-- Core dispatch. opts: { test=bool } bypasses dedup + raid suppression.
local function dispatch(buffKey, eventType, message, opts)
    opts = opts or {}
    local row = alertRow(buffKey, eventType)
    local test = opts.test == true

    if not test then
        local dkey = buffKey .. ":" .. eventType
        local t = frameClock()
        if lastAlertAt[dkey] and (t - lastAlertAt[dkey]) < DEDUP_WINDOW then
            return   -- deduped
        end
        lastAlertAt[dkey] = t
    end

    message = message or (buffLabel(buffKey) .. " — " .. eventType)

    -- Master "On" toggle (settings writes row.enabled; nil = on). Test bypasses.
    if row.enabled == false and not test then return end
    -- notify -> screen banner
    if (row.notify or test) and not (not test and raidDisabled("notify")) then
        HUD.ShowBanner(message, 5, opts.colorToken)
    end
    -- chat
    if (row.chat or test) and not (not test and raidDisabled("chat")) then
        ns:Print(message)
    end
    -- flash the client taskbar icon
    if (row.flash or test) and not (not test and raidDisabled("flash")) then
        if FlashClientIcon then FlashClientIcon() end
    end
    -- sound: per-row sound KEY now (item 14). "None"/empty/false => silent.
    -- Test always previews the row's key (falling back to the event default).
    local rowSound = row.sound
    local wantSound = test or (rowSound ~= nil and rowSound ~= false
                               and rowSound ~= "None" and rowSound ~= "")
    if wantSound and not (not test and raidDisabled("sound")) then
        local key = (type(rowSound) == "string" and rowSound ~= "None" and rowSound ~= "")
                    and rowSound or soundKeyForEvent(eventType)
        playSoundKey(key)
    end
end

-- Public: fire an alert for an engine event. Safe to call from anywhere.
function HUD.Alert(buffKey, eventType, message, colorToken)
    ns:SafeCall(dispatch, buffKey, eventType, message, { colorToken = colorToken })
end

-- Public: owner Test hook — always previews every configured channel for the
-- row, ignoring dedup and raid suppression so the owner sees the real config.
function HUD.TestAlert(buffKey, eventType)
    buffKey   = buffKey or "rend"
    eventType = eventType or "pullTimer"
    local msg = buffLabel(buffKey) .. " — test " .. eventType
    ns:SafeCall(dispatch, buffKey, eventType, msg, { test = true })
end

----------------------------------------------------------------------
-- Pull-timer bars
--
-- A bar is built on UI.MakeStatusBar (Core kit): interpolated drain fill + a
-- spark riding the fill edge (the HUD's only continuous motion, §8), an icon,
-- a buff label and a numeral countdown. A bar's identity is buff+variant zone
-- (barKeyOf), so a multi-zone pop such as Rend renders BOTH landings side by side
-- rather than the second fire overwriting the first.
-- Bars group into Main (large; centered)
-- and Small (idle; top-right), ≤8 total, with FROZEN group assignment (no mid-
-- pull jumps — see HUD._AssignGroups above). Colours keep the owner-approved
-- traffic language: green (ok) -> amber (warn, under expand threshold) -> red
-- (danger, ≤3s). Crossing T-3s calls bar:SetUrgent(true): the fill + countdown
-- BRIGHTEN and the countdown goes solid — never the old math.sin alpha pulse
-- that dimmed the whole bar (BRAND_SPEC §7/§8: urgency raises luminance, never
-- dims). Draggable while unlocked; trust tags drive confirmation chat notices;
-- a just-expired key is blocked from restarting for 60s.
----------------------------------------------------------------------

-- Every table below is keyed by BAR key (barKeyOf: buffKey, or "buff:zone" for a
-- multi-zone buff's variant landing) — never by buffKey — so Rend's Orgrimmar and
-- Barrens bars coexist instead of the second fire overwriting the first.
local bars = {}              -- barKey -> bar frame (outer)
local barOrder = {}          -- insertion order (for cap eviction: oldest first)
local recentlyExpired = {}   -- barKey -> frameClock of expiry
local mainGroup, smallGroup  -- container frames

local function expandThreshold()
    return cfg("expandThreshold", 10)
end

-- Brighten a token colour toward white (never darkens) — mirrors the kit's
-- urgency-brighten so the traffic-light fill matches the countdown's brighten.
local function brighten(r, g, b, t)
    t = t or 0.35
    return r + (1 - r) * t, g + (1 - g) * t, b + (1 - b) * t
end

-- Apply the bar's current state colour to its fill. Registered via UI.Skin AFTER
-- the kit's own reskin, so on a live theme switch this wins for the fill hue.
-- Reads bar._stateToken (traffic light) + bar._urgent (kit flag) so a brightened
-- bar stays brightened across a theme change. The kit's SetUrgent independently
-- brightens the numeral countdown text (kept solid — no alpha pulse).
local function applyBarVisual(sb)
    local r, gg, bb = UI.Color(sb._stateToken or "ok")
    if sb._urgent then r, gg, bb = brighten(r, gg, bb) end
    sb:SetStatusBarColor(r, gg, bb)
end

-- Group containers hold and position their bars; draggable when unlocked.
local function ensureGroups()
    if mainGroup then return end

    local function makeGroup(name, defPoint, defX, defY, sizeKeyW, sizeKeyH)
        local g = CreateFrame("Frame", "DaseekiNexusBars" .. name, UIParent)
        g:SetSize(cfg(sizeKeyW, 220), 40)
        g:SetFrameStrata("MEDIUM")
        g._posKey = name        -- "Main" / "Small"
        g._bars = {}
        -- Restore saved position (additive keys; fall back to defaults).
        local pos = cfg(name == "Main" and "mainPos" or "smallPos", nil)
        if type(pos) == "table" and pos.point then
            g:SetPoint(pos.point, UIParent, pos.point, pos.x or 0, pos.y or 0)
        else
            g:SetPoint(defPoint, UIParent, defPoint, defX, defY)
        end
        g:SetMovable(true)
        g:RegisterForDrag("LeftButton")
        g:SetScript("OnDragStart", function(self)
            if cfg("locked", true) then return end
            self:StartMoving()
        end)
        g:SetScript("OnDragStop", function(self)
            self:StopMovingOrSizing()
            HUD.SaveGroupPosition(self)
        end)
        return g
    end

    mainGroup  = makeGroup("Main",  "CENTER",   0,  160, "width",      "height")
    smallGroup = makeGroup("Small", "TOPRIGHT", -24, -220, "smallWidth", "smallHeight")
end

-- Persist a group's current position into settings (additive keys).
function HUD.SaveGroupPosition(g)
    local pb = pullBarCfg()
    if not pb then return end
    local point, _, _, x, y = g:GetPoint(1)
    local key = (g._posKey == "Main") and "mainPos" or "smallPos"
    pb[key] = { point = point or "CENTER", x = x or 0, y = y or 0 }
end

-- Build one pull bar (both dimensions set at creation, per style rule).
-- Structure: outer Frame (positioned by the group) → token FlatFrame bg →
-- UI.MakeStatusBar fill (interpolation + spark + numeral countdown). Icon and
-- label are children of the STATUS BAR (drawn above the fill), so they never sit
-- behind the drain. The countdown is the kit's own text FS (numeral, right).
-- `buffKey` is the BUFF (not the bar key): it drives icon/label/alert routing and
-- is stashed on the frame as bar._buffKey. onPullDetected additionally stamps
-- bar._variantZone on a variant bar.
local function createBar(buffKey)
    local bar = CreateFrame("Frame", nil, UIParent)
    bar:SetSize(220, 18)
    bar._buffKey = buffKey

    local bg = UI.FlatFrame(bar, "inset", "border")
    bg:SetAllPoints(bar)
    bar._bg = bg

    local sb = UI.MakeStatusBar(bar, {
        spark      = true,
        text       = true,
        textFont   = "numeral",
        textJustify = "RIGHT",
        fillToken  = "ok",       -- baseline; hue is driven per-state by applyBarVisual
        bgToken    = "inset",
    })
    sb:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
    sb:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1, 1)
    sb._stateToken = "ok"
    bar._sb = sb

    -- Our fill-hue reskin, registered AFTER the kit's, so it wins for the fill
    -- colour on a live theme switch (the kit still owns the countdown brighten).
    UI.Skin(sb, applyBarVisual)

    -- Icon (left) + label (buff name) live ON the status bar → above the fill.
    local icon = sb:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("LEFT", sb, "LEFT", 2, 0)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    bar._icon = icon

    local label = sb:CreateFontString(nil, "OVERLAY")
    label:SetFontObject(UI.fonts.body)
    label:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    label:SetJustifyH("LEFT")
    bar._label = label
    UI.Skin(label, function(self) self:SetTextColor(UI.Color("text")) end)

    bar:Hide()
    return bar
end

-- Evict the oldest bar when at cap (never a currently-relevant main bar if a
-- small one exists; simplest: evict the oldest by insertion order).
local function evictIfNeeded()
    while #barOrder >= MAX_BARS do
        local oldest = table.remove(barOrder, 1)
        local b = bars[oldest]
        if b then b:Hide(); bars[oldest] = nil end
    end
end

-- Colour + fill a bar for its remaining/duration. The kit interpolates the fill
-- (SetBarValue) and rides the spark; we set the traffic-light hue + urgency.
-- NO alpha pulse anywhere — the bar never dims (BRAND_SPEC §7/§8).
local function paintBar(bar, remaining, duration)
    local sb = bar._sb
    sb:SetBarValue(remaining)   -- interpolated drain toward `remaining`; spark tracks it

    local token, urgent
    if remaining <= RED_PULSE_AT then
        token, urgent = "danger", true      -- T-3s: brighten (never dim), solid text
    elseif remaining <= expandThreshold() then
        token, urgent = "warn", false
    else
        token, urgent = "ok", false
    end

    sb._stateToken = token
    if sb._urgent ~= urgent then
        sb:SetUrgent(urgent)    -- kit: brighten + solidify the numeral countdown text
    end
    applyBarVisual(sb)          -- apply the (possibly brightened) fill hue
end

-- Per-bar zone relevance: a VARIANT bar is relevant only when the player stands
-- in that bar's OWN landing zone (an Orgrimmar waiter must not see the Barrens
-- bar promoted, and vice versa). A non-variant bar keeps the BUFF_META check.
local function barZoneRelevant(bar)
    if bar._variantZone then return zoneMatches(zoneNow(), bar._variantZone) end
    return zoneRelevant(bar._buffKey)
end

-- Recompute every bar's FROZEN group. Called ONLY at a structural event (a new
-- bar spawns, or a bar expires) — never on the periodic tick — so a bar never
-- jumps groups mid-countdown when the expand threshold is crossed. Delegates to
-- the pure HUD._AssignGroups (the same code the regression suite exercises).
local function assignGroups()
    local list = {}
    for i = 1, #barOrder do
        local k = barOrder[i]
        local b = bars[k]
        if b then
            list[#list + 1] = {
                key = k,
                rem = (b._endTime or 0) - frameClock(),
                zoneRelevant = barZoneRelevant(b),
                bar = b,
            }
        end
    end
    HUD._AssignGroups(list, expandThreshold())
    for _, e in ipairs(list) do e.bar._group = e.group end
end

-- Lay out bars into their groups (by FROZEN _group) and size each per settings.
local function reflow()
    ensureGroups()
    local mainW  = cfg("width", 220)
    local mainH  = cfg("height", 18)
    local smallW = cfg("smallWidth", math.floor(mainW * 0.72 + 0.5))
    local smallH = cfg("smallHeight", math.max(12, mainH - 4))

    local mainBars, smallBars = {}, {}
    for i = 1, #barOrder do
        local k = barOrder[i]
        local b = bars[k]
        if b and b:IsShown() then
            if b._group == "main" then mainBars[#mainBars + 1] = b else smallBars[#smallBars + 1] = b end
        end
    end

    local function stack(group, list, w, h, downward)
        group:SetSize(w, math.max(h, #list * (h + 3)))
        for i, b in ipairs(list) do
            b:SetParent(group)
            b:SetSize(w, h)
            b._icon:SetSize(h - 2, h - 2)
            b:ClearAllPoints()
            local y = -(i - 1) * (h + 3)
            b:SetPoint("TOP", group, "TOP", 0, y)
            b:EnableMouse(false)   -- bars are visual; group handles drag
        end
    end

    -- Main group centered-stack; small group stacked at top-right.
    stack(mainGroup, mainBars, mainW, mainH, true)
    stack(smallGroup, smallBars, smallW, smallH, true)
end

-- The single driver ticker updates every live bar, expires finished ones.
local barTicker
local function ensureTicker()
    if barTicker then return end
    barTicker = CreateFrame("Frame")
    barTicker._accum = 0
    barTicker:SetScript("OnUpdate", function(self, elapsed)
        if not next(bars) then return end
        self._accum = self._accum + elapsed
        local doReflow = false
        for k, b in pairs(bars) do
            if b:IsShown() then
                local rem = (b._endTime or 0) - frameClock()
                if rem <= 0 then
                    b:Hide()
                    bars[k] = nil
                    for i = #barOrder, 1, -1 do
                        if barOrder[i] == k then table.remove(barOrder, i) end
                    end
                    recentlyExpired[k] = frameClock()
                    doReflow = true
                else
                    local dur = b._duration or DEFAULT_PULL_WINDOW
                    paintBar(b, rem, dur)
                    b._sb:SetBarText(rem >= 60
                        and string.format("%d:%02d", math.floor(rem / 60), math.floor(rem % 60))
                        or  string.format("%.0fs", rem))
                end
            end
        end
        -- Expiry is a STRUCTURAL event → re-partition groups, then reflow. The
        -- periodic 0.5s pass only repositions (frozen groups → no mid-pull jump).
        if doReflow then
            ns:SafeCall(assignGroups)
            self._accum = 0
            ns:SafeCall(reflow)
        elseif self._accum >= 0.5 then
            self._accum = 0
            ns:SafeCall(reflow)
        end
    end)
end

-- trust -> confirmation chat notice (spec §3). Keyed by BUFF, not by bar: one pop
-- that raises two variant bars is still one pop, so the notice dedups on the
-- dispatcher's window instead of printing once per bar. The dedup key carries
-- trust + confirmed, so a genuine trust UPGRADE still speaks.
local lastTrustNoticeAt = {}   -- "buff:trust:confirmed" -> frameClock
local function trustNotice(buffKey, trust, confirmed)
    local t = frameClock()
    local dkey = buffKey .. ":" .. tostring(trust) .. ":" .. tostring(confirmed == true)
    local prev = lastTrustNoticeAt[dkey]
    if prev and (t - prev) < DEDUP_WINDOW then return end
    lastTrustNoticeAt[dkey] = t
    local label = buffLabel(buffKey)
    if trust == "dbm" and not confirmed then
        ns:Print("|cffff9f40[Intercepted DBM]|r " .. label .. " — no local or NWB confirmation.")
    elseif confirmed then
        ns:Print("|cff82bf6b[Timer confirmed]|r " .. label .. ".")
    end
end

-- PULL_DETECTED(buffKey, duration, trust, zone) handler. `zone` carries the
-- LANDING zone, which is what splits a multi-zone buff into two bars: identity
-- below is the bar key, not the buff key (Rend fires twice per pop).
local function onPullDetected(buffKey, duration, trust, zone)
    if not BUFF_META[buffKey] and buffKey ~= "battleShout" then return end
    ensureGroups(); ensureTicker()

    local barKey = barKeyOf(buffKey, zone)
    local variantZone = (barKey ~= buffKey) and lower(zone) or nil

    -- 60s recently-expired restart block — per BAR, so Orgrimmar's 6s bar
    -- expiring never blocks the Barrens bar from the same pop.
    local exp = recentlyExpired[barKey]
    if exp and (frameClock() - exp) < RECENT_EXPIRE_BLOCK then
        return
    end

    duration = (duration and duration > 0) and duration or DEFAULT_PULL_WINDOW

    local isNew = false
    local bar = bars[barKey]
    if bar then
        -- Existing bar: refresh window + possible trust upgrade. NOT a structural
        -- event → group stays frozen (no jump), only the fill range refreshes.
        local wasTrust = bar._trust
        bar._endTime = frameClock() + duration
        bar._duration = duration
        bar._sb:SetBarRange(0, duration)
        bar._sb:SetBarValue(duration, true)   -- refill to full immediately
        if trust and trust ~= wasTrust then
            bar._trust = trust
            trustNotice(buffKey, trust, true)
        end
    else
        isNew = true
        evictIfNeeded()
        bar = createBar(buffKey)
        bar._variantZone = variantZone
        bar._icon:SetTexture(buffIcon(buffKey))
        -- Variant bars name their landing so two Rend bars read apart.
        bar._label:SetText(variantZone
            and (buffLabel(buffKey) .. " (" .. zone .. ")")
            or  buffLabel(buffKey))
        bar._endTime = frameClock() + duration
        bar._duration = duration
        bar._trust = trust
        bar._sb:SetBarRange(0, duration)
        bar._sb:SetBarValue(duration, true)   -- start full (no drain-in pop)
        bar:Show()
        bars[barKey] = bar
        barOrder[#barOrder + 1] = barKey
        trustNotice(buffKey, trust, false)
    end

    -- A new bar spawning is a STRUCTURAL event → re-partition groups (spec-allowed
    -- regroup point). A plain refresh keeps every bar's frozen group.
    if isNew then ns:SafeCall(assignGroups) end

    -- Route a pull-timer alert through the dispatcher. Deliberately keyed by
    -- BUFF, not bar: the dispatcher's 3s dedup collapses Rend's two fires into a
    -- single "Rend incoming!" banner — two bars, one alert.
    HUD.Alert(buffKey, "pullTimer", buffLabel(buffKey) .. " incoming!")
    ns:SafeCall(reflow)
end

-- Public: clear all bars (resetui path / debug).
function HUD.ClearBars()
    for k, b in pairs(bars) do b:Hide(); bars[k] = nil end
    wipe(barOrder)
end

----------------------------------------------------------------------
-- Mover mode
--
-- A dimmed full-screen overlay with two draggable labelled preview groups
-- ("Main Bars" / "Small Bars") sized from live settings, plus Save / Cancel.
-- Save writes the preview positions back into settings and reflows the live
-- bars; Cancel discards. Live size preview: sample bars render at the current
-- width/height so the owner sees the real footprint while dragging.
----------------------------------------------------------------------

local mover

local function makePreview(parent, titleText, w, h)
    local p = CreateFrame("Frame", nil, parent)
    p:SetSize(math.max(w, 120), h + 26)
    p:SetMovable(true)
    p:EnableMouse(true)
    p:RegisterForDrag("LeftButton")
    p:SetScript("OnDragStart", p.StartMoving)
    p:SetScript("OnDragStop", p.StopMovingOrSizing)

    local bg = UI.FlatFrame(p, "panel", "accent")
    bg:SetAllPoints(p)

    local title = p:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(UI.fonts.accent)
    title:SetPoint("TOP", p, "TOP", 0, -4)
    title:SetText(titleText)

    -- sample bar (live size preview)
    local sample = CreateFrame("StatusBar", nil, p)
    sample:SetSize(w, h)
    sample:SetPoint("TOP", title, "BOTTOM", 0, -4)
    sample:SetStatusBarTexture("Interface\\Buttons\\WHITE8X8")
    sample:SetMinMaxValues(0, 1)
    sample:SetValue(0.66)
    UI.Skin(sample, function(self) self:SetStatusBarColor(UI.Color("ok")) end)
    p._sample = sample
    p._title = title
    return p
end

function HUD.ShowMover()
    if mover and mover:IsShown() then return end
    local mainW  = cfg("width", 220)
    local mainH  = cfg("height", 18)
    local smallW = cfg("smallWidth", math.floor(mainW * 0.72 + 0.5))
    local smallH = cfg("smallHeight", math.max(12, mainH - 4))

    if not mover then
        mover = CreateFrame("Frame", "DaseekiNexusMover", UIParent)
        mover:SetAllPoints(UIParent)
        mover:SetFrameStrata("DIALOG")
        mover:EnableMouse(true)   -- swallow clicks to the world beneath

        local dim = mover:CreateTexture(nil, "BACKGROUND")
        dim:SetAllPoints(mover)
        dim:SetColorTexture(0, 0, 0, 0.5)

        local hint = mover:CreateFontString(nil, "OVERLAY")
        hint:SetFontObject(UI.fonts.muted)
        hint:SetPoint("TOP", mover, "TOP", 0, -120)
        hint:SetText("Drag the Main and Small bar groups, then Save.")
        mover._hint = hint

        mover._main  = makePreview(mover, "Main Bars",  mainW, mainH)
        mover._small = makePreview(mover, "Small Bars", smallW, smallH)

        local save = UI.MakeButton(mover, {
            text = "Save", variant = "normal", width = 90,
            onClick = function() HUD.SaveMover() end,
        })
        save:SetPoint("BOTTOM", mover, "BOTTOM", -52, 120)
        local cancel = UI.MakeButton(mover, {
            text = "Cancel", variant = "quiet", width = 90,
            onClick = function() mover:Hide() end,
        })
        cancel:SetPoint("BOTTOM", mover, "BOTTOM", 52, 120)
    end

    -- Position the previews at the live group positions.
    ensureGroups()
    mover._main:ClearAllPoints()
    mover._small:ClearAllPoints()
    local mp = { mainGroup:GetPoint(1) }
    local sp = { smallGroup:GetPoint(1) }
    mover._main:SetPoint(mp[1] or "CENTER", UIParent, mp[1] or "CENTER", mp[4] or 0, mp[5] or 160)
    mover._small:SetPoint(sp[1] or "TOPRIGHT", UIParent, sp[1] or "TOPRIGHT", sp[4] or -24, sp[5] or -220)
    -- refresh sample sizes to live settings
    mover._main._sample:SetSize(mainW, mainH)
    mover._small._sample:SetSize(smallW, smallH)
    mover:Show()
end

function HUD.SaveMover()
    if not mover then return end
    ensureGroups()
    local function copyPos(preview, group, key)
        local point, _, _, x, y = preview:GetPoint(1)
        local pb = pullBarCfg()
        pb[key] = { point = point or "CENTER", x = x or 0, y = y or 0 }
        group:ClearAllPoints()
        group:SetPoint(point or "CENTER", UIParent, point or "CENTER", x or 0, y or 0)
    end
    copyPos(mover._main, mainGroup, "mainPos")
    copyPos(mover._small, smallGroup, "smallPos")
    mover:Hide()
    ns:SafeCall(reflow)
    ns:Print("pull-bar positions saved.")
end

----------------------------------------------------------------------
-- Cancel Buffs popup
--
-- A movable 3-column grid of tracked-aura buttons (lit + timer when active,
-- greyed when absent) that cancel the aura on click, plus wide Boon / Unboon
-- Chronoboon buttons. Cancels use insecure CancelUnitBuff, valid out of
-- combat only (the popup is combat-blocked with a chat notice, so a secure
-- cancelaura button is unnecessary). Boon/Unboon MUST be secure use-item
-- buttons (Chronoboon Displacer, item 184937).
----------------------------------------------------------------------

-- Engine tracked-aura layout (matches tracker's BUFF_SLOTS names). R3 item 36
-- adds Battle Shout + seasonal FFF as trailing slots 9/10. The grid geometry is
-- derived from #CANCEL_AURAS, so it auto-reflows to the new count. The FFF prefix
-- is a best-guess PLACEHOLDER the owner confirms in-game (mirrors tracker.lua).
local CANCEL_AURAS = {
    { label = "Ony",         prefix = "rallying cry of the dragonslayer", icon = "Interface\\Icons\\INV_Misc_Head_Dragon_01" },
    { label = "Rend",        prefix = "warchief's blessing",              icon = "Interface\\Icons\\Ability_Warrior_WarCry" },
    { label = "ZG",          prefix = "spirit of zandalar",               icon = "Interface\\Icons\\INV_Jewelry_Talisman_14" },
    { label = "Songflower",  prefix = "songflower serenade",              icon = "Interface\\Icons\\Spell_Holy_MindVision" },
    { label = "DMF",         prefix = "sayge's dark fortune",             icon = "Interface\\Icons\\INV_Misc_Ticket_Tarot_Blessings_01" },
    { label = "Fengus",      prefix = "fengus' ferocity",                 icon = "Interface\\Icons\\Ability_Warrior_Rampage" },
    { label = "Mol'dar",     prefix = "mol'dar's moxie",                  icon = "Interface\\Icons\\Ability_Warrior_Charge" },
    { label = "Slip'kik",    prefix = "slip'kik's savvy",                 icon = "Interface\\Icons\\Spell_Nature_MoonKey" },
    { label = "Battle Shout", prefix = "battle shout",                    icon = "Interface\\Icons\\Ability_Warrior_BattleShout" },
    { label = "FFF",         prefix = "fervor of the first feast",        icon = "Interface\\Icons\\INV_Misc_Food_15" },  -- [verify prefix]
}

local CHRONOBOON_ITEM_ID = 184937

-- Find a player buff whose name prefix-matches; returns index, remaining.
local function findPlayerAura(prefix)
    if not (C_UnitAuras and C_UnitAuras.GetBuffDataByIndex) then return nil end
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if not aura then break end
        if lower(aura.name):sub(1, #prefix) == prefix then
            local rem = 0
            if aura.expirationTime and aura.expirationTime > 0 then
                rem = aura.expirationTime - frameClock()
                if rem < 0 then rem = 0 end
            end
            return i, rem
        end
    end
    return nil
end

local cancelPopup

local function buildCancelPopup()
    local f = CreateFrame("Frame", "DaseekiNexusCancelBuffs", UIParent)
    local COLS, CELL, PAD, GAP = 3, 74, 12, 8
    local rows = math.ceil(#CANCEL_AURAS / COLS)
    local gridW = COLS * CELL + (COLS - 1) * GAP
    local width = gridW + PAD * 2
    local headerH, footerH = 30, 34
    local gridH = rows * CELL + (rows - 1) * GAP
    f:SetSize(width, headerH + gridH + footerH + PAD * 3)
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetClampedToScreen(true)

    local bg = UI.FlatFrame(f, "panel", "accent")
    bg:SetAllPoints(f)

    local title = f:CreateFontString(nil, "OVERLAY")
    title:SetFontObject(UI.fonts.accent)
    title:SetPoint("TOP", f, "TOP", 0, -8)
    title:SetText("Cancel Buffs")

    local close = UI.MakeButton(f, { text = "×", variant = "quiet", width = 24, height = 20,
        onClick = function() f:Hide() end })
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -6, -6)

    -- Grid cells.
    f._cells = {}
    for idx, def in ipairs(CANCEL_AURAS) do
        local col = (idx - 1) % COLS
        local rw  = math.floor((idx - 1) / COLS)
        local cell = CreateFrame("Button", nil, f)
        cell:SetSize(CELL, CELL)
        cell:SetPoint("TOPLEFT", f, "TOPLEFT",
            PAD + col * (CELL + GAP),
            -(headerH + PAD + rw * (CELL + GAP)))

        local cbg = UI.FlatFrame(cell, "inset", "border")
        cbg:SetAllPoints(cell)

        local icon = cell:CreateTexture(nil, "ARTWORK")
        icon:SetSize(CELL - 30, CELL - 30)
        icon:SetPoint("TOP", cell, "TOP", 0, -4)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        icon:SetTexture(def.icon)

        local lbl = cell:CreateFontString(nil, "OVERLAY")
        lbl:SetFontObject(UI.fonts.small)
        lbl:SetPoint("BOTTOM", cell, "BOTTOM", 0, 3)
        lbl:SetText(def.label)

        local timer = cell:CreateFontString(nil, "OVERLAY")
        timer:SetFontObject(UI.fonts.small)
        timer:SetPoint("BOTTOM", lbl, "TOP", 0, 0)

        cell._def, cell._icon, cell._lbl, cell._timer = def, icon, lbl, timer
        cell:SetScript("OnClick", function()
            if InCombatLockdown and InCombatLockdown() then
                ns:Print("cannot cancel buffs in combat.")
                return
            end
            local i = findPlayerAura(def.prefix)
            if i and CancelUnitBuff then
                CancelUnitBuff("player", i)   -- insecure; valid out of combat
                if f._Refresh then f._Refresh() end
            end
        end)
        f._cells[idx] = cell
    end

    -- Boon / Unboon secure use-item buttons (Chronoboon Displacer).
    local function makeItemButton(name, text, xoff)
        local b = CreateFrame("Button", "DaseekiNexus" .. name, f, "SecureActionButtonTemplate")
        b:SetSize((gridW - GAP) / 2, 24)
        b:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", PAD + xoff, PAD)
        b:SetAttribute("type", "item")
        b:SetAttribute("item", "item:" .. CHRONOBOON_ITEM_ID)
        b:RegisterForClicks("AnyUp", "AnyDown")

        local bbg = UI.FlatFrame(b, "control", "accentDim")
        bbg:SetAllPoints(b)
        local blbl = b:CreateFontString(nil, "OVERLAY")
        blbl:SetFontObject(UI.fonts.body)
        blbl:SetPoint("CENTER", b, "CENTER", 0, 0)
        blbl:SetText(text)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints(b)
        UI.Skin(hl, function(self) self:SetColorTexture(UI.Color("accent", 0.14)) end)
        b:SetHighlightTexture(hl)
        return b
    end
    makeItemButton("Boon",   "Boon",   0)
    makeItemButton("Unboon", "Unboon", (gridW - GAP) / 2 + GAP)

    -- Live refresh: lit + timer when active, greyed when absent.
    function f._Refresh()
        local combat = InCombatLockdown and InCombatLockdown()
        for _, cell in ipairs(f._cells) do
            local i, rem = findPlayerAura(cell._def.prefix)
            if i then
                cell._icon:SetDesaturated(false)
                cell._icon:SetVertexColor(1, 1, 1)
                cell._lbl:SetTextColor(UI.Color("text"))
                if rem and rem > 0 then
                    cell._timer:SetText(rem >= 60
                        and string.format("%d:%02d", math.floor(rem / 60), math.floor(rem % 60))
                        or  string.format("%.0fs", rem))
                    cell._timer:SetTextColor(UI.Color("accent"))
                else
                    cell._timer:SetText("")
                end
            else
                cell._icon:SetDesaturated(true)
                cell._icon:SetVertexColor(0.5, 0.5, 0.5)
                cell._lbl:SetTextColor(UI.Color("faint"))
                cell._timer:SetText("")
            end
        end
        if combat then
            title:SetText("Cancel Buffs (combat — locked)")
        else
            title:SetText("Cancel Buffs")
        end
    end

    -- Poll live while shown.
    f._accum = 0
    f:SetScript("OnUpdate", function(self, elapsed)
        self._accum = self._accum + elapsed
        if self._accum >= 0.5 then self._accum = 0; self._Refresh() end
    end)
    f:SetScript("OnShow", function(self) self._Refresh() end)
    f:Hide()
    return f
end

-- Build the popup out of combat (it hosts SecureActionButtonTemplate item
-- buttons; SetAttribute on a secure frame is blocked in combat lockdown).
local function ensureCancelPopup()
    if cancelPopup then return cancelPopup end
    if InCombatLockdown and InCombatLockdown() then return nil end
    cancelPopup = buildCancelPopup()
    return cancelPopup
end

function HUD.ShowCancelBuffs()
    local p = ensureCancelPopup()
    if not p then
        ns:Print("open the Cancel Buffs panel outside combat first.")
        return
    end
    if p:IsShown() then p:Hide() else p:Show() end
end

----------------------------------------------------------------------
-- Engine callback wiring + slash / debug registration
----------------------------------------------------------------------

local function wireCallbacks()
    ns:On("PULL_DETECTED", function(buffKey, duration, trust, zone)
        ns:SafeCall(onPullDetected, buffKey, duration, trust, zone)
    end)

    -- CD_WARNING(buffKey, kind) kind ∈ "5min"/"1min"/"ready".
    ns:On("CD_WARNING", function(buffKey, kind)
        local eventType = (kind == "ready") and "cdExpired" or "cdWarning"
        local word = (kind == "ready") and "off cooldown"
                   or (kind == "5min") and "5 minutes"
                   or (kind == "1min") and "1 minute" or kind
        HUD.Alert(buffKey, eventType, buffLabel(buffKey) .. " — " .. word .. ".")
    end)
end

local function registerCommands()
    -- Override the core stub: `/dsn x` opens the Cancel Buffs popup.
    ns:RegisterSubcommand("x", function() HUD.ShowCancelBuffs() end, "cancel-buffs popup")
    ns:RegisterSubcommand("cancelbuffs", function() HUD.ShowCancelBuffs() end, "cancel-buffs popup")
    ns:RegisterSubcommand("mover", function() HUD.ShowMover() end, "move pull-timer bars")

    ns:RegisterDebugCommand("hud", function(args)
        args = (args or ""):lower()
        if args:find("mover") then HUD.ShowMover()
        elseif args:find("cancel") then HUD.ShowCancelBuffs()
        elseif args:find("clear") then HUD.ClearBars(); ns:Print("bars cleared.")
        else
            -- fabricate a demo pull bar for visual checks
            local k = args:match("(%S+)") or "rend"
            if not BUFF_META[k] then k = "rend" end
            -- No zone: the demo wants ONE plain-keyed bar, not a variant pair.
            onPullDetected(k, 30, "local", nil)
            ns:Print("demo pull bar: " .. buffLabel(k))
        end
    end)

    ns:RegisterDebugCommand("testalert", function(args)
        local buff, evt = args:match("^(%S*)%s*(%S*)$")
        HUD.TestAlert(buff ~= "" and buff or "rend", evt ~= "" and evt or "pullTimer")
    end)
end

-- Pure-Lua self-test: exercises the settings-free helpers.
local function runSelfTests(verbose)
    local pass = true
    local function check(cond, msg)
        if not cond then pass = false; if verbose then ns:Print("  FAIL: " .. msg) end end
    end
    check(buffLabel("rend") == "Rend", "buffLabel rend")
    check(buffIcon("zg"):find("Talisman"), "buffIcon zg")
    check(SOUND_BY_KEY["RaidWarning"] ~= nil, "sound RaidWarning present")
    check(SOUND_BY_KEY["None"].id == nil, "None has no id")
    check(soundKeyForEvent("pullTimer") ~= nil, "event sound resolves")
    check(#CANCEL_AURAS == 10, "10 cancel auras (added Battle Shout + FFF)")
    check(buffLabel("dmf") == "DMF" and buffLabel("fff") == "FFF", "dmf/fff BUFF_META present")
    check(BUFF_META.rend.zones["barrens"] == true, "rend zone meta covers the Barrens")
    check(barKeyOf("rend", "Barrens") == "rend:barrens", "variant bars key by buff+zone")
    if verbose then ns:Print("  hud selftest " .. (pass and "PASS" or "FAIL")) end
    return pass
end

registerCommands()
wireCallbacks()
ns:RegisterSelfTest("hud", runSelfTests)

ns:On("LOGIN", function()
    ns:SafeCall(ensureGroups)
    ns:SafeCall(ensureTicker)
    -- Pre-build the secure Cancel Buffs popup while guaranteed out of combat.
    ns:SafeCall(ensureCancelPopup)
end)
