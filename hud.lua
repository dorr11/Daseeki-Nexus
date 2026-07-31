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

-- ── A12.1 — alert dedup windows, PER CATEGORY ────────────────────────────────
-- Declared up here (above the DaseekiUI guard, like the group logic) so the
-- policy is pure, headless-testable and cannot be skipped when Core is absent.
-- The dispatcher below consumes HUD.DedupWindow.
--
--   * pull timers     -> 10s  (a real pull genuinely re-announces)
--   * every other cat -> 60s  (quest hand-in, NPC died / respawned, CD warning,
--     CD expired, buff gain). With local + mesh + third-party + boss-mod ingest
--     the same event arrived up to 4x inside the old flat 3s window and alerted
--     for every one of them.
--   * Battle Shout is EXEMPT from dedup entirely — it is a short, repeatedly
--     recast raid buff and suppressing repeats would hide real re-applications.
local DEDUP_WINDOWS = { pullTimer = 10 }
local DEDUP_DEFAULT = 60          -- seconds, every other category
local DEDUP_EXEMPT  = { battleShout = true }

-- PURE: the dedup window in seconds for a (buff, category) pair. 0 = exempt.
function HUD.DedupWindow(buffKey, eventType)
    if DEDUP_EXEMPT[buffKey] then return 0 end
    return DEDUP_WINDOWS[eventType] or DEDUP_DEFAULT
end

-- Frame clock. Declared up here (rather than with the other below-guard helpers)
-- because the A12.4 / A13.3 policy below is headless-testable and needs it.
local function frameClock() return (GetTime and GetTime()) or 0 end

-- ── A12.2 + A12.3 — the raid override block, all FIVE toggles ─────────────────
-- Spec §11: inside a raid instance the reference suppresses notify / chat /
-- flash / sound AND, on a fifth independent toggle, the pull-timer BARS. Every
-- one of the five defaults ON — a raid is the one place this addon should be
-- silent and empty.
--
-- A12.2 adds the fifth toggle (`bars`); A12.3 (owner decision) flips the four
-- channel defaults from the store's mixed notify/flash-on, chat/sound-off to
-- all-on. Both read an ABSENT key as `true`, which matters twice: the gate is
-- already correct on a settings table the LOGIN seed has not reached yet, and
-- on an SV file written before these defaults changed.
--
-- The `bars` toggle is deliberately NOT an alert channel: RaidChannelSuppressed
-- always answers false for it, so no alert can ever be silenced by the bar
-- toggle, and suppressing bars in a raid never suppresses the chat/screen line.
local RAID_SUPPRESS_CHANNELS = { "notify", "chat", "flash", "sound" }

-- PURE: read one raid-override flag, absent = ON.
-- Written as explicit ifs on purpose: the idiomatic
-- `(type(t)=="table") and t[k] or nil` collapses a stored FALSE to nil, which
-- would turn every explicit opt-out back into the default-ON. Do not "tidy".
local function raidFlag(raidDisable, key)
    if type(raidDisable) ~= "table" then return true end
    local v = raidDisable[key]
    if v == nil then return true end          -- DEFAULT ON (A12.2 / A12.3)
    return v == true
end
HUD._RaidFlag = raidFlag

function HUD.SuppressBarsInRaid(raidDisable, inRaid)
    if not inRaid then return false end
    return raidFlag(raidDisable, "bars")
end

function HUD.RaidChannelSuppressed(raidDisable, inRaid, channel)
    if not inRaid or channel == "bars" then return false end
    return raidFlag(raidDisable, channel)
end

-- ── A12.5 — CD warning / CD expired are SILENT by default ─────────────────────
-- Spec §11: "CD warning and CD expired default to no sound." The store seeds
-- EVERY alert row with its event's default tone, so those two rows shipped
-- audible. This is an additive, sticky, run-once correction:
--   * a row with no stored sound (nil / "" / false) is seeded "None";
--   * a row still holding the exact tone the store shipped for that event is
--     treated as never-chosen and corrected to "None". Without that clause a
--     fresh install could never be silent, because Store.Init writes its default
--     before anything else can run. It is the same "only rewrite values still
--     equal to the old default" rule store.lua's songflower migration uses;
--   * ANY other value is an owner choice and is left alone;
--   * the sticky flag makes it run exactly once, so an owner who later picks the
--     old default keeps it forever.
local SILENT_CD_EVENTS = { "cdWarning", "cdExpired" }
local LEGACY_CD_SOUND  = { cdWarning = "AuctionWindowOpen", cdExpired = "ReadyCheck" }
local SILENT_SOUND     = "None"

-- A12.3 — the raid CHANNEL defaults the store shipped before the owner's flip.
-- Same never-chosen test as the sounds: a stored value still equal to the tone/
-- flag the store wrote is treated as never-chosen; anything else is an owner
-- choice and survives.
local LEGACY_RAID_DISABLE = { notify = true, chat = false, flash = true, sound = false }

-- PURE: may we overwrite this stored value with the new default? True when the
-- slot is empty, or still holds exactly what the store originally shipped.
--
-- The `cur == legacy` clause is load-bearing and is the one place this pass can
-- overrule an owner: Store.Init writes its defaults at ADDON_LOADED, before any
-- module can run, so a strictly-absent test would make BOTH A12.3 and A12.5
-- no-ops on every install that has ever logged in — including fresh ones. The
-- residual: an owner who deliberately chose the value the store already shipped
-- is indistinguishable from one who never touched it, and is re-defaulted once.
-- The sticky flags below mean "once" is literal — a re-pick after this pass is
-- permanent. This mirrors store.lua's MigrateSongflowerDefaults rule.
local function seedable(cur, legacy)
    return cur == nil or cur == "" or cur == legacy
end
HUD._Seedable = seedable

-- Seed the additive alert defaults into `ts` (timerSettings) in place.
-- Returns rawSeeded, cdSeeded — whether each one-shot pass actually ran.
function HUD.SeedAlertDefaults(ts)
    if type(ts) ~= "table" then return false, false end
    if type(ts.raidDisable) ~= "table" then ts.raidDisable = {} end
    local rd = ts.raidDisable

    -- A12.2 — additive SV: publish the fifth raid toggle at its spec default so
    -- the settings checkbox and the bar gate read one stored value. Idempotent,
    -- so it is safe on every login.
    if rd.bars == nil then rd.bars = true end

    -- A12.3 — one-shot: raise the four channel overrides to all-suppressed.
    local raidSeeded = false
    if not ts.raidSuppressSeeded then
        ts.raidSuppressSeeded = true
        raidSeeded = true
        for i = 1, #RAID_SUPPRESS_CHANNELS do
            local ch = RAID_SUPPRESS_CHANNELS[i]
            if seedable(rd[ch], LEGACY_RAID_DISABLE[ch]) then rd[ch] = true end
        end
    end

    -- A12.5 — one-shot: silence the CD warning / CD expired rows.
    if ts.silentCDSeeded then return raidSeeded, false end
    ts.silentCDSeeded = true

    local alerts = ts.alerts
    for _, evt in ipairs(SILENT_CD_EVENTS) do
        local legacy = LEGACY_CD_SOUND[evt]
        local rows = (type(alerts) == "table") and alerts[evt] or nil
        if type(rows) == "table" then
            for _, row in pairs(rows) do
                if type(row) == "table" and seedable(row.sound, legacy) then
                    row.sound = SILENT_SOUND
                end
            end
        end
        local sk = ts.soundKeys
        if type(sk) == "table" and seedable(sk[evt], legacy) then
            sk[evt] = SILENT_SOUND
        end
    end
    return raidSeeded, true
end

-- ── A12.4 — Ony vs Nef buff-gain disambiguation ───────────────────────────────
-- Rallying Cry of the Dragonslayer is the SAME aura for Onyxia and Nefarian, so
-- a gain in that slot cannot name its own source. Spec §11 resolves it by which
-- announcer yelled most recently inside 30s, and — critically — fires NO alert
-- when neither yelled recently, because guessing would file a Nef kill on the
-- Ony rows and corrupt the reading of both.
--
-- HOW THE EPOCHS ARE SOURCED (a real, recorded limitation): timers.lua keeps no
-- per-announcer yell epoch and fires no yell event. Its only yell-derived
-- outputs are PULL_DETECTED(buffKey, remaining, trust, zone) and the direct
-- ns.HUD.Alert() calls from its own notify(). We therefore maintain the epochs
-- HERE, off the alert-side triggers we already receive, keyed by the
-- announcer-specific buff key (onyH/onyA vs nefH/nefA) — which is the only
-- channel that carries announcer identity. Consequences, deliberately accepted:
--   * a pull relayed by mesh / NWB / DBM also stamps the epoch. That is right —
--     it is still evidence that announcer yelled — but the stamp is RECEIPT
--     time, not the yell's own server epoch;
--   * both the stamp and the comparison run on frameClock(), so the 30s window
--     is internally consistent and immune to server-clock drift.
local ANNOUNCER_FAMILY   = { onyH = "ony", onyA = "ony", nefH = "nef", nefA = "nef" }
local GAIN_ATTRIB_WINDOW = 30

-- Slot keys whose buff-gain is ambiguous between Ony and Nef. The tracker files
-- this aura under its Ony slot, so onyH/onyA arrive here needing resolution too.
local AMBIGUOUS_GAIN = {
    ony = true, onyH = true, onyA = true, rallyingCry = true, rallyingcry = true,
}

local FAMILY_KEY_BY_FACTION = {
    ony = { Horde = "onyH", Alliance = "onyA" },
    nef = { Horde = "nefH", Alliance = "nefA" },
}

HUD._yellEpochs = {}   -- family -> frameClock of the most recent announcer report
HUD._yellKeys   = {}   -- family -> the announcer-specific buff key last seen

-- PURE. `epochs` = { ony = <t>, nef = <t> }, either may be nil.
-- Returns the winning family, or nil when neither is inside the window.
-- Nef wins an exact tie (it is the buff whose NAME belongs to the other boss,
-- so an unqualified "Rallying Cry" defaults away from the misleading label).
function HUD.PickYellFamily(epochs, t, window)
    window = window or GAIN_ATTRIB_WINDOW
    epochs = epochs or {}
    local best, bestAt
    local order = { "nef", "ony" }
    for i = 1, #order do
        local fam = order[i]
        local at  = epochs[fam]
        if type(at) == "number" then
            local age = t - at
            if age >= 0 and age <= window and (not bestAt or at > bestAt) then
                best, bestAt = fam, at
            end
        end
    end
    return best
end

-- Record that an announcer for `buffKey` just reported. No-op for other buffs.
function HUD.NoteAnnouncerYell(buffKey, t)
    local fam = ANNOUNCER_FAMILY[buffKey]
    if not fam then return false end
    HUD._yellEpochs[fam] = t or frameClock()
    HUD._yellKeys[fam]   = buffKey
    return true
end

-- Which alert row a buff-gain should fire on. nil = SUPPRESS (spec §11).
-- Unambiguous keys pass straight through untouched.
function HUD.ResolveGainKey(buffKey, t)
    if not AMBIGUOUS_GAIN[buffKey] then return buffKey end
    local fam = HUD.PickYellFamily(HUD._yellEpochs, t or frameClock(), GAIN_ATTRIB_WINDOW)
    if not fam then return nil end
    local key = HUD._yellKeys[fam]
    if key then return key end
    -- Family known but not the announcer's own key (only reachable if the epoch
    -- table was seeded without a key): fall back to our own faction's row.
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    return (FAMILY_KEY_BY_FACTION[fam] or {})[faction or ""] or nil
end

-- ── A13.3 — trust-ladder replacement of a LIVE bar ─────────────────────────────
-- TRUST_RANK is owned by timers.lua (local > mesh > sn > nwb > dbm); we read it
-- live so the ladder stays single-sourced, and keep a mirror only for the
-- headless case where Timers has not loaded.
local TRUST_FALLBACK     = { ["local"] = 5, mesh = 4, sn = 3, nwb = 2, dbm = 1 }
local TRUST_LABEL        = { ["local"] = "local", mesh = "mesh", sn = "SN", nwb = "NWB", dbm = "DBM" }
local TRUST_NOTICE_DELAY = 3   -- seconds; spec §10.7 confirm/warn line

local function trustRank(t)
    local tbl = (ns.Timers and ns.Timers.TRUST_RANK) or TRUST_FALLBACK
    return tbl[t or ""] or 0
end
HUD._TrustRank = trustRank

-- PURE: what a report at `newTrust` does to a live bar currently at `curTrust`.
--   "upgrade" — strictly higher trust: REWRITE the live window in place, then
--               print the confirm line ~3s later
--   "refresh" — equal trust, or an untagged report: plain window refresh
--   "ignore"  — strictly lower trust NEVER displaces a higher-trust window
function HUD.TrustAction(curTrust, newTrust)
    if newTrust == nil then return "refresh" end
    local a, b = trustRank(curTrust), trustRank(newTrust)
    if b > a then return "upgrade" end
    if b < a then return "ignore" end
    return "refresh"
end

-- PURE: the deferred notice a bar should print. nil = stay quiet.
-- More than one distinct source seen = corroborated, so the green confirm line
-- wins even for a bar that started life on the boss-mod addon. A lone boss-mod
-- bar warns; a lone anything-else bar says nothing.
function HUD.TrustNoticeFor(trust, sources)
    local n = 0
    for _ in pairs(sources or {}) do n = n + 1 end
    if n > 1 then return "confirm" end
    if trust == "dbm" then return "warn" end
    return nil
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

    -- A12.1: per-category alert dedup windows. Pull timers 10s, everything else
    -- 60s, Battle Shout exempt (0). The old flat 3s let the same event through
    -- up to 4x when local + mesh + third-party + boss-mod all reported it.
    check(HUD.DedupWindow("rend", "pullTimer") == 10, "pullTimer dedup window is 10s")
    check(HUD.DedupWindow("zg", "pullTimer") == 10,
        "pullTimer dedup is per-CATEGORY, not per-buff")
    local others = { "questHandin", "npcDied", "npcRespawned",
                     "cdWarning", "cdExpired", "buffGain" }
    for i = 1, #others do
        check(HUD.DedupWindow("ony", others[i]) == 60, others[i] .. " dedup window is 60s")
    end
    check(HUD.DedupWindow("ony", "somethingNew") == 60, "unknown category defaults to 60s")
    -- Battle Shout is exempt in EVERY category, pull timers included.
    check(HUD.DedupWindow("battleShout", "buffGain") == 0, "Battle Shout exempt (buffGain)")
    check(HUD.DedupWindow("battleShout", "pullTimer") == 0, "Battle Shout exempt (pullTimer)")
    check(HUD.DedupWindow("battleShout", "cdWarning") == 0, "Battle Shout exempt (cdWarning)")

    -- ── A12.2 / A12.3 — the five raid overrides ──────────────────────────────
    -- All five default ON, so an ABSENT key must read suppressed.
    check(HUD.SuppressBarsInRaid({}, true), "bars: absent key defaults ON in raid")
    check(HUD.SuppressBarsInRaid(nil, true), "bars: absent BLOCK defaults ON in raid")
    check(not HUD.SuppressBarsInRaid({}, false), "bars: never suppressed outside a raid")
    check(not HUD.SuppressBarsInRaid({ bars = false }, true),
        "bars: an explicit opt-out is honoured in raid")
    check(HUD.SuppressBarsInRaid({ bars = true }, true), "bars: explicit ON in raid")

    for _, ch in ipairs({ "notify", "chat", "flash", "sound" }) do
        check(HUD.RaidChannelSuppressed({}, true, ch), ch .. ": absent key defaults ON (A12.3)")
        check(not HUD.RaidChannelSuppressed({}, false, ch), ch .. ": untouched outside a raid")
        check(not HUD.RaidChannelSuppressed({ [ch] = false }, true, ch),
            ch .. ": explicit opt-out honoured")
    end
    -- The bar toggle is NOT a channel: it can never silence an alert. This is
    -- the "no bars in raid, but chat/screen alerts still fire" guarantee.
    check(not HUD.RaidChannelSuppressed({ bars = true }, true, "bars"),
        "bars is not an alert channel")
    local barsOnlyRaid = { bars = true, notify = false, chat = false, flash = false, sound = false }
    check(HUD.SuppressBarsInRaid(barsOnlyRaid, true), "bars-only config: bars suppressed")
    for _, ch in ipairs({ "notify", "chat", "flash", "sound" }) do
        check(not HUD.RaidChannelSuppressed(barsOnlyRaid, true, ch),
            "bars-only config: " .. ch .. " still fires")
    end

    -- ── A12.3 / A12.5 — additive seeding, never clobbering a real choice ─────
    -- A table shaped exactly like what Store.Init writes on a fresh install.
    local function freshTS()
        return {
            raidDisable = { notify = true, chat = false, flash = true, sound = false },
            soundKeys   = { pullTimer = "RaidWarning", cdWarning = "AuctionWindowOpen" },
            alerts = {
                cdWarning = { rend = { sound = "AuctionWindowOpen" }, onyH = { sound = "AuctionWindowOpen" } },
                cdExpired = { rend = { sound = "ReadyCheck" },        onyH = { sound = "ReadyCheck" } },
                pullTimer = { rend = { sound = "RaidWarning" } },
            },
        }
    end

    local ts = freshTS()
    local raidSeeded, cdSeeded = HUD.SeedAlertDefaults(ts)
    check(raidSeeded and cdSeeded, "fresh install: both seed passes run")
    check(ts.raidDisable.bars == true, "A12.2: bars seeded ON")
    check(ts.raidDisable.notify == true and ts.raidDisable.chat == true
        and ts.raidDisable.flash == true and ts.raidDisable.sound == true,
        "A12.3: all four channels raised to suppressed")
    check(ts.alerts.cdWarning.rend.sound == "None"
        and ts.alerts.cdWarning.onyH.sound == "None",
        "A12.5: cdWarning rows silent on a fresh install")
    check(ts.alerts.cdExpired.rend.sound == "None"
        and ts.alerts.cdExpired.onyH.sound == "None",
        "A12.5: cdExpired rows silent on a fresh install")
    check(ts.soundKeys.cdWarning == "None", "A12.5: soundKeys fallback silenced too")
    check(ts.alerts.pullTimer.rend.sound == "RaidWarning",
        "A12.5: other events keep their tone")

    -- Second run is inert: the sticky flags make both passes run exactly once.
    ts.alerts.cdWarning.rend.sound = "ReadyCheck"   -- owner re-picks a tone later
    ts.raidDisable.chat = false                     -- and re-opens chat in raid
    local raid2, cd2 = HUD.SeedAlertDefaults(ts)
    check(not raid2 and not cd2, "seeding is one-shot (sticky flags)")
    check(ts.alerts.cdWarning.rend.sound == "ReadyCheck",
        "a post-seed sound choice is permanent")
    check(ts.raidDisable.chat == false, "a post-seed raid choice is permanent")

    -- An owner choice that DIFFERS from what the store shipped survives the very
    -- first pass — that is the whole point of the never-chosen test.
    local chosen = freshTS()
    chosen.alerts.cdWarning.rend.sound = "MapPing"   -- deliberately picked
    chosen.raidDisable.notify = false                -- deliberately kept on-screen
    HUD.SeedAlertDefaults(chosen)
    check(chosen.alerts.cdWarning.rend.sound == "MapPing",
        "an explicit sound choice is never overwritten")
    check(chosen.raidDisable.notify == false,
        "an explicit raid-channel choice is never overwritten")
    check(chosen.alerts.cdWarning.onyH.sound == "None",
        "untouched sibling rows are still silenced")
    check(chosen.raidDisable.sound == true, "untouched sibling channels still raised")

    -- ── A12.4 — Ony vs Nef buff-gain attribution ─────────────────────────────
    local NOW = 1000
    check(HUD.PickYellFamily({ nef = NOW - 5 }, NOW) == "nef", "Nef yell 5s ago wins")
    check(HUD.PickYellFamily({ ony = NOW - 5 }, NOW) == "ony", "Ony yell 5s ago wins")
    check(HUD.PickYellFamily({ nef = NOW - 29 }, NOW) == "nef", "29s is inside the window")
    check(HUD.PickYellFamily({ nef = NOW - 30 }, NOW) == "nef", "30s is inclusive")
    check(HUD.PickYellFamily({ nef = NOW - 31 }, NOW) == nil, "31s is outside the window")
    check(HUD.PickYellFamily({}, NOW) == nil, "no yell at all -> no attribution")
    -- Most recent wins; an exact tie goes to Nef.
    check(HUD.PickYellFamily({ nef = NOW - 5, ony = NOW - 20 }, NOW) == "nef",
        "newer Nef beats older Ony")
    check(HUD.PickYellFamily({ nef = NOW - 20, ony = NOW - 5 }, NOW) == "ony",
        "newer Ony beats older Nef")
    check(HUD.PickYellFamily({ nef = NOW, ony = NOW }, NOW) == "nef", "exact tie -> Nef")
    -- A stale Nef must not shadow a live Ony.
    check(HUD.PickYellFamily({ nef = NOW - 90, ony = NOW - 10 }, NOW) == "ony",
        "expired Nef does not shadow a live Ony")

    wipe(HUD._yellEpochs); wipe(HUD._yellKeys)
    check(HUD.ResolveGainKey("onyH", NOW) == nil,
        "ambiguous gain with NO recent yell fires nothing (spec §11)")
    check(HUD.ResolveGainKey("rend", NOW) == "rend", "unambiguous key passes through")
    check(HUD.ResolveGainKey("zg", NOW) == "zg", "zg passes through")
    -- A Nef kill-yell, then the Rallying Cry lands: it must file on NEF's row.
    HUD.NoteAnnouncerYell("nefH", NOW - 4)
    check(HUD.ResolveGainKey("onyH", NOW) == "nefH",
        "Rallying Cry within 30s of a Nef yell -> Nef row")
    check(HUD.ResolveGainKey("ony", NOW) == "nefH", "slot alias resolves too")
    -- Same yell, but the gain arrives too late to be attributable.
    check(HUD.ResolveGainKey("onyH", NOW + 40) == nil,
        "same gain outside 30s -> no alert rather than a guess")
    -- Ony yells afterwards: attribution flips back.
    HUD.NoteAnnouncerYell("onyA", NOW - 1)
    check(HUD.ResolveGainKey("onyH", NOW) == "onyA",
        "a newer Ony yell reclaims the gain (and keeps its own faction key)")
    check(HUD.NoteAnnouncerYell("rend", NOW) == false, "non-announcer buffs stamp nothing")
    wipe(HUD._yellEpochs); wipe(HUD._yellKeys)

    -- ── A13.3 — trust ladder ─────────────────────────────────────────────────
    local ladder = { "dbm", "nwb", "sn", "mesh", "local" }
    for i = 1, #ladder do
        for j = 1, #ladder do
            local expect = (j > i) and "upgrade" or (j < i) and "ignore" or "refresh"
            check(HUD.TrustAction(ladder[i], ladder[j]) == expect,
                ladder[j] .. " onto " .. ladder[i] .. " -> " .. expect)
        end
    end
    check(HUD.TrustAction("dbm", nil) == "refresh", "an untagged report just refreshes")
    check(HUD.TrustAction(nil, "dbm") == "upgrade", "any trust beats an untrusted bar")
    check(HUD._TrustRank("local") > HUD._TrustRank("mesh"), "local outranks mesh")
    check(HUD._TrustRank("nwb") > HUD._TrustRank("dbm"), "nwb outranks dbm")
    check(HUD._TrustRank("nonsense") == 0, "an unknown trust ranks bottom")

    check(HUD.TrustNoticeFor("dbm", { dbm = true }) == "warn",
        "a lone boss-mod bar warns")
    check(HUD.TrustNoticeFor("local", { dbm = true, ["local"] = true }) == "confirm",
        "a corroborated bar confirms")
    check(HUD.TrustNoticeFor("local", { ["local"] = true }) == nil,
        "a lone trusted bar says nothing")
    check(HUD.TrustNoticeFor("dbm", { dbm = true, nwb = true }) == "confirm",
        "even a still-dbm bar confirms once a second source agrees")

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

-- frameClock() is declared above the DaseekiUI guard (the A12.4 / A13.3 policy
-- needs it headless); only `lower` is local to this section.
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
    -- A12.5: CD warning / CD expired are SILENT by default (spec §11). This is
    -- the last-resort fallback used when neither the alert row nor ts.soundKeys
    -- names a tone; the stored-value seeding lives in HUD.SeedAlertDefaults.
    cdWarning    = "None",
    cdExpired    = "None",
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

-- A12.1: the per-category dedup windows live above the DaseekiUI guard (see
-- HUD.DedupWindow near the top of this file) so they stay headless-testable.
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

-- Live wrappers over the pure A12.2/A12.3 policy above.
local function raidDisabled(channel)
    return HUD.RaidChannelSuppressed(timerSettings().raidDisable, inRaidInstance(), channel)
end

local function barsSuppressed()
    return HUD.SuppressBarsInRaid(timerSettings().raidDisable, inRaidInstance())
end

-- Core dispatch. opts: { test=bool } bypasses dedup + raid suppression.
local function dispatch(buffKey, eventType, message, opts)
    opts = opts or {}
    local row = alertRow(buffKey, eventType)
    local test = opts.test == true

    local window = HUD.DedupWindow(buffKey, eventType)
    if not test and window > 0 then
        local dkey = buffKey .. ":" .. eventType
        local t = frameClock()
        if lastAlertAt[dkey] and (t - lastAlertAt[dkey]) < window then
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

-- trust -> confirmation chat notice (spec §10.7). Keyed by BUFF, not by bar: one
-- pop that raises two variant bars is still one pop, so the notice dedups on the
-- dispatcher's window instead of printing once per bar. The dedup key carries
-- trust + notice kind, so a genuine trust UPGRADE still speaks.
local lastTrustNoticeAt = {}   -- "buff:trust:kind" -> frameClock
local function trustNotice(buffKey, trust, kind, sources)
    local t = frameClock()
    local dkey = buffKey .. ":" .. tostring(trust) .. ":" .. tostring(kind)
    local prev = lastTrustNoticeAt[dkey]
    if prev and (t - prev) < HUD.DedupWindow(buffKey, "pullTimer") then return end
    lastTrustNoticeAt[dkey] = t
    local label = buffLabel(buffKey)
    if kind == "warn" then
        ns:Print("|cffff9f40[Intercepted DBM]|r " .. label .. " — no local or NWB confirmation.")
    elseif kind == "confirm" then
        local who = (sources and #sources > 0) and (" — confirmed by " .. table.concat(sources, " + ")) or ""
        ns:Print("|cff82bf6b[Timer confirmed]|r " .. label .. who .. ".")
    end
end

-- A13.3 — every distinct source that has reported this bar, so the deferred
-- notice can tell "boss-mod guess" from "boss-mod guess, corroborated".
local function noteSource(bar, trust)
    if not trust then return end
    bar._sources = bar._sources or {}
    bar._sources[trust] = true
end

local function barSourceLabels(bar)
    local out = {}
    for t in pairs(bar._sources or {}) do out[#out + 1] = TRUST_LABEL[t] or t end
    table.sort(out)
    return out
end

-- Emit the bar's confirm/warn line from its state AT THE TIME IT FIRES — which
-- is the whole point of the 3s delay: a boss-mod bar that a local witness
-- upgrades in the meantime reports "confirmed", not "no confirmation".
local function emitTrustNotice(barKey, buffKey)
    local bar = bars[barKey]
    if not bar then return end
    bar._noticePending = false
    local kind = HUD.TrustNoticeFor(bar._trust, bar._sources)
    if not kind then return end
    trustNotice(buffKey, bar._trust, kind, barSourceLabels(bar))
end

-- Schedule the ~3s notice. One pending notice per bar: if an upgrade lands while
-- one is already in flight it simply reports the upgraded state, so a bar never
-- prints twice for a single pop. An upgrade arriving AFTER the notice fired
-- schedules a fresh one — that is the "rewrote a live bar, say so" line.
local function scheduleTrustNotice(barKey, buffKey)
    local bar = bars[barKey]
    if not bar or bar._noticePending then return end
    bar._noticePending = true
    if C_Timer and C_Timer.After then
        C_Timer.After(TRUST_NOTICE_DELAY, function()
            ns:SafeCall(emitTrustNotice, barKey, buffKey)
        end)
    else
        ns:SafeCall(emitTrustNotice, barKey, buffKey)
    end
end

-- PULL_DETECTED(buffKey, duration, trust, zone) handler. `zone` carries the
-- LANDING zone, which is what splits a multi-zone buff into two bars: identity
-- below is the bar key, not the buff key (Rend fires twice per pop).
local function onPullDetected(buffKey, duration, trust, zone)
    if not BUFF_META[buffKey] and buffKey ~= "battleShout" then return end

    -- A12.4: a pull report for an Ony/Nef announcer IS the evidence that that
    -- announcer yelled. Stamp it first, before any path can return early, so the
    -- 30s buff-gain attribution window is armed even when the bar is suppressed
    -- (in a raid) or blocked (recently expired).
    HUD.NoteAnnouncerYell(buffKey, frameClock())

    -- Route a pull-timer alert through the dispatcher. Deliberately keyed by
    -- BUFF, not bar: the dispatcher's dedup collapses Rend's two fires into a
    -- single "Rend incoming!" banner — two bars, one alert. Hoisted above the
    -- bar work so A12.2's raid bar suppression cannot take the alert with it.
    local function fireAlert()
        HUD.Alert(buffKey, "pullTimer", buffLabel(buffKey) .. " incoming!")
    end

    local barKey = barKeyOf(buffKey, zone)
    local variantZone = (barKey ~= buffKey) and lower(zone) or nil
    local bar = bars[barKey]

    -- A12.2 — in a raid instance, with the fifth override on (the default), we
    -- create NO new bar. Alerts still fire per their own four toggles. A bar
    -- already live (raised before we zoned in) keeps ticking and keeps its trust
    -- arbitration: this gates creation, not existence.
    if not bar and barsSuppressed() then
        fireAlert()
        return
    end

    ensureGroups(); ensureTicker()

    -- 60s recently-expired restart block — per BAR, so Orgrimmar's 6s bar
    -- expiring never blocks the Barrens bar from the same pop.
    local exp = recentlyExpired[barKey]
    if exp and (frameClock() - exp) < RECENT_EXPIRE_BLOCK then
        return
    end

    duration = (duration and duration > 0) and duration or DEFAULT_PULL_WINDOW

    local isNew = false
    if bar then
        -- A13.3 — trust arbitration on a LIVE bar. Every report is recorded as a
        -- source (corroboration counts even when it does not move the window),
        -- then the ladder decides what happens to the window itself.
        local action = HUD.TrustAction(bar._trust, trust)
        noteSource(bar, trust)

        if action == "upgrade" then
            -- REWRITE IN PLACE. `duration` here is PULL_DETECTED's `remaining`,
            -- which timers.lua already computed as (spec window − elapsed since
            -- the higher-trust source's event epoch) — so adopting it IS the
            -- recompute-from-the-better-epoch the spec asks for, and it is why a
            -- late-but-truer report legitimately SHORTENS a bar.
            -- The full window stays the fill range (widened only if this source
            -- knows of more time than we did) so the drain reads honestly instead
            -- of snapping back to full.
            bar._trust = trust
            bar._endTime = frameClock() + duration
            if duration > (bar._duration or 0) then bar._duration = duration end
            bar._sb:SetBarRange(0, bar._duration)
            bar._sb:SetBarValue(duration, true)
            scheduleTrustNotice(barKey, buffKey)
        elseif action == "refresh" then
            -- Same trust (or an untagged report): the historical plain refresh.
            -- NOT a structural event → group stays frozen (no mid-pull jump).
            bar._endTime = frameClock() + duration
            bar._duration = duration
            bar._sb:SetBarRange(0, duration)
            bar._sb:SetBarValue(duration, true)   -- refill to full immediately
        end
        -- action == "ignore": a LOWER-trust report never displaces a higher-trust
        -- window. It still counted as a source above, so it can still turn a
        -- lone boss-mod bar's warning into a confirmation.
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
        noteSource(bar, trust)
        scheduleTrustNotice(barKey, buffKey)
    end

    -- A new bar spawning is a STRUCTURAL event → re-partition groups (spec-allowed
    -- regroup point). A plain refresh keeps every bar's frozen group.
    if isNew then ns:SafeCall(assignGroups) end

    fireAlert()
    ns:SafeCall(reflow)
end
HUD._OnPullDetected = onPullDetected

-- Public: fire a buff-gain alert, resolving the ambiguous Rallying Cry slot to
-- whichever announcer actually yelled (A12.4). Returns false when the gain was
-- suppressed because neither Ony nor Nef yelled inside the 30s window.
function HUD.BuffGainAlert(buffKey, message)
    local key = HUD.ResolveGainKey(buffKey, frameClock())
    if not key then return false end
    HUD.Alert(key, "buffGain", message or (buffLabel(key) .. " gained."))
    return true
end

-- Test seam: a live bar's arbitration state, or nil when no such bar exists.
-- `remaining` is derived rather than stored so a test reads what the ticker
-- would paint.
function HUD._BarInfo(barKey)
    local b = bars[barKey]
    if not b then return nil end
    local sources = {}
    for t in pairs(b._sources or {}) do sources[#sources + 1] = t end
    table.sort(sources)
    return {
        trust     = b._trust,
        duration  = b._duration,
        remaining = (b._endTime or 0) - frameClock(),
        variant   = b._variantZone,
        sources   = sources,
        pending   = b._noticePending == true,
    }
end

-- Test seam: how many bars are live right now.
function HUD._BarCount() return #barOrder end

-- Test/reset seam: wipe every piece of live bar + alert state. Used by the
-- headless suites and by the resetui path.
function HUD._ResetBarState()
    for k, b in pairs(bars) do b:Hide(); bars[k] = nil end
    wipe(barOrder)
    wipe(recentlyExpired)
    wipe(lastAlertAt)
    wipe(lastTrustNoticeAt)
    wipe(HUD._yellEpochs)
    wipe(HUD._yellKeys)
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

    -- BUFF_GAIN(buffKey, message) — the A12.4 seam. Nothing fires this yet:
    -- aura capture lives in tracker.lua, which today only feeds the record. When
    -- it grows a settled before/after gain comparison it emits here and the
    -- Ony-vs-Nef attribution is already correct, including the spec's "neither
    -- announcer yelled recently -> stay silent" case.
    ns:On("BUFF_GAIN", function(buffKey, message)
        ns:SafeCall(HUD.BuffGainAlert, buffKey, message)
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

-- ── Integration suite: raid bar suppression + trust-ladder replacement ────────
-- Drives the REAL PULL_DETECTED handler against the REAL alert dispatcher and
-- the REAL live settings table, so it catches wiring the pure suite above
-- cannot. Registered below the DaseekiUI guard because it builds actual bars.
--
-- Everything it mutates (IsInInstance, ns.Print, timerSettings.alerts /
-- .raidDisable) is saved and restored, and the bar/alert state is reset between
-- cases so no case can inherit another's dedup timestamps.
ns:RegisterSelfTest("hudalerts", function(verbose)
    -- Failures are COLLECTED, not printed: this suite hijacks ns.Print to
    -- observe the chat channel, so printing a failure mid-run would both hide it
    -- and pollute the very buffer the next assertion counts.
    local fails = {}
    local function check(c, m) if not c then fails[#fails + 1] = m end end
    local function near(a, b) return math.abs((a or -999) - b) < 0.01 end

    local ts          = timerSettings()
    local savedRD     = ts.raidDisable
    local savedAlerts = ts.alerts
    local savedInst   = _G.IsInInstance
    local savedPrint  = ns.Print

    local lines = {}
    ns.Print = function(_, msg) lines[#lines + 1] = tostring(msg) end
    local function setRaid(on)
        _G.IsInInstance = function()
            if on then return true, "raid" end
            return false, "none"
        end
    end
    local function chatRow() return { notify = false, chat = true, flash = false, sound = "None" } end

    -- Chat-only rows make every alert observable as exactly one captured line.
    ts.alerts = {
        pullTimer = { rend = chatRow(), onyH = chatRow(), nefH = chatRow() },
        buffGain  = { onyH = chatRow(), onyA = chatRow(), nefH = chatRow(), nefA = chatRow() },
    }
    -- The owner has deliberately re-opened CHAT in raid but left bars suppressed:
    -- the exact config that proves the two are independent.
    ts.raidDisable = { notify = true, chat = false, flash = true, sound = true, bars = true }

    -- (1) A12.2 — in a raid, no bar is created, but the alert still fires.
    HUD._ResetBarState(); setRaid(true); lines = {}
    HUD._OnPullDetected("rend", 17, "local", "Barrens")
    check(HUD._BarCount() == 0, "raid: pull creates NO bar")
    check(#lines == 1 and lines[1]:find("Rend", 1, true) ~= nil,
        "raid: the chat alert still fires")

    -- Opting bars back in inside a raid restores the bar.
    HUD._ResetBarState(); ts.raidDisable.bars = false; lines = {}
    HUD._OnPullDetected("rend", 17, "local", "Barrens")
    check(HUD._BarCount() == 1, "raid + bars opt-in: bar created")
    ts.raidDisable.bars = true

    -- (2) A13.3 — a boss-mod bar, then a local witness REWRITES it in place.
    HUD._ResetBarState(); setRaid(false); lines = {}
    HUD._OnPullDetected("rend", 17, "dbm", "Barrens")
    local info = HUD._BarInfo("rend:barrens")
    check(info ~= nil and info.trust == "dbm", "dbm bar created at dbm trust")
    check(HUD._BarCount() == 1, "one bar")

    -- The local witness saw the yell later than dbm guessed, so the honest
    -- remaining is SHORTER. A replacement must be free to shorten a bar.
    HUD._OnPullDetected("rend", 6, "local", "Barrens")
    info = HUD._BarInfo("rend:barrens")
    check(HUD._BarCount() == 1, "replacement is IN PLACE — no second bar")
    check(info.trust == "local", "higher trust takes the bar over")
    check(near(info.remaining, 6), "window recomputed from the higher-trust epoch")
    check(info.duration == 17, "fill range keeps the full spec window")
    check(#info.sources == 2, "both sources recorded")
    check(info.pending, "a confirm/warn notice is scheduled")
    check(HUD.TrustNoticeFor(info.trust, info.sources) == "confirm",
        "the scheduled notice is the green confirm line")

    -- (3) A13.3 — a LOWER-trust report never displaces the live window.
    HUD._OnPullDetected("rend", 40, "nwb", "Barrens")
    info = HUD._BarInfo("rend:barrens")
    check(info.trust == "local", "lower trust does not take the bar")
    check(near(info.remaining, 6), "lower trust does not extend the window")
    check(#info.sources == 3, "but it still counts as corroboration")

    -- (4) Equal trust is the historical plain refresh.
    HUD._OnPullDetected("rend", 12, "local", "Barrens")
    info = HUD._BarInfo("rend:barrens")
    check(near(info.remaining, 12), "equal trust refreshes the window")

    -- (5) Variant isolation — a zone-variant Rend bar replaces only its own.
    HUD._ResetBarState(); lines = {}
    HUD._OnPullDetected("rend", 6,  "dbm", "Orgrimmar")
    HUD._OnPullDetected("rend", 17, "dbm", "Barrens")
    check(HUD._BarCount() == 2, "one pop, two variant bars")
    HUD._OnPullDetected("rend", 5, "local", "Orgrimmar")
    local org, barrens = HUD._BarInfo("rend:orgrimmar"), HUD._BarInfo("rend:barrens")
    check(HUD._BarCount() == 2, "still two bars after the upgrade")
    check(org.trust == "local" and near(org.remaining, 5), "the Orgrimmar variant upgraded")
    check(barrens.trust == "dbm" and near(barrens.remaining, 17),
        "the Barrens variant is untouched by its sibling's upgrade")
    check(#barrens.sources == 1 and barrens.sources[1] == "dbm",
        "sources do not leak across variants")

    -- (6) A12.4 — buff-gain attribution end to end through the dispatcher.
    HUD._ResetBarState(); lines = {}
    check(HUD.BuffGainAlert("onyH", "Rallying Cry.") == false,
        "no announcer yelled -> the gain is suppressed")
    check(#lines == 0, "a suppressed gain prints nothing at all")

    -- A Nef pull is what stamps the Nef announcer epoch.
    HUD._OnPullDetected("nefH", 15, "local", "Orgrimmar")
    lines = {}
    check(HUD.BuffGainAlert("onyH", "Rallying Cry.") == true,
        "after a Nef yell the gain fires")
    check(#lines == 1, "and fires exactly once")

    -- Restore everything this suite touched.
    ts.raidDisable  = savedRD
    ts.alerts       = savedAlerts
    _G.IsInInstance = savedInst
    ns.Print        = savedPrint
    HUD._ResetBarState()

    local pass = #fails == 0
    if verbose then
        for i = 1, #fails do ns:Print("  FAIL: " .. fails[i]) end
        ns:Print("  hudalerts selftest " .. (pass and "PASS" or "FAIL"))
    end
    return pass
end)

registerCommands()
wireCallbacks()
ns:RegisterSelfTest("hud", runSelfTests)

ns:On("LOGIN", function()
    -- A12.2 / A12.3 / A12.5 — additive SV seeds. Runs at LOGIN (PLAYER_LOGIN),
    -- which is strictly after Store.Init's ADDON_LOADED applyDefaults pass, so
    -- the store has already written whatever it was going to write and we are
    -- correcting a known-final table rather than racing it.
    ns:SafeCall(function() HUD.SeedAlertDefaults(timerSettings()) end)
    ns:SafeCall(ensureGroups)
    ns:SafeCall(ensureTicker)
    -- Pre-build the secure Cancel Buffs popup while guaranteed out of combat.
    ns:SafeCall(ensureCancelPopup)
end)
