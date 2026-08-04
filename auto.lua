-- Daseeki Nexus — auto.lua
-- Wave N4a: AUTOMATIONS (engine spec §5 + §7).
--
-- No-click automation: invite accept/send by trust category, mass alt
-- invite, raid-convert, summon acceptance with the fresh-buff
-- gate, gossip (DMT / BWL / Sayge), quest turn-ins (E'ko / ZG coins / zanza
-- / R.O.I.D.S.) and auto-repair. Every subsystem is gated on the per-faction
-- settings block owned by store.lua.
--
-- Clean-room build: reimplements the *functionality* of an unlicensed source
-- addon from a functional spec only. No third-party code or identifiers.
--
-- API discipline (target Interface 11509 only, every call catalog-verified):
--   * Group:   C_PartyInfo.InviteUnit                             (C_ member)
--              ConvertToRaid / AcceptGroup / LeaveParty           (GLOBALS —
--              NOT C_PartyInfo members in the 1.15.9 catalog).
--              READ-ONLY group state: GetNumGroupMembers, IsInRaid,
--              UnitIsGroupLeader, UnitName, IsEveryoneAssistant.
--              NO PROTECTED group API is called from this file — see the
--              "Mesh-assembly gate" block for why, and harness.lua's
--              "protected-API gate" for the rule that keeps it that way.
--   * Summon:  C_SummonInfo.ConfirmSummon / .CancelSummon /
--              .GetSummonReason ; UnitOnTaxi ; InCombatLockdown.
--   * Gossip:  C_GossipInfo.GetOptions / .SelectOption / .CloseGossip.
--   * Quest:   GetNumActiveQuests / GetActiveTitle / SelectActiveQuest ;
--              GetNumAvailableQuests / GetAvailableTitle / SelectAvailableQuest ;
--              AcceptQuest ; IsQuestCompletable / CompleteQuest ;
--              GetNumQuestChoices / GetQuestItemInfo / GetQuestReward ;
--              CloseQuest (all GLOBAL quest-frame functions).
--   * Repair:  CanMerchantRepair / GetRepairAllCost / RepairAllItems (globals).

local ADDON, ns = ...

local Auto = {}
ns.Auto = Auto

local Store = ns.Store

----------------------------------------------------------------------
-- Small helpers
----------------------------------------------------------------------

local function lower(s) return s and s:lower() or "" end
local function trim(s) return (s or ""):gsub("^%s+", ""):gsub("%s+$", "") end

local function selfRealm()
    local realm = GetNormalizedRealmName and GetNormalizedRealmName()
    if not realm or realm == "" then
        realm = (GetRealmName() or ""):gsub("%s+", "")
    end
    return realm
end

local function selfNameRealm()
    local name = UnitName("player") or "player"
    return name .. "-" .. selfRealm()
end

-- Normalise an arbitrary "Name" or "Name-Realm" to canonical "Name-Realm".
-- Bare names get our own realm appended (invite/whisper senders on the same
-- realm arrive without the suffix).
function Auto.NormalizeName(name)
    name = trim(name)
    if name == "" then return name end
    if name:find("-", 1, true) then
        return name
    end
    return name .. "-" .. selfRealm()
end

-- The autoGroup / autoSummon / autoGossip / autoQuest blocks for our current
-- faction. Falls back to Alliance defaults when faction is unknown pre-login.
local function factionSettings()
    local faction = UnitFactionGroup and UnitFactionGroup("player") or nil
    if faction ~= "Alliance" and faction ~= "Horde" then faction = "Alliance" end
    return Store.GetFactionSettings(faction)
end
local function agBlock()  return factionSettings().autoGroup  end
local function asBlock()  return factionSettings().autoSummon end
local function agoBlock() return factionSettings().autoGossip end
local function aqBlock()  return factionSettings().autoQuest  end

local function globalToggles() return Store.GetSettings() end

----------------------------------------------------------------------
-- Trust categories (spec §5)
--
-- roster  = a character known to the mesh (any account bucket, incl. our own
--           alts, plus any online peer's current character).
-- guild   = present in the cached guild social set.
-- friends = present in the cached friends social set.
-- whitelist = per-faction Name-Realm whitelist (always bypasses gating).
----------------------------------------------------------------------

-- Roster membership is testable in isolation by injecting the accounts table
-- and peer set; the live wrappers below feed it the real store/mesh state.
function Auto.IsRosterIn(nameRealm, accounts, peers)
    if accounts then
        for _, bucket in pairs(accounts) do
            if (bucket.characters and bucket.characters[nameRealm])
               or (bucket.homeless and bucket.homeless[nameRealm]) then
                return true
            end
        end
    end
    if peers then
        for _, p in pairs(peers) do
            if p.name == nameRealm then return true end
        end
    end
    return false
end

function Auto.IsRoster(nameRealm)
    local data = Store.GetData()
    local peers = ns.Mesh and ns.Mesh.peers or nil
    return Auto.IsRosterIn(nameRealm, data and data.accounts, peers)
end

function Auto.IsGuild(nameRealm)
    local social = Store.GetSocial()
    return social and social.guild and social.guild[nameRealm] == true
end

function Auto.IsFriend(nameRealm)
    local social = Store.GetSocial()
    return social and social.friends and social.friends[nameRealm] == true
end

-- Pure decision function for the invite-accept truth table. `ctx` carries the
-- autoGroup toggles + membership predicates so the self-test can drive it with
-- no game state. Returns (accept:boolean, category:string|nil).
--
-- Whitelist bypasses every toggle. Otherwise each ENABLED accept-toggle admits
-- its category independently (a member of two categories is accepted if EITHER
-- toggle is on), and acceptFromAnyone admits everyone.
function Auto.DecideAccept(ctx)
    if ctx.whitelisted then return true, "whitelist" end
    if ctx.acceptFromAnyone then return true, "anyone" end
    if ctx.acceptFromRoster and ctx.isRoster then return true, "roster" end
    if ctx.acceptFromGuild and ctx.isGuild then return true, "guild" end
    if ctx.acceptFromFriends and ctx.isFriend then return true, "friends" end
    return false, nil
end

-- Whitelist membership gated by the master enable toggle (item 35). Default-on
-- semantics preserved: a nil `whitelistEnabled` (older DB) still bypasses.
local function whitelisted(ag, nameRealm)
    return (ag.whitelistEnabled ~= false
        and ag.whitelist and ag.whitelist[nameRealm] == true) or false
end
Auto._Whitelisted = whitelisted

-- Live wrapper: build the ctx from settings + membership and decide.
function Auto.ShouldAcceptInvite(nameRealm)
    local ag = agBlock()
    return Auto.DecideAccept({
        whitelisted      = whitelisted(ag, nameRealm),
        acceptFromAnyone = ag.acceptFromAnyone == true,
        acceptFromRoster = ag.acceptFromRoster == true,
        acceptFromGuild  = ag.acceptFromGuild == true,
        acceptFromFriends= ag.acceptFromFriends == true,
        isRoster = Auto.IsRoster(nameRealm),
        isGuild  = Auto.IsGuild(nameRealm),
        isFriend = Auto.IsFriend(nameRealm),
    })
end

-- Pure decision function for keyword-invite SENDING (item 22). The reference
-- gates SENDS per trust category independently, mirroring the four accept-from
-- gates: sendToRoster / sendToGuild / sendToFriends / sendToAnyone. Whitelist
-- always bypasses. A member of multiple categories is invited if ANY of its
-- enabled send-gates admits it. Returns (invite:boolean, category:string|nil).
function Auto.DecideKeywordInvite(ctx)
    if ctx.whitelisted then return true, "whitelist" end
    if ctx.sendToAnyone then return true, "anyone" end
    if ctx.sendToRoster and ctx.isRoster then return true, "roster" end
    if ctx.sendToGuild  and ctx.isGuild  then return true, "guild" end
    if ctx.sendToFriends and ctx.isFriend then return true, "friends" end
    return false, nil
end

function Auto.ShouldInviteKeyword(nameRealm)
    local ag = agBlock()
    return Auto.DecideKeywordInvite({
        whitelisted   = whitelisted(ag, nameRealm),
        sendToRoster  = ag.sendToRoster == true,
        sendToGuild   = ag.sendToGuild == true,
        sendToFriends = ag.sendToFriends == true,
        sendToAnyone  = ag.sendToAnyone == true,
        isRoster = Auto.IsRoster(nameRealm),
        isGuild  = Auto.IsGuild(nameRealm),
        isFriend = Auto.IsFriend(nameRealm),
    })
end

----------------------------------------------------------------------
-- Invite automation (spec §5, §7)
----------------------------------------------------------------------

-- Accept an incoming party invite when the inviter clears the trust gate.
function Auto.OnPartyInvite(name)
    local nameRealm = Auto.NormalizeName(name)
    local accept, cat = Auto.ShouldAcceptInvite(nameRealm)
    if not accept then return end
    if AcceptGroup then AcceptGroup() end
    -- Dismiss the Blizzard confirmation popup(s) so nothing lingers on screen.
    if StaticPopup_Hide then
        StaticPopup_Hide("PARTY_INVITE")
        StaticPopup_Hide("PARTY_INVITE_XREALM")
    end
    ns:Print(("auto-accepted invite from %s (%s)."):format(nameRealm, cat or "?"))
end

-- Keyword matcher: is the FIRST word of `text` the (case-insensitive) keyword?
-- Accepts "inv" and "inv me" alike; rejects "reinvite". Pure + self-tested.
function Auto.MatchKeyword(text, keyword)
    keyword = lower(trim(keyword))
    if keyword == "" then return false end
    local first = lower(trim(text)):match("^(%S+)")
    return first == keyword
end

-- Whisper handler: keyword auto-invite + the leader-redirect protocol.
--
-- Leader-redirect ("DSN:LEAD:Name-Realm") is OUR OWN protocol tag (not the
-- spec source's). Two directions:
--   inbound  "DSN:LEAD:X" — a peer tells us the real inviter is X, so we
--            re-whisper the keyword to X and route ourselves onto their group.
--   outbound when someone whispers our keyword but a redirectLeader is
--            configured (and it isn't us), we answer "DSN:LEAD:<leader>" so the
--            requester's client re-routes to that leader instead of us.
function Auto.OnWhisper(text, playerName)
    text = text or ""
    local ag = agBlock()

    -- Inbound redirect: obey a peer's routing instruction.
    local leader = text:match("^DSN:LEAD:(.+)$")
    if leader then
        leader = trim(leader)
        if leader ~= "" and leader ~= selfNameRealm() then
            local kw = ag.inviteKeyword or "inv"
            if SendChatMessage then SendChatMessage(kw, "WHISPER", nil, leader) end
        end
        return
    end

    -- Keyword path.
    if not Auto.MatchKeyword(text, ag.inviteKeyword or "inv") then return end
    local nameRealm = Auto.NormalizeName(playerName)

    -- Outbound redirect: hand the requester off to the designated leader.
    local redirect = ag.redirectLeader
    if type(redirect) == "string" and redirect ~= "" and redirect ~= selfNameRealm() then
        if SendChatMessage then
            SendChatMessage("DSN:LEAD:" .. redirect, "WHISPER", nil, nameRealm)
        end
        return
    end

    -- We handle it: invite the requester if they clear the send gate.
    local ok, cat = Auto.ShouldInviteKeyword(nameRealm)
    if ok and C_PartyInfo and C_PartyInfo.InviteUnit then
        C_PartyInfo.InviteUnit(nameRealm)
        ns:Print(("keyword invite -> %s (%s)."):format(nameRealm, cat or "?"))
    end
end

----------------------------------------------------------------------
-- MESH-ASSEMBLY GATE  (1.0.2 — fixes the live 1.0.1 raid defect)
--
-- 1.0.1 wired GROUP_ROSTER_UPDATE straight into the convert+assist pass, so
-- every roster tick of ANY group the player happened to be in ran it. In a
-- 40-man raid the owner had merely JOINED, that fired the all-assist step over
-- and over and the client answered:
--
--     [ADDON_ACTION_BLOCKED] AddOn 'Daseeki-Nexus' tried to call the
--     protected function 'SetEveryoneIsAssistant()'.
--
-- Two independent defects, fixed together.
--
-- (1) PROTECTED CALL. SetEveryoneIsAssistant is protected on 1.15.9 — the block
--     is the proof. pcall / ns:SafeCall CANNOT launder a protected call:
--     ADDON_ACTION_BLOCKED is a client refusal, not a Lua error, so the pcall
--     returns "success" while nothing happened and the attempt spreads taint.
--     The API catalog records existence + signatures only and carries no
--     protection flags, so there is no VERIFIED-unprotected per-member
--     substitute to swap in either (PromoteToAssistant et al. exist, but their
--     protection status is unverified — shipping an unverified alternative
--     would just move the same block one function along). The step is therefore
--     deleted outright: no protected group API is called from this addon at
--     all, and the autoAssistAll toggle now prints a one-time hint instead.
--     harness.lua's "protected-API gate" fails the build if the name ever
--     reappears in call form anywhere in the .toc.
--
-- (2) CONTEXT MISFIRE. The pass now hard-gates on ALL THREE of:
--       * ARMED — our own InviteOnline flow started an assembly this session
--                 and the window has not expired (self-clearing, so a stale
--                 flag can never adopt a later unrelated group),
--       * LEADER — UnitIsGroupLeader("player"),
--       * OURS  — the other members are (mostly) mesh-owned characters.
--     In somebody else's raid nothing is armed, so the handler returns on its
--     first line: zero group API touched, zero attempts, zero events acted on.
----------------------------------------------------------------------

-- How long an armed assembly stays live. Invites trickle in over several
-- seconds; a minute is generous, and expiry is checked lazily so no timer is
-- needed to take the flag back down.
Auto.ASSEMBLY_WINDOW = 60

-- At least this share of the OTHER group members must be mesh-owned before we
-- accept the group as one of ours.
Auto.ASSEMBLY_MESH_SHARE = 0.5

Auto._assemblyUntil   = nil     -- GetTime() deadline; nil = not armed
Auto._assistHintShown = false   -- one hint per armed episode

local function nowSecs()
    return (GetTime and GetTime()) or 0
end

-- Arm the assembly window. ONLY Auto.InviteOnline calls this — it is the single
-- point at which the player says "build my group", and nothing else in the
-- addon may open the gate.
function Auto.ArmAssembly()
    Auto._assemblyUntil   = nowSecs() + Auto.ASSEMBLY_WINDOW
    Auto._assistHintShown = false
end

function Auto.DisarmAssembly()
    Auto._assemblyUntil = nil
end

-- Armed AND unexpired. Expiry self-clears on read. `t` is injectable so the
-- self-tests can drive the window without a clock.
function Auto.IsAssemblyArmed(t)
    if not Auto._assemblyUntil then return false end
    t = t or nowSecs()
    if t > Auto._assemblyUntil then
        Auto._assemblyUntil = nil
        return false
    end
    return true
end

-- Canonical Name-Realm of every OTHER group member. Raid tokens in a raid,
-- party tokens otherwise (party1..N-1 excludes the player; raid1..N does not,
-- so our own name is filtered out either way). READ-ONLY API throughout.
function Auto.GroupMemberNames()
    local out = {}
    local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
    if n <= 1 then return out end
    local raid = (IsInRaid and IsInRaid()) and true or false
    local me = selfNameRealm()
    local last = raid and n or (n - 1)
    for i = 1, last do
        local unit = (raid and "raid" or "party") .. i
        local nm, rlm = UnitName and UnitName(unit)
        if nm and nm ~= "" then
            local full = (rlm and rlm ~= "") and (nm .. "-" .. rlm)
                          or Auto.NormalizeName(nm)
            if full ~= me then out[#out + 1] = full end
        end
    end
    return out
end

-- Share of `names` the mesh owns. Pure over (names, isRoster) so the self-test
-- drives it with a fake predicate. Returns (share 0..1, owned, total).
function Auto.MeshShare(names, isRoster)
    local total = names and #names or 0
    if total == 0 then return 0, 0, 0 end
    local owned = 0
    for i = 1, total do
        if isRoster(names[i]) then owned = owned + 1 end
    end
    return owned / total, owned, total
end

-- Pure gate decision. ctx:
--   armed     -- our InviteOnline flow armed this session, window still open
--   inGroup   -- GetNumGroupMembers() > 1
--   isLeader  -- UnitIsGroupLeader("player")
--   meshOwned -- count of OTHER members the mesh owns
--   meshShare -- that count as a share of the other members (0..1)
-- Returns (ok:boolean, reason:string). Every rejection has its own reason so a
-- failing self-test names the gate that fired.
function Auto.DecideAssembly(ctx)
    if not ctx.armed    then return false, "not-armed"       end
    if not ctx.inGroup  then return false, "no-group"        end
    if not ctx.isLeader then return false, "not-leader"      end
    if (ctx.meshOwned or 0) < 1 then return false, "no-mesh-members" end
    if (ctx.meshShare or 0) < Auto.ASSEMBLY_MESH_SHARE then
        return false, "foreign-group"
    end
    return true, "ours"
end

-- Live wrapper. Reads the ARMED flag first and bails before touching any group
-- API — that first line is what makes an external raid completely inert.
function Auto.MayAssemble()
    if not Auto.IsAssemblyArmed() then return false, "not-armed" end
    local names = Auto.GroupMemberNames()
    local share, owned = Auto.MeshShare(names, Auto.IsRoster)
    return Auto.DecideAssembly({
        armed     = true,
        inGroup   = ((GetNumGroupMembers and GetNumGroupMembers()) or 0) > 1,
        isLeader  = (UnitIsGroupLeader and UnitIsGroupLeader("player")) and true or false,
        meshOwned = owned,
        meshShare = share,
    })
end

----------------------------------------------------------------------
-- Invite automation, continued
----------------------------------------------------------------------

-- Mass-invite every online mesh character. Source of truth is the mesh peer
-- table: each online peer's `name` is that account's currently-logged-in
-- character. Unless the caller opts out, this ARMS the assembly window (see the
-- gate block above) and schedules the convert pass once the invites settle.
--
-- Public surface: minimap left-click, dashboard "Invite Online", /dsn invite.
function Auto.InviteOnline(skipConvert)
    -- Arm BEFORE the invites go out: the roster updates they provoke arrive
    -- while the invites are still landing, and those are exactly the ticks the
    -- convert pass needs to see.
    if not skipConvert then Auto.ArmAssembly() end

    local invited = 0
    local me = selfNameRealm()
    local peers = ns.Mesh and ns.Mesh.peers or nil
    if peers and C_PartyInfo and C_PartyInfo.InviteUnit then
        for _, p in pairs(peers) do
            if p.online and p.name and p.name ~= me then
                C_PartyInfo.InviteUnit(p.name)
                invited = invited + 1
            end
        end
    end
    if invited > 0 then
        ns:Print(("invited %d online mesh character(s)."):format(invited))
    else
        ns:Print("no online mesh characters to invite.")
    end
    if not skipConvert then
        -- Let the invites land before converting the group.
        if C_Timer and C_Timer.After then
            C_Timer.After(2, function() ns:SafeCall(Auto.MaybeConvertRaid) end)
        else
            Auto.MaybeConvertRaid()
        end
    end
    return invited
end

-- All-Assist is a PROTECTED switch: Blizzard reserves it for the player, from
-- the raid menu. The most an addon may legally do is say so — once, and only
-- while WE are the ones assembling the group (callers reach here through the
-- assembly gate). Nothing here calls a protected function.
function Auto.MaybeAssistHint(db)
    db = db or globalToggles()
    if not db.autoAssistAll then return false end
    if Auto._assistHintShown then return false end
    if not (IsInRaid and IsInRaid()) then return false end
    if IsEveryoneAssistant and IsEveryoneAssistant() then return false end
    Auto._assistHintShown = true
    ns:Print("raid is up — tick |cffffd200All Assist|r in the raid menu. "
          .. "That switch is protected: only you can flip it, no addon may.")
    return true
end

-- Convert the party to a raid, gated on its global toggle AND on the whole
-- mesh-assembly gate. Idempotent: safe to call repeatedly as members trickle
-- in. Returns the gate reason so the self-tests can assert WHY it did nothing.
function Auto.MaybeConvertRaid()
    local ok, reason = Auto.MayAssemble()
    if not ok then return false, reason end

    local db = globalToggles()
    if db.autoConvertToRaid
       and not (IsInRaid and IsInRaid())
       and GetNumGroupMembers and GetNumGroupMembers() > 1 then
        if ConvertToRaid then ConvertToRaid() end   -- GLOBAL (see header note)
    end

    Auto.MaybeAssistHint(db)

    -- Once the raid exists the assembly is finished — everything still
    -- outstanding (All Assist) belongs to the player — so drop the flag
    -- immediately rather than leaving it live for the rest of the window.
    if IsInRaid and IsInRaid() then Auto.DisarmAssembly() end
    return true, reason
end

-- GROUP_ROSTER_UPDATE entry point. The armed check is deliberately the FIRST
-- statement: in somebody else's group (the overwhelmingly common case) this
-- returns having read one addon-local field and nothing else.
function Auto.OnRosterUpdate()
    if not Auto.IsAssemblyArmed() then return false end
    return (Auto.MaybeConvertRaid())
end

----------------------------------------------------------------------
-- Summon automation (spec §5, §7)
----------------------------------------------------------------------

-- Canonical trigger-buff catalog: buffKey -> aura-name prefix. The user's
-- autoSummon.triggers set (options.lua wires the UI in N3) references these
-- keys; a freshly-gained trigger buff within the window means "I'm buffed and
-- want the summon to raid". Exposed so options.lua can enumerate them.
-- All 10 world buffs are summon triggers (item 23): the reference gates summon
-- acceptance on holding ANY of DMF, Ony, ZG, DMT AP/SP/STAM, Songflower, Rend,
-- Battle Shout, FFF. (Prior build had only 7 — no dmf/battleShout/fff.)
Auto.SUMMON_TRIGGER_BUFFS = {
    { key = "dragonslayer", prefix = "rallying cry of the dragonslayer" },
    { key = "warchief",     prefix = "warchief's blessing" },
    { key = "zandalar",     prefix = "spirit of zandalar" },
    { key = "songflower",   prefix = "songflower serenade" },
    { key = "fengus",       prefix = "fengus' ferocity" },
    { key = "moldar",       prefix = "mol'dar's moxie" },
    { key = "slipkik",      prefix = "slip'kik's savvy" },
    { key = "dmf",          prefix = "sayge's dark fortune" },
    { key = "battleShout",  prefix = "battle shout" },
    { key = "fff",          prefix = "fervor of the first feast" },  -- seasonal [verify prefix]
}

-- Most-recent trigger-buff gain timestamp (GetTime seconds). Refreshed as
-- configured trigger buffs newly appear on the player.
Auto._lastTriggerGain = nil
Auto._triggerPresent  = {}   -- [key] = true while the aura is up

-- Rescan player auras; stamp a gain time when a *configured* trigger buff
-- transitions absent->present. Cheap (fires off UNIT_AURA, already debounced by
-- WoW's own coalescing for the player unit).
function Auto.ScanTriggerBuffs()
    local triggers = asBlock().triggers or {}
    if not (C_UnitAuras and C_UnitAuras.GetBuffDataByIndex) then return end
    local nowUp = {}
    for i = 1, 40 do
        local aura = C_UnitAuras.GetBuffDataByIndex("player", i)
        if not aura then break end
        local nm = lower(aura.name)
        for _, def in ipairs(Auto.SUMMON_TRIGGER_BUFFS) do
            if nm:find(def.prefix, 1, true) == 1 then
                nowUp[def.key] = true
                if triggers[def.key] and not Auto._triggerPresent[def.key] then
                    Auto._lastTriggerGain = GetTime()
                end
            end
        end
    end
    Auto._triggerPresent = nowUp
end

-- Age (seconds) of the most-recent trigger-buff gain, or nil if none seen.
function Auto.TriggerBuffAge()
    if not Auto._lastTriggerGain then return nil end
    return GetTime() - Auto._lastTriggerGain
end

-- Pure summon-gate decision matrix (spec §5). `ctx`:
--   enabled, alwaysAccept, dropOnTaxiPvp (settings)
--   triggerAge (seconds since last trigger gain, or nil), window (seconds)
--   onTaxiOrPvpDrop (boolean)
-- Returns (accept:boolean, reason:string).
function Auto.DecideSummon(ctx)
    if not ctx.enabled then return false, "disabled" end
    if ctx.alwaysAccept then return true, "always" end
    if ctx.triggerAge ~= nil and ctx.window and ctx.triggerAge <= ctx.window then
        return true, "freshbuff"
    end
    if ctx.dropOnTaxiPvp and ctx.onTaxiOrPvpDrop then
        return true, "taxipvp"
    end
    return false, "no-trigger"
end

-- Live wrapper reading settings + world state.
function Auto.EvaluateSummon()
    local as = asBlock()
    local onTaxi = UnitOnTaxi and UnitOnTaxi("player") or false
    return Auto.DecideSummon({
        enabled       = as.enabled == true,
        alwaysAccept  = as.alwaysAccept == true,
        dropOnTaxiPvp = as.dropOnTaxiPvp == true,
        triggerAge    = Auto.TriggerBuffAge(),
        window        = as.freshBuffWindow or 19,
        onTaxiOrPvpDrop = onTaxi and true or false,
    })
end

-- Perform the accept: snapshot state first (auras are unreliable across the
-- teleport), then confirm through the catalog API.
function Auto.AcceptSummon(reason)
    -- Pre-teleport snapshot so the dashboard keeps our buffs/location.
    if ns.Tracker and ns.Tracker.Capture then ns:SafeCall(ns.Tracker.Capture) end
    if C_SummonInfo and C_SummonInfo.ConfirmSummon then
        C_SummonInfo.ConfirmSummon()
    end
    if StaticPopup_Hide then StaticPopup_Hide("CONFIRM_SUMMON") end
    ns:Print(("auto-accepted summon (%s)."):format(reason or "?"))
end

Auto._pendingSummon = false

function Auto.OnConfirmSummon()
    local accept, reason = Auto.EvaluateSummon()
    if not accept then
        Auto._pendingSummon = false
        return
    end
    -- Combat-deferred: wait for PLAYER_REGEN_ENABLED before teleporting out.
    if InCombatLockdown and InCombatLockdown() then
        Auto._pendingSummon = true
        Auto._pendingReason = reason
        ns:Print("summon pending: will accept when combat ends.")
        return
    end
    Auto.AcceptSummon(reason)
end

-- Combat ended: honour a deferred summon if the dialog is still live.
function Auto.OnRegenEnabled()
    if not Auto._pendingSummon then return end
    Auto._pendingSummon = false
    -- Re-check the dialog is still open (non-zero time left) before confirming.
    local timeLeft = C_SummonInfo and C_SummonInfo.GetSummonConfirmTimeLeft
        and C_SummonInfo.GetSummonConfirmTimeLeft() or 0
    if timeLeft and timeLeft > 0 then
        Auto.AcceptSummon(Auto._pendingReason or "deferred")
    end
end

----------------------------------------------------------------------
-- Gossip automation (spec §5) — C_GossipInfo namespace
----------------------------------------------------------------------

-- Dire Maul tribute guard buff options (Mol'dar / Fengus / Slip'kik plus the
-- Mizzle/Komcrush lines). Matched by keyword against option display text.
local DMT_KEYWORDS = {
    "moxie", "ferocity", "savvy", "mol'dar", "fengus", "slip'kik",
    "mizzle", "komcrush", "spare", "free",
}
-- BWL Orb of Command entry gossip.
local BWL_KEYWORDS = { "orb of command", "enter", "blackwing" }

-- Map a Sayge buff-type setting to keyword fragments that appear in the fortune
-- option text. NOTE: Sayge's answer strings are philosophical statements; the
-- buff-type keyword may not literally appear, so the store may also hold the
-- literal option substring in buffType[CLASS]. In-game verification confirms
-- the exact strings (see deliverable notes).
local SAYGE_TYPE_KEYWORDS = {
    damage      = { "damage" },
    resistance  = { "resist" },
    resist      = { "resist" },
    armor       = { "armor" },
    spirit      = { "spirit" },
    intellect   = { "intellect", "intelligence" },
    intelligence= { "intellect", "intelligence" },
    stamina     = { "stamina" },
    strength    = { "strength" },
    agility     = { "agility" },
    stats       = { "stats", "all" },
}

-- Select the first gossip option whose display name contains any keyword.
-- Returns true if a selection was made. Pure over the (options, keywords) pair
-- so the matcher is self-testable; the live SelectOption call is guarded.
function Auto.FindOptionByKeywords(options, keywords)
    if not options then return nil end
    for _, opt in ipairs(options) do
        local nm = lower(opt.name)
        for _, kw in ipairs(keywords) do
            if nm:find(kw, 1, true) then
                return opt.gossipOptionID, opt
            end
        end
    end
    return nil
end

local function selectGossipOption(optionID)
    if optionID ~= nil and C_GossipInfo and C_GossipInfo.SelectOption then
        C_GossipInfo.SelectOption(optionID)
        return true
    end
    return false
end

-- Session guard so we don't re-trigger Sayge / close-cookie in a loop.
Auto._saygeDone = false

function Auto.HandleSayge(options, dmf)
    -- If we already took the fortune this visit and skip-cookie is on, close.
    if Auto._saygeDone then
        if dmf.skipCookie and C_GossipInfo and C_GossipInfo.CloseGossip then
            C_GossipInfo.CloseGossip()
        end
        return true
    end

    -- Determine desired buff-type for our class.
    local _, classTag = UnitClass("player")
    local want = dmf.buffType and dmf.buffType[classTag]
    if not want or want == "" then return false end

    -- Build keyword set: mapped fragments plus the literal setting (allows the
    -- user to store the exact option substring when the mapping is ambiguous).
    local keywords = {}
    local mapped = SAYGE_TYPE_KEYWORDS[lower(want)]
    if mapped then for _, k in ipairs(mapped) do keywords[#keywords + 1] = k end end
    keywords[#keywords + 1] = lower(want)

    local optionID = Auto.FindOptionByKeywords(options, keywords)
    if optionID == nil then
        -- No buff-type match yet: advance a single "hear the fortune" style
        -- option so the next GOSSIP_SHOW presents the buff choices.
        if #options == 1 then
            selectGossipOption(options[1].gossipOptionID)
        end
        return false
    end
    if selectGossipOption(optionID) then
        Auto._saygeDone = true
        return true
    end
    return false
end

function Auto.OnGossipShow()
    if not (C_GossipInfo and C_GossipInfo.GetOptions) then return end
    local ago = agoBlock()
    local options = C_GossipInfo.GetOptions()
    if not options or #options == 0 then return end

    if ago.dmt then
        local id = Auto.FindOptionByKeywords(options, DMT_KEYWORDS)
        if id ~= nil then selectGossipOption(id) return end
    end
    if ago.bwl then
        local id = Auto.FindOptionByKeywords(options, BWL_KEYWORDS)
        if id ~= nil then selectGossipOption(id) return end
    end
    if ago.dmf and ago.dmf.enabled then
        Auto.HandleSayge(options, ago.dmf)
    end
end

----------------------------------------------------------------------
-- Quest automation (spec §5) — global quest-frame API
----------------------------------------------------------------------

-- Title keyword sets per enabled category. Quest IDs vary by faction/coin type
-- so we match on the stable title text.
local QUEST_KEYWORDS = {
    eko     = { "e'ko", "eko" },                         -- Winterspring E'ko
    zgCoins = { "coin", "bijou", "gurubashi", "vilebranch",
                "witherbark", "sandfury", "skullsplitter", "bloodscalp" },
    zanza   = { "zanza", "honor token", "zulian", "razzashi", "hakkari" },
    roids   = { "r.o.i.d.s", "roids" },
}

-- Which categories are enabled right now (as a keyword pool + a flag map).
local function activeQuestCategories()
    local aq = aqBlock()
    local pool, flags = {}, {}
    local function add(name, on)
        flags[name] = on
        if on then for _, k in ipairs(QUEST_KEYWORDS[name]) do pool[#pool + 1] = k end end
    end
    add("eko",     aq.eko == true)
    add("zgCoins", aq.zgCoins == true)
    add("zanza",   aq.zanza and aq.zanza.enabled == true)
    add("roids",   aq.roids == true)
    return pool, flags
end

-- Does a quest title match any enabled category? Pure helper (self-tested).
function Auto.TitleMatches(title, pool)
    local t = lower(title)
    for _, kw in ipairs(pool) do
        if t:find(kw, 1, true) then return true end
    end
    return false
end

-- QUEST_GREETING: a multi-quest NPC (E'ko / coin / token turn-ins). Select the
-- first active quest whose title matches an enabled category; then handle
-- available quests (accept) the same way.
function Auto.OnQuestGreeting()
    local pool = activeQuestCategories()
    if #pool == 0 then return end

    local nActive = GetNumActiveQuests and GetNumActiveQuests() or 0
    for i = 1, nActive do
        local title = GetActiveTitle and GetActiveTitle(i)
        if title and Auto.TitleMatches(title, pool) then
            if SelectActiveQuest then SelectActiveQuest(i) end
            return
        end
    end

    local nAvail = GetNumAvailableQuests and GetNumAvailableQuests() or 0
    for i = 1, nAvail do
        local title = GetAvailableTitle and GetAvailableTitle(i)
        if title and Auto.TitleMatches(title, pool) then
            if SelectAvailableQuest then SelectAvailableQuest(i) end
            return
        end
    end
end

-- QUEST_DETAIL: a quest is being offered. Accept it if it belongs to an
-- enabled category (R.O.I.D.S. accept, coin/token re-pickups).
function Auto.OnQuestDetail()
    local pool = activeQuestCategories()
    if #pool == 0 then return end
    local title = GetTitleText and GetTitleText()
    if title and Auto.TitleMatches(title, pool) then
        if AcceptQuest then AcceptQuest() end
    end
end

-- QUEST_PROGRESS: turn-in requirements screen. Complete when the game says the
-- quest is completable and it belongs to an enabled category.
function Auto.OnQuestProgress()
    local pool = activeQuestCategories()
    if #pool == 0 then return end
    local title = GetTitleText and GetTitleText()
    if title and Auto.TitleMatches(title, pool) then
        if IsQuestCompletable and IsQuestCompletable() and CompleteQuest then
            CompleteQuest()
        end
    end
end

-- Zanza reward priority: pick the reward whose name best matches the user's
-- priority list; fall back to the first choice. Pure over (choices, priority).
-- `choices` is an array of { index, name }.
function Auto.PickReward(choices, priority)
    if not choices or #choices == 0 then return nil end
    if priority then
        for _, want in ipairs(priority) do
            local w = lower(want)
            for _, c in ipairs(choices) do
                if lower(c.name):find(w, 1, true) then return c.index end
            end
        end
    end
    return choices[1].index
end

-- QUEST_COMPLETE: take the reward. For a single fixed reward pass 1; for a
-- choice of rewards (zanza tokens) honour the priority list. Records the
-- expected item for bag-delta verification.
function Auto.OnQuestComplete()
    local pool, flags = activeQuestCategories()
    if #pool == 0 then return end
    local title = GetTitleText and GetTitleText()
    if not (title and Auto.TitleMatches(title, pool)) then return end

    local nChoices = GetNumQuestChoices and GetNumQuestChoices() or 0
    local rewardIndex = 1
    if nChoices > 1 then
        -- Build the choice list from the quest-item info.
        local choices = {}
        for i = 1, nChoices do
            local name = GetQuestItemInfo and select(1, GetQuestItemInfo("choice", i)) or nil
            choices[#choices + 1] = { index = i, name = name or "" }
        end
        local priority = flags.zanza and aqBlock().zanza and aqBlock().zanza.priority or nil
        rewardIndex = Auto.PickReward(choices, priority) or 1
        -- Record expected reward name for bag-delta verification.
        for _, c in ipairs(choices) do
            if c.index == rewardIndex then Auto._expectedReward = lower(c.name) end
        end
    else
        Auto._expectedReward = nil
    end
    if GetQuestReward then GetQuestReward(rewardIndex) end
end

-- Bag-delta verification: after a reward is taken, a follow-up bag update
-- should show the item. We keep this lightweight — log confirmation once the
-- expected reward name is seen in the reward flow. (Full inventory scanning is
-- deferred to the tracker's item pass; here we just clear the expectation.)
function Auto.OnBagUpdate()
    if Auto._expectedReward then
        -- The reward was requested; assume delivery on the next bag tick and
        -- clear. A mismatch would leave the item un-turned which the user sees.
        Auto._expectedReward = nil
    end
end

----------------------------------------------------------------------
-- Auto-repair (spec §5) — MERCHANT_SHOW + RepairAllItems (globals)
----------------------------------------------------------------------

function Auto.OnMerchantShow()
    if not aqBlock().autoRepair then return end
    if not (CanMerchantRepair and CanMerchantRepair()) then return end
    local cost = GetRepairAllCost and GetRepairAllCost() or 0
    if cost and cost > 0 and (GetMoney and GetMoney() or 0) >= cost then
        if RepairAllItems then RepairAllItems() end
        ns:Print("auto-repaired at vendor.")
    end
end

----------------------------------------------------------------------
-- Zone-change resets (Sayge/session guards clear when we move away)
----------------------------------------------------------------------

function Auto.OnZoneChanged()
    Auto._saygeDone = false
end

----------------------------------------------------------------------
-- Event wiring
----------------------------------------------------------------------

function Auto.OnLogin()
    ns:RegisterEvent("PARTY_INVITE_REQUEST", function(_, name)
        ns:SafeCall(Auto.OnPartyInvite, name)
    end)
    ns:RegisterEvent("CHAT_MSG_WHISPER", function(_, text, playerName)
        ns:SafeCall(Auto.OnWhisper, text, playerName)
    end)
    -- Roster ticks are acted on ONLY inside an armed mesh assembly of our own
    -- (see the gate block): joining someone else's raid must be completely
    -- inert. Auto.OnRosterUpdate owns that check.
    ns:RegisterEvent("GROUP_ROSTER_UPDATE", function()
        ns:SafeCall(Auto.OnRosterUpdate)
    end)

    ns:RegisterEvent("CONFIRM_SUMMON", function()
        ns:SafeCall(Auto.OnConfirmSummon)
    end)
    ns:RegisterEvent("PLAYER_REGEN_ENABLED", function()
        ns:SafeCall(Auto.OnRegenEnabled)
    end)
    ns:RegisterEvent("UNIT_AURA", function(_, unit)
        if unit == "player" then ns:SafeCall(Auto.ScanTriggerBuffs) end
    end)

    ns:RegisterEvent("GOSSIP_SHOW", function()
        ns:SafeCall(Auto.OnGossipShow)
    end)

    ns:RegisterEvent("QUEST_GREETING", function() ns:SafeCall(Auto.OnQuestGreeting) end)
    ns:RegisterEvent("QUEST_DETAIL",   function() ns:SafeCall(Auto.OnQuestDetail) end)
    ns:RegisterEvent("QUEST_PROGRESS", function() ns:SafeCall(Auto.OnQuestProgress) end)
    ns:RegisterEvent("QUEST_COMPLETE", function() ns:SafeCall(Auto.OnQuestComplete) end)
    ns:RegisterEvent("BAG_UPDATE_DELAYED", function() ns:SafeCall(Auto.OnBagUpdate) end)

    ns:RegisterEvent("MERCHANT_SHOW", function() ns:SafeCall(Auto.OnMerchantShow) end)
    ns:RegisterEvent("ZONE_CHANGED_NEW_AREA", function() ns:SafeCall(Auto.OnZoneChanged) end)

    -- Seed trigger-buff presence so a buff already up at login isn't counted
    -- as a fresh gain.
    ns:SafeCall(Auto.ScanTriggerBuffs)
    Auto._lastTriggerGain = nil
end

----------------------------------------------------------------------
-- Self-tests (pure Lua; registered as suite "auto")
----------------------------------------------------------------------

local function testTrustTruthTable()
    -- roster member, only acceptFromRoster on -> accept as roster.
    local a, cat = Auto.DecideAccept({
        acceptFromRoster = true, isRoster = true,
    })
    if not (a and cat == "roster") then return false, "roster accept" end

    -- roster member but acceptFromRoster OFF, acceptFromGuild ON and also
    -- guild -> accepted via guild (independent toggles).
    a, cat = Auto.DecideAccept({
        acceptFromRoster = false, isRoster = true,
        acceptFromGuild = true, isGuild = true,
    })
    if not (a and cat == "guild") then return false, "guild independent accept" end

    -- friend only, friends toggle off -> reject.
    a = Auto.DecideAccept({ acceptFromFriends = false, isFriend = true })
    if a then return false, "friend reject when toggle off" end

    -- stranger, acceptFromAnyone -> accept.
    a, cat = Auto.DecideAccept({ acceptFromAnyone = true })
    if not (a and cat == "anyone") then return false, "anyone accept" end

    -- whitelist bypasses everything.
    a, cat = Auto.DecideAccept({ whitelisted = true })
    if not (a and cat == "whitelist") then return false, "whitelist bypass" end

    -- nothing enabled -> reject.
    a = Auto.DecideAccept({ isRoster = true, isGuild = true, isFriend = true })
    if a then return false, "reject with all toggles off" end

    -- keyword-invite per-category send gates (item 22):
    -- roster member, sendToRoster OFF -> reject.
    a = Auto.DecideKeywordInvite({ sendToRoster = false, isRoster = true })
    if a then return false, "keyword send roster gate off" end
    -- roster member, sendToRoster ON -> invite as roster.
    a, cat = Auto.DecideKeywordInvite({ sendToRoster = true, isRoster = true })
    if not (a and cat == "roster") then return false, "keyword send roster" end
    -- guild member, only sendToGuild ON (roster gate off) -> invite as guild.
    a, cat = Auto.DecideKeywordInvite({ sendToRoster = false, sendToGuild = true,
                                        isGuild = true, isRoster = true })
    if not (a and cat == "guild") then return false, "keyword send guild independent" end
    -- friend, sendToFriends OFF -> reject.
    a = Auto.DecideKeywordInvite({ sendToFriends = false, isFriend = true })
    if a then return false, "keyword send friends gate off" end
    -- stranger, sendToAnyone ON -> invite.
    a, cat = Auto.DecideKeywordInvite({ sendToAnyone = true })
    if not (a and cat == "anyone") then return false, "keyword send anyone" end
    -- whitelist bypasses even with every send gate off.
    a, cat = Auto.DecideKeywordInvite({ whitelisted = true })
    if not (a and cat == "whitelist") then return false, "keyword whitelist bypass" end
    -- nothing enabled -> reject.
    a = Auto.DecideKeywordInvite({ isRoster = true, isGuild = true, isFriend = true })
    if a then return false, "keyword reject all gates off" end

    -- whitelist ENABLE toggle (item 35): a listed name bypasses only when enabled.
    local wl = { ["A-B"] = true }
    if not Auto._Whitelisted({ whitelist = wl, whitelistEnabled = true }, "A-B") then
        return false, "whitelist enabled admits listed name"
    end
    if Auto._Whitelisted({ whitelist = wl, whitelistEnabled = false }, "A-B") then
        return false, "whitelist disabled blocks listed name"
    end
    if not Auto._Whitelisted({ whitelist = wl }, "A-B") then
        return false, "nil whitelistEnabled defaults to on (back-compat)"
    end
    return true
end

-- The mesh-assembly gate (1.0.2 defect fix). Pure layer only; harness.lua's
-- "assembly-gate live-path" section drives the real event entry point against
-- stubbed group API for the end-to-end scenarios.
local function testAssemblyGate()
    local S = Auto.ASSEMBLY_MESH_SHARE

    -- The live defect: not armed (we merely JOINED a raid) -> refuse first,
    -- before leader or membership is even consulted.
    local ok, why = Auto.DecideAssembly({
        armed = false, inGroup = true, isLeader = true,
        meshOwned = 39, meshShare = 1,
    })
    if ok or why ~= "not-armed" then return false, "unarmed group must be refused" end

    -- Armed but a member, not the leader -> refuse.
    ok, why = Auto.DecideAssembly({
        armed = true, inGroup = true, isLeader = false,
        meshOwned = 3, meshShare = 1,
    })
    if ok or why ~= "not-leader" then return false, "non-leader must be refused" end

    -- Armed + leader but the group is strangers -> refuse.
    ok, why = Auto.DecideAssembly({
        armed = true, inGroup = true, isLeader = true,
        meshOwned = 1, meshShare = 0.1,
    })
    if ok or why ~= "foreign-group" then return false, "foreign group must be refused" end

    -- Armed + leader but not a single mesh character present -> refuse.
    ok, why = Auto.DecideAssembly({
        armed = true, inGroup = true, isLeader = true,
        meshOwned = 0, meshShare = 0,
    })
    if ok or why ~= "no-mesh-members" then return false, "mesh-free group must be refused" end

    -- Armed + leader but still solo -> refuse (nothing to convert yet).
    ok, why = Auto.DecideAssembly({
        armed = true, inGroup = false, isLeader = true,
        meshOwned = 0, meshShare = 0,
    })
    if ok or why ~= "no-group" then return false, "solo must be refused" end

    -- All three gates satisfied -> the allowed path runs.
    ok, why = Auto.DecideAssembly({
        armed = true, inGroup = true, isLeader = true,
        meshOwned = 4, meshShare = 1,
    })
    if not (ok and why == "ours") then return false, "our own assembly must be allowed" end

    -- Exactly at the share threshold is enough; a hair under is not.
    ok = Auto.DecideAssembly({ armed = true, inGroup = true, isLeader = true,
                               meshOwned = 2, meshShare = S })
    if not ok then return false, "share exactly at threshold admits" end
    ok = Auto.DecideAssembly({ armed = true, inGroup = true, isLeader = true,
                               meshOwned = 2, meshShare = S - 0.01 })
    if ok then return false, "share below threshold refuses" end

    -- MeshShare arithmetic over an injected predicate.
    local mesh = { ["A-R"] = true, ["B-R"] = true }
    local pred = function(n) return mesh[n] == true end
    local share, owned, total = Auto.MeshShare({ "A-R", "B-R", "Pug-R", "Pug2-R" }, pred)
    if not (owned == 2 and total == 4 and share == 0.5) then
        return false, "MeshShare counts"
    end
    share, owned, total = Auto.MeshShare({}, pred)
    if not (share == 0 and owned == 0 and total == 0) then
        return false, "MeshShare on an empty group"
    end
    return true
end

-- Arming lifecycle: only InviteOnline opens the window, it self-clears on
-- expiry, and DisarmAssembly shuts it immediately.
local function testAssemblyArming()
    local saved = Auto._assemblyUntil
    Auto.DisarmAssembly()
    if Auto.IsAssemblyArmed(0) then return false, "starts disarmed" end

    Auto._assemblyUntil = 100
    if not Auto.IsAssemblyArmed(50) then return false, "armed inside the window" end
    if not Auto.IsAssemblyArmed(100) then return false, "armed at the deadline" end
    if Auto.IsAssemblyArmed(101) then return false, "expired past the deadline" end
    -- ... and the expired read must have CLEARED the flag, not just answered no.
    if Auto._assemblyUntil ~= nil then return false, "expiry self-clears the flag" end

    Auto._assemblyUntil = 100
    Auto.DisarmAssembly()
    if Auto.IsAssemblyArmed(50) then return false, "disarm takes effect immediately" end

    Auto._assemblyUntil = saved
    return true
end

local function testSummonMatrix()
    local W = 19
    -- disabled -> never.
    local ok = Auto.DecideSummon({ enabled = false, alwaysAccept = true })
    if ok then return false, "disabled blocks" end
    -- always -> accept.
    ok = select(1, Auto.DecideSummon({ enabled = true, alwaysAccept = true }))
    if not ok then return false, "always accept" end
    -- fresh buff within window -> accept.
    local r
    ok, r = Auto.DecideSummon({ enabled = true, triggerAge = 5, window = W })
    if not (ok and r == "freshbuff") then return false, "freshbuff within window" end
    -- buff too old -> no-trigger.
    ok = Auto.DecideSummon({ enabled = true, triggerAge = 40, window = W })
    if ok then return false, "stale buff rejected" end
    -- no buff, on taxi + dropOnTaxiPvp -> accept.
    ok, r = Auto.DecideSummon({ enabled = true, dropOnTaxiPvp = true, onTaxiOrPvpDrop = true })
    if not (ok and r == "taxipvp") then return false, "taxi drop accept" end
    -- taxi but flag off -> reject.
    ok = Auto.DecideSummon({ enabled = true, dropOnTaxiPvp = false, onTaxiOrPvpDrop = true })
    if ok then return false, "taxi rejected when flag off" end
    -- nothing -> reject.
    ok = Auto.DecideSummon({ enabled = true, window = W })
    if ok then return false, "no trigger rejects" end
    return true
end

local function testKeywordMatcher()
    if not Auto.MatchKeyword("inv", "inv") then return false, "exact" end
    if not Auto.MatchKeyword("INV", "inv") then return false, "case-insensitive" end
    if not Auto.MatchKeyword("  inv me please ", "inv") then return false, "leading word" end
    if Auto.MatchKeyword("reinvite", "inv") then return false, "no substring" end
    if Auto.MatchKeyword("please inv", "inv") then return false, "keyword must be first word" end
    if Auto.MatchKeyword("anything", "") then return false, "empty keyword never matches" end
    return true
end

local function testRosterMembership()
    local accounts = {
        ["1"] = { characters = { ["Alt-Realm"] = {} }, homeless = {} },
        ["2"] = { characters = {}, homeless = { ["Homie-Realm"] = {} } },
    }
    local peers = { ["3"] = { name = "PeerToon-Realm" } }
    if not Auto.IsRosterIn("Alt-Realm", accounts, peers) then return false, "bucket char" end
    if not Auto.IsRosterIn("Homie-Realm", accounts, peers) then return false, "homeless" end
    if not Auto.IsRosterIn("PeerToon-Realm", accounts, peers) then return false, "peer name" end
    if Auto.IsRosterIn("Stranger-Realm", accounts, peers) then return false, "stranger excluded" end
    return true
end

local function testOptionMatcher()
    local options = {
        { name = "Kill King Gordok",        gossipOptionID = 10 },
        { name = "Spare King Gordok",       gossipOptionID = 11 },
    }
    local id = Auto.FindOptionByKeywords(options, DMT_KEYWORDS)
    if id ~= 11 then return false, "DMT spare option" end
    id = Auto.FindOptionByKeywords(options, { "nothing" })
    if id ~= nil then return false, "no match returns nil" end
    return true
end

local function testTitleAndReward()
    local pool = { "e'ko", "zanza" }
    if not Auto.TitleMatches("Winterspring E'ko Delivery", pool) then return false, "title match" end
    if Auto.TitleMatches("Random Quest", pool) then return false, "title non-match" end
    local choices = {
        { index = 1, name = "Zanza's Potent Potables" },
        { index = 2, name = "Spirit of Zanza" },
    }
    if Auto.PickReward(choices, { "spirit of zanza" }) ~= 2 then return false, "priority pick" end
    if Auto.PickReward(choices, { "nonexistent" }) ~= 1 then return false, "priority fallback" end
    if Auto.PickReward(choices, nil) ~= 1 then return false, "no-priority default" end
    return true
end

function Auto.RunSelfTests(verbose)
    local suite = {
        { name = "trust truth table",   fn = testTrustTruthTable },
        { name = "assembly gate",       fn = testAssemblyGate },
        { name = "assembly arming",     fn = testAssemblyArming },
        { name = "summon gate matrix",  fn = testSummonMatrix },
        { name = "keyword matcher",     fn = testKeywordMatcher },
        { name = "roster membership",   fn = testRosterMembership },
        { name = "gossip option match", fn = testOptionMatcher },
        { name = "quest title + reward", fn = testTitleAndReward },
    }
    local allPass = true
    for _, t in ipairs(suite) do
        local ok, why = t.fn()
        if not ok then allPass = false end
        if verbose and ns and ns.Print then
            if ok then ns:Print("  PASS auto/" .. t.name)
            else ns:Print("  FAIL auto/" .. t.name .. " :: " .. tostring(why)) end
        end
    end
    return allPass
end

----------------------------------------------------------------------
-- Registration
----------------------------------------------------------------------

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("auto", Auto.RunSelfTests)
end

-- /dsn invite -> mass alt-invite (overrides the N1 stub).
ns:RegisterSubcommand("invite", function(rest)
    rest = lower(trim(rest))
    local skipConvert = (rest == "noconvert" or rest == "nc")
    Auto.InviteOnline(skipConvert)
end, "mass-invite online mesh characters")

ns:On("LOGIN", function()
    ns:SafeCall(Auto.OnLogin)
end)
