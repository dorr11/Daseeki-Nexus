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
--              GOSSIP-WINDOW QUEST LISTS (1.1.4): .GetAvailableQuests /
--              .GetActiveQuests -> info:table, and .SelectAvailableQuest /
--              .SelectActiveQuest(optionID:number). All eight are in
--              functions.txt AND globals.txt for 1.15.9.68808. The catalog
--              records existence + signatures only, so it cannot tell us
--              whether that one number is a questID or a 1-based index; the
--              driver therefore reads `info.questID` off the list entry and
--              passes THAT, falling back to the entry's ordinal only when the
--              record carries no questID. See Auto.ReadGossipQuests.
--   * Quest:   GetNumActiveQuests / GetActiveTitle / SelectActiveQuest ;
--              GetNumAvailableQuests / GetAvailableTitle / SelectAvailableQuest ;
--              AcceptQuest ; IsQuestCompletable / CompleteQuest ;
--              GetNumQuestChoices / GetQuestItemInfo / GetQuestItemLink /
--              GetQuestID / GetQuestReward ;
--              CloseQuest (all GLOBAL quest-frame functions).
--   * Bags:    C_Container.CalculateTotalNumberOfFreeBagSlots (documented) with
--              a C_Container.GetContainerNumFreeSlots fallback; item counts via
--              C_Item.GetItemCount (documented) falling back to the GetItemCount
--              global. Bank slots are read through ns.Inventory.ScanBank, which
--              already owns the C_Container container walk.
--   * Input:   IsShiftKeyDown ; UnitGUID (NPC identity).
--   * Repair:  CanMerchantRepair / GetRepairAllCost / RepairAllItems (globals).
--
-- EVENTS (catalog events.txt, 1.15.9.68808): Event.GossipInfo.GossipShow /
-- GossipClosed, Event.QuestOffer.QuestGreeting / QuestProgress / QuestFinished,
-- Event.QuestLog.QuestDetail / QuestComplete, Event.Container.BagUpdateDelayed,
-- Event.Bank.BankframeOpened / BankframeClosed.

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

-- GOSSIP_SHOW entry point.
--
-- ORDER MATTERS (1.1.4 defect fix). The gossip-window QUEST path runs FIRST,
-- ahead of every keyword-matched option, and it only ever fires on an exact
-- quest-ID match — which is unambiguous evidence, where an option keyword is a
-- fuzzy substring test. That precedence is what stops a keyword pool (DMT's
-- carries "spare"/"free") from eating the interaction at a quest-giving gossip
-- NPC, and it is the shape the spec's "auto-repair only when the zanza flow is
-- idle" rule needs: a pickable turn-in wins the one interaction we get.
--
-- Shift is checked before anything else: spec §14 / §19.23 — holding Shift while
-- opening gossip skips the whole flow (and auto-repair) at Mau'ari, Vinchaxa,
-- Rin'wosho and Drazial.
function Auto.OnGossipShow()
    if IsShiftKeyDown and IsShiftKeyDown() then return end
    if Auto.HandleGossipQuests() then return end

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
-- Quest automation (spec §5, §14) — global quest-frame API
----------------------------------------------------------------------

-- Title keyword sets per enabled category. These drive the CLASSIC GREETING
-- path only (QUEST_GREETING has no quest IDs to match on); the gossip-window
-- path below is quest-ID-first and never consults them.
--
-- DECONTAMINATION (1.1.4): "zulian" / "razzashi" / "hakkari" used to sit in the
-- `zanza` pool. Per spec §14 those three are the COIN set of quest 8195 — the
-- third-priority Zul'Gurub coin turn-in at Vinchaxa — and have nothing to do
-- with Rin'wosho's zanza flow. Their presence in the zanza pool meant a coin
-- title matched the zanza category and dragged the zanza reward priority onto a
-- coin turn-in. The two pools are now disjoint, and the self-test asserts it.
local QUEST_KEYWORDS = {
    eko     = { "e'ko", "eko" },                         -- Winterspring E'ko
    zgCoins = { "coin", "bijou", "gurubashi", "vilebranch",
                "witherbark", "sandfury", "skullsplitter", "bloodscalp",
                "zulian", "razzashi", "hakkari" },
    zanza   = { "zanza", "honor token" },
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

----------------------------------------------------------------------
-- QUEST IDENTITY (spec §14) — the ID tables the gossip path steers by.
--
-- Everything below is quest-ID-first. The greeting path still matches titles
-- because QUEST_GREETING exposes no IDs, but nothing that rides the gossip
-- window ever selects on a string.
----------------------------------------------------------------------

Auto.ZANZA_NPC          = 14921        -- Rin'wosho the Trader
Auto.ZANZA_QUEST        = 8243         -- "Zanza's Potent Potables" turn-in
Auto.ZANZA_TOKEN        = 19858        -- Zandalar Honor Token
Auto.ZANZA_TOKEN_NEED   = 1

-- Rin'wosho also offers 8196 and 8246. Spec §14, verbatim: they "must never be
-- auto-progressed". 8240 is the fourth Zul'Gurub coin quest, "deliberately not
-- handled". This set is the belt to the ID whitelist's braces: no allowed-ID
-- table may ever contain one of these, and the self-test asserts that too.
Auto.QUEST_NEVER = { [8196] = true, [8246] = true, [8240] = true }

-- Zanza reward priority (spec §14): Swiftness -> Spirit -> Sheen. The ORDER is
-- fixed by the spec; only MEMBERSHIP is user-toggleable (options.lua stores the
-- ticked keys in autoQuest.zanza.priority and its own comment says "Order
-- fixed; membership toggled"). Auto.ZanzaEnabledPicks re-imposes this order on
-- whatever order the checkboxes happened to be clicked in.
Auto.ZANZA_REWARDS = {
    { key = "swiftness", itemID = 20081, name = "swiftness of zanza" },
    { key = "spirit",    itemID = 20079, name = "spirit of zanza"    },
    { key = "sheen",     itemID = 20080, name = "sheen of zanza"     },
}

Auto.ZANZA_REJECT_COOLDOWN  = 30       -- seconds, per reward item
Auto.ZANZA_DELIVERY_TIMEOUT = 5        -- seconds, backstop on the bag verifier

-- Zul'Gurub coin turn-ins at Vinchaxa, in spec priority order. Each needs one
-- of each of its three coins. 8240 is absent on purpose (see QUEST_NEVER).
Auto.ZG_COIN_SETS = {
    { questID = 8238, items = { 19701, 19702, 19703 } },  -- Gurubashi/Vilebranch/Witherbark
    { questID = 8239, items = { 19704, 19705, 19706 } },  -- Sandfury/Skullsplitter/Bloodscalp
    { questID = 8195, items = { 19698, 19699, 19700 } },  -- Zulian/Razzashi/Hakkari
}

-- Enabled zanza picks in the spec's canonical order.
--
-- An EMPTY priority list means "all three" rather than "none": the store ships
-- `priority = {}` and Store.ApplyDefaults recurses into tables, so seeding the
-- three keys there would resurrect a pick the owner deliberately unticked on
-- every login (the same trap documented on autoSummon.triggers). Treating empty
-- as the full spec default gives a fresh install the spec's behaviour from the
-- one parent checkbox, with no store migration and no resurrection. PURE.
function Auto.ZanzaEnabledPicks(priority)
    local out = {}
    if type(priority) ~= "table" or #priority == 0 then
        for _, r in ipairs(Auto.ZANZA_REWARDS) do out[#out + 1] = r.key end
        return out
    end
    local want = {}
    for _, k in ipairs(priority) do want[lower(k)] = true end
    for _, r in ipairs(Auto.ZANZA_REWARDS) do
        if want[r.key] then out[#out + 1] = r.key end
    end
    return out
end

function Auto.ZanzaReward(key)
    for _, r in ipairs(Auto.ZANZA_REWARDS) do
        if r.key == key then return r end
    end
    return nil
end

----------------------------------------------------------------------
-- OWNERSHIP: bags + a SESSION-ONLY bank snapshot (spec §14, §19.22)
--
-- The snapshot is refreshed every time the bank frame opens and on every bag
-- update while it is open. It is a plain Lua field on Auto — it is never
-- written to either SavedVariables table, so a reload or relog forgets it
-- entirely. That is a deliberate privacy choice, not an oversight.
----------------------------------------------------------------------

Auto._bankSnapshot = nil     -- itemID -> count, or nil when never taken
Auto._bankOpen     = false

function Auto.RefreshBankSnapshot()
    local scan = ns.Inventory and ns.Inventory.ScanBank
    if type(scan) ~= "function" then return false end
    local ok, slots = pcall(scan)
    if not ok or type(slots) ~= "table" then return false end
    -- A bank frame open with zero readable slots is a cold read, not an empty
    -- bank (inventory.lua documents the same trap): keep the last honest
    -- snapshot rather than erasing it.
    if #slots == 0 and Auto._bankSnapshot ~= nil then return false end
    local snap = {}
    for _, s in ipairs(slots) do
        local id = tonumber(s.id)
        if id then snap[id] = (snap[id] or 0) + (tonumber(s.count) or 1) end
    end
    Auto._bankSnapshot = snap
    return true
end

-- Session teardown / test reset. Also the shape of "forgotten on reload".
function Auto.ForgetBankSnapshot()
    Auto._bankSnapshot = nil
    Auto._bankOpen     = false
end

-- Carried-bag count only (the snapshot supplies the bank half).
function Auto.BagCount(itemID)
    if C_Item and C_Item.GetItemCount then
        local ok, n = pcall(C_Item.GetItemCount, itemID, false)
        if ok and tonumber(n) then return tonumber(n) end
    end
    if GetItemCount then
        local ok, n = pcall(GetItemCount, itemID, false)
        if ok and tonumber(n) then return tonumber(n) end
    end
    return 0
end

-- PURE: bags + snapshot. The snapshot may legitimately be nil (never banked
-- this session), which reads as "nothing known in the bank", not as zero owned.
function Auto.CountOwned(itemID, bagCount, snapshot)
    local n = tonumber(bagCount) or 0
    if type(snapshot) == "table" then n = n + (tonumber(snapshot[itemID]) or 0) end
    return n
end

function Auto.OwnedCount(itemID)
    return Auto.CountOwned(itemID, Auto.BagCount(itemID), Auto._bankSnapshot)
end

function Auto.FreeBagSlots()
    local C = _G.C_Container
    if C and C.CalculateTotalNumberOfFreeBagSlots then
        local ok, n = pcall(C.CalculateTotalNumberOfFreeBagSlots)
        if ok and tonumber(n) then return tonumber(n) end
    end
    if C and C.GetContainerNumFreeSlots then
        local total = 0
        for bag = 0, 4 do
            local ok, n = pcall(C.GetContainerNumFreeSlots, bag)
            if ok and tonumber(n) then total = total + tonumber(n) end
        end
        return total
    end
    return 0
end

-- PURE GUID parse. "Creature-0-3299-0-14-14921-0000027FA6" -> 14921.
function Auto.ParseNpcID(guid)
    if type(guid) ~= "string" then return nil end
    local kind, id = guid:match("^(%a+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
    if kind == "Creature" or kind == "Vehicle" or kind == "GameObject" then
        return tonumber(id)
    end
    return nil
end

function Auto.NpcID()
    if not UnitGUID then return nil end
    local ok, g = pcall(UnitGUID, "npc")
    if not ok then return nil end
    return Auto.ParseNpcID(g)
end

----------------------------------------------------------------------
-- ZANZA GATES (spec §14) — all pure, all individually asserted.
----------------------------------------------------------------------

-- Bag-space guard WITH the exact-token-count exception: a full bag is fine when
-- the player holds exactly the required token count, because the turn-in
-- consumes that stack and frees the slot in time for the reward. Holding MORE
-- than the required count means the stack survives the turn-in, so a full bag
-- really is full. PURE.
function Auto.DecideBagSpace(freeSlots, tokenCount, needed)
    if (tonumber(freeSlots) or 0) > 0 then return true, "free-slot" end
    if (tonumber(tokenCount) or 0) == (tonumber(needed) or Auto.ZANZA_TOKEN_NEED) then
        return true, "exact-token"
    end
    return false, "bag-full"
end

-- The full entry gate. ctx:
--   enabled, shift, npcID (nil = unknown), tokenCount, tokenNeed, freeSlots
-- Returns (ok:boolean, reason:string). Every refusal names its own gate.
--
-- An UNKNOWN npcID admits: the quest-ID whitelist is the real guard (8243 only
-- exists at Rin'wosho), so a GUID we could not parse must not disable the flow.
-- A KNOWN and wrong npcID refuses.
function Auto.DecideZanzaGate(ctx)
    if not ctx.enabled then return false, "disabled" end
    if ctx.shift then return false, "shift-skip" end
    if ctx.npcID ~= nil and ctx.npcID ~= (ctx.wantNpc or Auto.ZANZA_NPC) then
        return false, "wrong-npc"
    end
    local need = ctx.tokenNeed or Auto.ZANZA_TOKEN_NEED
    if (ctx.tokenCount or 0) < need then return false, "no-token" end
    local ok, why = Auto.DecideBagSpace(ctx.freeSlots, ctx.tokenCount, need)
    if not ok then return false, why end
    return true, "ok"
end

-- Walk the enabled picks in canonical order and return the first that is
-- neither already owned nor inside its rejection cooldown nor absent from the
-- rewards actually on offer. ctx:
--   picks (ordered keys), owned[key], cooldowns[key]=stamp, offered[key],
--   now, cooldown (seconds)
-- Returns (key, reason). Distinct refusal reasons matter: "all-owned" is the
-- one that arms the bag watcher instead of closing the dialog. PURE.
function Auto.NextZanzaPick(ctx)
    local picks = ctx.picks or {}
    if #picks == 0 then return nil, "none-enabled" end
    local cd      = ctx.cooldown or Auto.ZANZA_REJECT_COOLDOWN
    local now     = ctx.now or 0
    local owned   = ctx.owned or {}
    local stamps  = ctx.cooldowns or {}
    local offered = ctx.offered
    local sawUnowned, sawOffered = false, false
    for _, key in ipairs(picks) do
        local isOffered = (offered == nil) or (offered[key] == true)
        if isOffered then
            sawOffered = true
            if not owned[key] then
                sawUnowned = true
                local stamp = stamps[key]
                if not (stamp and (now - stamp) < cd) then
                    return key, "pick"
                end
            end
        end
    end
    if not sawOffered then return nil, "not-offered" end
    if not sawUnowned then return nil, "all-owned" end
    return nil, "all-cooling"
end

-- PURE delivery verdict. `pending` is { itemID, before, at, key }.
function Auto.JudgeDelivery(pending, nowCount, now, timeout)
    if not pending then return "idle" end
    if (tonumber(nowCount) or 0) > (tonumber(pending.before) or 0) then
        return "delivered"
    end
    if ((now or 0) - (pending.at or 0)) >= (timeout or Auto.ZANZA_DELIVERY_TIMEOUT) then
        return "timeout"
    end
    return "pending"
end

-- PURE: highest-priority coin quest whose whole three-coin set is held.
-- `count` is a function(itemID) -> number.
function Auto.PickCoinQuest(count)
    for _, set in ipairs(Auto.ZG_COIN_SETS) do
        local holdsAll = true
        for _, id in ipairs(set.items) do
            if (tonumber(count(id)) or 0) < 1 then holdsAll = false break end
        end
        if holdsAll then return set.questID end
    end
    return nil
end

----------------------------------------------------------------------
-- GOSSIP-WINDOW QUEST PATH (1.1.4 — the defect this build fixes)
--
-- ROOT CAUSE. Rin'wosho the Trader (14921) is a GOSSIP npc: his quests ride the
-- gossip window, and the spec's auto-repair option lives on that same menu.
-- Before this build auto.lua selected quests ONLY through the classic greeting
-- API (QUEST_GREETING -> SelectActiveQuest/SelectAvailableQuest by index), and
-- Auto.OnGossipShow handled DMT / BWL / Sayge options and nothing else — no
-- C_GossipInfo.Get*Quests call existed anywhere in the addon. So at Rin'wosho
-- the zanza flow was never entered at all: not gated, not refused, simply never
-- started. That is the owner's "isn't working".
----------------------------------------------------------------------

-- Normalise one C_GossipInfo quest list into an array of
-- { questID, title, isComplete, index, selector }.
--
-- SELECTOR. C_GossipInfo.SelectAvailableQuest / .SelectActiveQuest take a single
-- number that the catalog labels `optionID` and nothing more — existence and
-- signature only, no indication whether that number is the questID or the
-- 1-based ordinal, and the answer differs by client generation. We therefore
-- take it from the record itself: `info.questID` when the entry carries one
-- (the modern gossip list is questID-keyed), the ordinal only as a fallback for
-- a list shape that has no ID to give. Either way the value we pass came out of
-- the very list the client just handed us.
function Auto.ReadGossipQuests(getter)
    local out = {}
    if type(getter) ~= "function" then return out end
    local ok, list = pcall(getter)
    if not ok or type(list) ~= "table" then return out end
    for i, info in ipairs(list) do
        if type(info) == "table" then
            local qid = tonumber(info.questID)
            out[#out + 1] = {
                questID    = qid,
                title      = info.title,
                isComplete = info.isComplete and true or false,
                index      = i,
                selector   = qid or i,
            }
        end
    end
    return out
end

-- PURE planner. `allowed` is a set of questID -> true built by the driver from
-- the ENABLED and GATED categories, so every policy decision has already been
-- made by the time we get here and this function's only job is ordering.
--
-- Active turn-ins are considered before available pickups: a turn-in always
-- wins over a pickup at the same NPC (you cannot re-take a repeatable quest you
-- are already on). Returns nil when nothing allowed is present — which is what
-- leaves the gossip interaction free for the option handlers.
function Auto.PlanGossipQuest(active, available, allowed)
    if type(allowed) ~= "table" or next(allowed) == nil then return nil, "nothing-allowed" end
    for _, q in ipairs(active or {}) do
        if q.questID and allowed[q.questID] then
            return { kind = "active", questID = q.questID, selector = q.selector }, "active"
        end
    end
    for _, q in ipairs(available or {}) do
        if q.questID and allowed[q.questID] then
            return { kind = "available", questID = q.questID, selector = q.selector }, "available"
        end
    end
    return nil, "no-match"
end

-- Build the allowed-ID set from live settings + world state. IMPURE by design:
-- every reading it does is funnelled into the pure planner above.
--
-- E'ko (Mau'ari) and R.O.I.D.S. (Drazial) are deliberately NOT here. Spec §14
-- is silent on whether those two NPCs use the gossip window, and the remit is
-- "leave their entry as-is if the spec does not say" — they keep the greeting
-- path they have always used. Adding IDs here for them would change their
-- behaviour on no evidence.
function Auto.AllowedGossipQuestIDs()
    local _, flags = activeQuestCategories()
    local allowed = {}

    if flags.zanza then
        local ok = Auto.ZanzaGateNow()
        if ok then allowed[Auto.ZANZA_QUEST] = true end
    end

    if flags.zgCoins then
        local qid = Auto.PickCoinQuest(function(id) return Auto.OwnedCount(id) end)
        if qid then allowed[qid] = true end
    end

    -- Belt to the whitelist's braces: nothing the spec forbids may ever survive
    -- into the set, however it got there.
    for qid in pairs(Auto.QUEST_NEVER) do allowed[qid] = nil end
    return allowed
end

-- Live wrapper over the pure zanza gate.
function Auto.ZanzaGateNow()
    local aq = aqBlock()
    return Auto.DecideZanzaGate({
        enabled    = aq.zanza and aq.zanza.enabled == true,
        shift      = IsShiftKeyDown and IsShiftKeyDown() or false,
        npcID      = Auto.NpcID(),
        tokenCount = Auto.OwnedCount(Auto.ZANZA_TOKEN),
        tokenNeed  = Auto.ZANZA_TOKEN_NEED,
        freeSlots  = Auto.FreeBagSlots(),
    })
end

-- The gossip-window driver. Returns true when it consumed the interaction.
function Auto.HandleGossipQuests()
    if not (C_GossipInfo and C_GossipInfo.GetAvailableQuests
            and C_GossipInfo.GetActiveQuests) then
        return false
    end
    local available = Auto.ReadGossipQuests(C_GossipInfo.GetAvailableQuests)
    local active    = Auto.ReadGossipQuests(C_GossipInfo.GetActiveQuests)
    if #available == 0 and #active == 0 then return false end

    local plan = Auto.PlanGossipQuest(active, available, Auto.AllowedGossipQuestIDs())
    if not plan then return false end

    if plan.kind == "active" then
        if C_GossipInfo.SelectActiveQuest then
            C_GossipInfo.SelectActiveQuest(plan.selector)
            return true
        end
    else
        if C_GossipInfo.SelectAvailableQuest then
            C_GossipInfo.SelectAvailableQuest(plan.selector)
            return true
        end
    end
    return false
end

-- Quest ID of the frame currently up (QUEST_DETAIL / PROGRESS / COMPLETE).
-- Returns nil rather than 0 so callers can fall back to the title pool.
function Auto.CurrentQuestID()
    if not GetQuestID then return nil end
    local ok, id = pcall(GetQuestID)
    id = ok and tonumber(id) or nil
    if id and id > 0 then return id end
    return nil
end

-- QUEST_GREETING: a multi-quest greeting NPC (E'ko / coin / token turn-ins).
-- This is the CLASSIC path, and the only one that still matches titles: the
-- greeting API exposes no quest IDs, so a keyword pool is all there is. Select
-- the first active quest whose title matches an enabled category; then handle
-- available quests (accept) the same way.
--
-- Shift skips it, same as the gossip window (spec §19.23 names all four NPCs).
function Auto.OnQuestGreeting()
    if IsShiftKeyDown and IsShiftKeyDown() then return end
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

-- Is the quest on the open quest frame one we auto-drive?
--
-- QUEST-ID-FIRST. When GetQuestID answers, the ID decides — and QUEST_NEVER
-- refuses before anything else, so 8196 / 8246 / 8240 are never accepted,
-- completed or rewarded no matter how they got on screen (including a manual
-- click while an enabled category is on). Only an absent ID falls back to the
-- title keyword pool, which is what keeps the greeting-driven E'ko and
-- R.O.I.D.S. flows working unchanged.
-- Returns (inScope:boolean, questID:number|nil, category:string|nil).
function Auto.QuestFrameInScope()
    local pool, flags = activeQuestCategories()
    if #pool == 0 then return false end
    local qid = Auto.CurrentQuestID()
    if qid then
        if Auto.QUEST_NEVER[qid] then return false, qid, "never" end
        if qid == Auto.ZANZA_QUEST then
            return flags.zanza == true, qid, "zanza"
        end
        for _, set in ipairs(Auto.ZG_COIN_SETS) do
            if set.questID == qid then return flags.zgCoins == true, qid, "zgCoins" end
        end
        -- An ID with no table of ours (E'ko, R.O.I.D.S.): fall through to the
        -- title test rather than refusing, so those flows are untouched.
    end
    local title = GetTitleText and GetTitleText()
    if title and Auto.TitleMatches(title, pool) then return true, qid end
    return false, qid
end

-- QUEST_DETAIL: a quest is being offered. Accept it if it belongs to an
-- enabled category (R.O.I.D.S. accept, coin/token re-pickups).
function Auto.OnQuestDetail()
    if not Auto.QuestFrameInScope() then return end
    if AcceptQuest then AcceptQuest() end
end

-- QUEST_PROGRESS: turn-in requirements screen. Complete when the game says the
-- quest is completable and it belongs to an enabled category.
function Auto.OnQuestProgress()
    if not Auto.QuestFrameInScope() then return end
    if IsQuestCompletable and IsQuestCompletable() and CompleteQuest then
        CompleteQuest()
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

----------------------------------------------------------------------
-- ZANZA REWARD MACHINERY (spec §14)
--
-- State is all session-local. `_zanzaCooldown` is the per-item 30 s rejection
-- stamp; `_zanzaPending` is the in-flight delivery verification; `_zanzaChoices`
-- is the reward list captured off the open QUEST_COMPLETE frame; `_zanzaWatch`
-- is the "every enabled flask already owned, dialog left open" bag watcher.
----------------------------------------------------------------------

Auto._zanzaCooldown = {}      -- key -> GetTime() stamp
Auto._zanzaPending  = nil     -- { key, itemID, before, at }
Auto._zanzaChoices  = nil     -- array of { index, itemID, name, key }
Auto._zanzaWatch    = false

-- PURE: stamp each reward choice with its zanza key. ITEM-ID-FIRST — the ID is
-- exact and locale-proof; the display name is only consulted when the reward
-- link did not resolve (item data not cached yet).
function Auto.KeyRewardChoices(choices)
    for _, c in ipairs(choices or {}) do
        c.key = nil
        if c.itemID then
            for _, r in ipairs(Auto.ZANZA_REWARDS) do
                if c.itemID == r.itemID then c.key = r.key break end
            end
        end
        if not c.key then
            local nm = lower(c.name)
            if nm ~= "" then
                for _, r in ipairs(Auto.ZANZA_REWARDS) do
                    if nm:find(r.name, 1, true) then c.key = r.key break end
                end
            end
        end
    end
    return choices
end

-- Read the choice list off the open QUEST_COMPLETE frame.
function Auto.ReadRewardChoices()
    local out = {}
    local n = GetNumQuestChoices and GetNumQuestChoices() or 0
    for i = 1, n do
        local name
        if GetQuestItemInfo then
            local ok, nm = pcall(GetQuestItemInfo, "choice", i)
            if ok and type(nm) == "string" then name = nm end
        end
        local itemID
        if GetQuestItemLink then
            local ok, link = pcall(GetQuestItemLink, "choice", i)
            if ok and type(link) == "string" then
                itemID = tonumber(link:match("item:(%d+)"))
            end
        end
        out[#out + 1] = { index = i, itemID = itemID, name = name or "" }
    end
    return Auto.KeyRewardChoices(out)
end

-- Pick the next enabled zanza and request it. Used both by QUEST_COMPLETE and,
-- later, by the bag watcher against the SAME still-open dialog.
-- Returns (requested:boolean, keyOrReason:string).
function Auto.ZanzaPickAndRequest()
    local choices = Auto._zanzaChoices
    if type(choices) ~= "table" or #choices == 0 then return false, "no-choices" end

    local aq = aqBlock()
    local picks = Auto.ZanzaEnabledPicks(aq.zanza and aq.zanza.priority)
    local offered, owned = {}, {}
    for _, c in ipairs(choices) do
        if c.key then offered[c.key] = true end
    end
    for _, k in ipairs(picks) do
        local r = Auto.ZanzaReward(k)
        owned[k] = (r ~= nil) and (Auto.OwnedCount(r.itemID) > 0) or false
    end

    local now = nowSecs()
    local key, reason = Auto.NextZanzaPick({
        picks     = picks,
        owned     = owned,
        offered   = offered,
        cooldowns = Auto._zanzaCooldown,
        now       = now,
        cooldown  = Auto.ZANZA_REJECT_COOLDOWN,
    })

    if not key then
        -- SPEC: every enabled zanza already owned -> KEEP the reward dialog
        -- open (we simply do not call GetQuestReward or CloseQuest) and arm a
        -- bag watcher, so the moment one is drunk the next is taken without
        -- re-opening gossip.
        if reason == "all-owned" and not Auto._zanzaWatch then
            Auto._zanzaWatch = true
            ns:Print("zanza: you already hold every enabled flask. Leaving the reward "
                  .. "window open — drink one and the next is taken automatically.")
        end
        return false, reason
    end

    local choice
    for _, c in ipairs(choices) do
        if c.key == key then choice = c break end
    end
    if not choice then return false, "not-offered" end

    -- SPEC: stamp the rejection cooldown BEFORE the reward request goes out, so
    -- a rapid re-open walks to the NEXT priority instead of retrying the pick
    -- that just failed. Cleared below on confirmed delivery.
    Auto._zanzaCooldown[key] = now
    Auto._zanzaWatch = false

    if choice.itemID then
        Auto._zanzaPending = {
            key = key, itemID = choice.itemID,
            before = Auto.OwnedCount(choice.itemID), at = now,
        }
    else
        -- No resolvable item ID means no honest bag delta to watch for. Rather
        -- than let the backstop fire a false rejection, drop the stamp and take
        -- the reward unverified.
        Auto._zanzaCooldown[key] = nil
        Auto._zanzaPending = nil
    end

    if GetQuestReward then GetQuestReward(choice.index) end

    -- 5 s timeout backstop. The same tick also runs off BAG_UPDATE_DELAYED, so
    -- the verification is event-driven first and timer-backed second (and stays
    -- reachable headless, where C_Timer.After is a no-op).
    if Auto._zanzaPending and C_Timer and C_Timer.After then
        C_Timer.After(Auto.ZANZA_DELIVERY_TIMEOUT, function()
            ns:SafeCall(Auto.ZanzaDeliveryTick)
        end)
    end
    return true, key
end

-- Event-driven delivery verification with the 5 s backstop.
-- Success clears the stamp and prints; failure re-stamps and prints.
function Auto.ZanzaDeliveryTick(now)
    local p = Auto._zanzaPending
    if not p then return "idle" end
    now = now or nowSecs()
    local verdict = Auto.JudgeDelivery(p, Auto.OwnedCount(p.itemID), now,
                                       Auto.ZANZA_DELIVERY_TIMEOUT)
    if verdict == "delivered" then
        Auto._zanzaCooldown[p.key] = nil
        Auto._zanzaPending = nil
        ns:Print(("zanza: %s delivered."):format(p.key))
    elseif verdict == "timeout" then
        Auto._zanzaCooldown[p.key] = now      -- re-stamp: 30 s from the failure
        Auto._zanzaPending = nil
        ns:Print(("zanza: %s did not arrive — trying the next priority for the "
               .. "next %ds."):format(p.key, Auto.ZANZA_REJECT_COOLDOWN))
    end
    return verdict
end

-- The armed bag watcher: a flask was drunk while the reward dialog stayed open.
function Auto.ZanzaWatchTick()
    if not Auto._zanzaWatch then return false end
    local ok = Auto.ZanzaPickAndRequest()
    return ok
end

-- The reward dialog closed for real: nothing left to pick from.
function Auto.OnQuestFinished()
    Auto._zanzaChoices = nil
    Auto._zanzaWatch   = false
end

-- QUEST_COMPLETE: take the reward. Zanza runs the full gated machinery above;
-- every other category keeps the simple "one fixed reward, or honour the
-- priority list" path it has always had.
function Auto.OnQuestComplete()
    local inScope, qid, category = Auto.QuestFrameInScope()
    if not inScope then return end

    if category == "zanza" or qid == Auto.ZANZA_QUEST then
        -- Re-run the token + bag-space guard on the REWARD step, not just at
        -- the gossip entry: this is the moment the item is actually asked for,
        -- and the frame can be reached without passing through our entry (a
        -- manual click, a quest already accepted before the toggle went on).
        -- Shift is deliberately NOT re-checked — spec §14 scopes it to "while
        -- opening gossip", so a Shift press mid-flow must not strand a
        -- half-finished turn-in.
        local ok = Auto.DecideZanzaGate({
            enabled    = true,
            shift      = false,
            npcID      = Auto.NpcID(),
            tokenCount = Auto.OwnedCount(Auto.ZANZA_TOKEN),
            tokenNeed  = Auto.ZANZA_TOKEN_NEED,
            freeSlots  = Auto.FreeBagSlots(),
        })
        if not ok then return end
        Auto._zanzaChoices = Auto.ReadRewardChoices()
        Auto.ZanzaPickAndRequest()
        return
    end

    local _, flags = activeQuestCategories()
    local nChoices = GetNumQuestChoices and GetNumQuestChoices() or 0
    local rewardIndex = 1
    if nChoices > 1 then
        local choices = {}
        for i = 1, nChoices do
            local name = GetQuestItemInfo and select(1, GetQuestItemInfo("choice", i)) or nil
            choices[#choices + 1] = { index = i, name = name or "" }
        end
        local priority = flags.zanza and aqBlock().zanza and aqBlock().zanza.priority or nil
        rewardIndex = Auto.PickReward(choices, priority) or 1
        for _, c in ipairs(choices) do
            if c.index == rewardIndex then Auto._expectedReward = lower(c.name) end
        end
    else
        Auto._expectedReward = nil
    end
    if GetQuestReward then GetQuestReward(rewardIndex) end
end

-- BAG_UPDATE_DELAYED — the settled bag tick.
--   1. refresh the session bank snapshot while the bank frame is open,
--   2. verify an in-flight zanza delivery,
--   3. let the armed watcher take the next flask now that one was drunk.
function Auto.OnBagUpdate()
    if Auto._bankOpen then Auto.RefreshBankSnapshot() end
    Auto.ZanzaDeliveryTick()
    Auto.ZanzaWatchTick()
    Auto._expectedReward = nil
end

function Auto.OnBankOpened()
    Auto._bankOpen = true
    Auto.RefreshBankSnapshot()
end

function Auto.OnBankClosed()
    -- The snapshot SURVIVES the bank closing (that is the whole point — it lets
    -- ownership be judged away from the bank). It dies with the session.
    Auto._bankOpen = false
end

----------------------------------------------------------------------
-- Auto-repair (spec §5) — MERCHANT_SHOW + RepairAllItems (globals)
--
-- SCOPE NOTE (1.1.4). Spec §14's "auto-repair at Rin'wosho" is a bigger flow
-- than what is here: it selects his VENDOR gossip option (icon file ID 132060)
-- when the zanza flow is idle, repairs on the merchant window IT opened, closes
-- it, and guards that with a 3 s disarm and a 5 s attempt cooldown. NONE of
-- that is shipped — what follows repairs on a merchant window the PLAYER
-- opened, at any vendor, and never touches gossip. That flow is deliberately
-- NOT added here (this build's remit is the zanza entry path), so there is no
-- idle-gate to compose with yet.
--
-- What this build DOES guarantee for it: Auto.OnGossipShow runs the quest-ID
-- path FIRST and returns the moment it selects, so when the Rin'wosho repair
-- flow is eventually built, a pickable zanza turn-in already wins the single
-- gossip interaction and the repair option cannot steal it. The "zanza flow is
-- idle" predicate it will need is Auto.ZanzaGateNow() returning false, plus
-- Auto.PlanGossipQuest returning nil.
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
    -- Walking away ends any dialog we were holding open. The rejection stamps
    -- are NOT cleared: they are a 30 s time-based guard, not a location one.
    Auto._zanzaChoices = nil
    Auto._zanzaWatch   = false
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
    ns:RegisterEvent("QUEST_FINISHED", function() ns:SafeCall(Auto.OnQuestFinished) end)
    ns:RegisterEvent("BAG_UPDATE_DELAYED", function() ns:SafeCall(Auto.OnBagUpdate) end)

    -- Session-only bank snapshot for zanza ownership (spec §14, §19.22). Never
    -- persisted: Auto._bankSnapshot is a plain field, so a reload forgets it.
    ns:RegisterEvent("BANKFRAME_OPENED", function() ns:SafeCall(Auto.OnBankOpened) end)
    ns:RegisterEvent("BANKFRAME_CLOSED", function() ns:SafeCall(Auto.OnBankClosed) end)

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

----------------------------------------------------------------------
-- ZANZA / GOSSIP-QUEST RULE TABLE (spec §14) — one assertion per rule.
--
-- These cover the PURE layer. harness.lua's "zanza-flow live path" section
-- drives the real event entry points (OnGossipShow / OnQuestComplete /
-- OnBagUpdate) against stubbed C_GossipInfo + container API for the
-- end-to-end and adversarial scenarios.
----------------------------------------------------------------------

-- RULE: the keyword pools are disjoint. zulian/razzashi/hakkari are the coin
-- set of 8195, never zanza.
local function testKeywordPools()
    local zanza, coins = {}, {}
    for _, k in ipairs(QUEST_KEYWORDS.zanza)   do zanza[k] = true end
    for _, k in ipairs(QUEST_KEYWORDS.zgCoins) do coins[k] = true end
    for k in pairs(zanza) do
        if coins[k] then return false, "zanza n zgCoins must be empty, shared: " .. k end
    end
    for _, k in ipairs({ "zulian", "razzashi", "hakkari" }) do
        if not coins[k] then return false, k .. " belongs to the coin pool (quest 8195)" end
        if zanza[k] then return false, k .. " must not be in the zanza pool" end
    end
    if not zanza["zanza"] then return false, "zanza pool keeps its own keyword" end
    return true
end

-- RULE: 8243 only; 8196 / 8246 / 8240 never.
local function testForbiddenQuests()
    if not (Auto.QUEST_NEVER[8196] and Auto.QUEST_NEVER[8246]) then
        return false, "8196/8246 must never be auto-progressed"
    end
    if not Auto.QUEST_NEVER[8240] then return false, "8240 is deliberately unhandled" end
    if Auto.QUEST_NEVER[Auto.ZANZA_QUEST] then return false, "8243 must be allowed" end
    for _, set in ipairs(Auto.ZG_COIN_SETS) do
        if Auto.QUEST_NEVER[set.questID] then
            return false, "coin quest " .. set.questID .. " must be allowed"
        end
    end
    -- ADVERSARIAL: the whole forbidden trio sits in the available list next to
    -- 8243 -> the planner takes 8243 and nothing else.
    local available = {
        { questID = 8196, selector = 8196 },
        { questID = 8246, selector = 8246 },
        { questID = 8243, selector = 8243 },
        { questID = 8240, selector = 8240 },
    }
    local plan = Auto.PlanGossipQuest({}, available, { [Auto.ZANZA_QUEST] = true })
    if not (plan and plan.questID == 8243) then return false, "must select 8243 among 8196/8246/8240" end
    -- ... and with 8243 absent, nothing at all is selected.
    plan = Auto.PlanGossipQuest({}, {
        { questID = 8196, selector = 8196 }, { questID = 8246, selector = 8246 },
    }, { [Auto.ZANZA_QUEST] = true })
    if plan ~= nil then return false, "8196/8246 alone must select nothing" end
    return true
end

-- RULE: active turn-ins beat available pickups; nothing allowed selects nothing.
local function testGossipPlanOrder()
    local plan = Auto.PlanGossipQuest(
        { { questID = 8243, selector = 8243, isComplete = true } },
        { { questID = 8238, selector = 8238 } },
        { [8243] = true, [8238] = true })
    if not (plan and plan.kind == "active" and plan.questID == 8243) then
        return false, "an active turn-in wins over an available pickup"
    end
    if Auto.PlanGossipQuest({}, { { questID = 8243, selector = 8243 } }, {}) ~= nil then
        return false, "an empty allowed-set selects nothing"
    end
    -- Selector provenance: questID when present, ordinal only as fallback.
    local read = Auto.ReadGossipQuests(function()
        return { { questID = 8243, title = "Zanza" }, { title = "No ID" } }
    end)
    if not (read[1].selector == 8243 and read[2].selector == 2) then
        return false, "selector is the questID, ordinal only when there is none"
    end
    return true
end

-- RULE: reward priority is Swiftness -> Spirit -> Sheen, order fixed by spec,
-- membership user-toggleable, empty list = spec default (all three).
local function testZanzaPriority()
    local all = Auto.ZanzaEnabledPicks({})
    if not (all[1] == "swiftness" and all[2] == "spirit" and all[3] == "sheen" and #all == 3) then
        return false, "empty priority means all three in spec order"
    end
    -- Ticked out of order in the UI -> still returned in spec order.
    local reordered = Auto.ZanzaEnabledPicks({ "sheen", "swiftness" })
    if not (reordered[1] == "swiftness" and reordered[2] == "sheen" and #reordered == 2) then
        return false, "canonical order is re-imposed on the stored membership"
    end
    local one = Auto.ZanzaEnabledPicks({ "spirit" })
    if not (#one == 1 and one[1] == "spirit") then return false, "single pick honoured" end
    -- Item IDs are the spec's.
    if Auto.ZanzaReward("swiftness").itemID ~= 20081 then return false, "swiftness 20081" end
    if Auto.ZanzaReward("spirit").itemID    ~= 20079 then return false, "spirit 20079" end
    if Auto.ZanzaReward("sheen").itemID     ~= 20080 then return false, "sheen 20080" end
    if Auto.ZANZA_TOKEN ~= 19858 then return false, "token 19858" end
    return true
end

-- RULE: bag space free, UNLESS holding exactly the required token count.
local function testBagSpaceGuard()
    if not Auto.DecideBagSpace(3, 1, 1) then return false, "free slots proceed" end
    if not Auto.DecideBagSpace(0, 1, 1) then return false, "bag full + EXACT token count proceeds" end
    if Auto.DecideBagSpace(0, 2, 1) then return false, "bag full + spare tokens must refuse" end
    if Auto.DecideBagSpace(0, 0, 1) then return false, "bag full + no token must refuse" end
    return true
end

-- RULE: the entry gate, every refusal named.
local function testZanzaGate()
    local base = { enabled = true, shift = false, npcID = Auto.ZANZA_NPC,
                   tokenCount = 1, tokenNeed = 1, freeSlots = 5 }
    local function with(t)
        local c = {}
        for k, v in pairs(base) do c[k] = v end
        for k, v in pairs(t) do c[k] = v end
        return Auto.DecideZanzaGate(c)
    end
    local ok, why = with({})
    if not (ok and why == "ok") then return false, "the happy path admits" end
    ok, why = with({ enabled = false })
    if ok or why ~= "disabled" then return false, "disabled refuses" end
    ok, why = with({ shift = true })
    if ok or why ~= "shift-skip" then return false, "held Shift skips the flow" end
    ok, why = with({ npcID = 15070 })
    if ok or why ~= "wrong-npc" then return false, "a KNOWN wrong NPC refuses" end
    ok = with({ npcID = nil })
    if not ok then return false, "an UNKNOWN npc must not disable the flow" end
    ok, why = with({ tokenCount = 0 })
    if ok or why ~= "no-token" then return false, "no honor token refuses" end
    ok, why = with({ freeSlots = 0, tokenCount = 2 })
    if ok or why ~= "bag-full" then return false, "bag full with spare tokens refuses" end
    ok = with({ freeSlots = 0, tokenCount = 1 })
    if not ok then return false, "bag full with the exact token count proceeds" end
    return true
end

-- RULE: walk the priority, skip owned, skip cooling; all-owned is its own verdict.
local function testNextPick()
    local picks = { "swiftness", "spirit", "sheen" }
    local offered = { swiftness = true, spirit = true, sheen = true }
    local key = Auto.NextZanzaPick({ picks = picks, offered = offered, now = 100 })
    if key ~= "swiftness" then return false, "first priority first" end

    -- Owned swiftness -> walk to spirit.
    key = Auto.NextZanzaPick({ picks = picks, offered = offered, now = 100,
                               owned = { swiftness = true } })
    if key ~= "spirit" then return false, "an owned pick is skipped" end

    -- Rapid re-open inside the 30 s stamp -> walk to the NEXT priority.
    key = Auto.NextZanzaPick({ picks = picks, offered = offered, now = 105,
                               cooldowns = { swiftness = 100 }, cooldown = 30 })
    if key ~= "spirit" then return false, "a cooling pick walks to the next priority" end
    -- ... and past the cooldown it comes back.
    key = Auto.NextZanzaPick({ picks = picks, offered = offered, now = 131,
                               cooldowns = { swiftness = 100 }, cooldown = 30 })
    if key ~= "swiftness" then return false, "the stamp expires at 30 s" end

    -- Every enabled pick owned -> the all-owned verdict (arms the bag watcher).
    local k2, why = Auto.NextZanzaPick({ picks = picks, offered = offered, now = 100,
        owned = { swiftness = true, spirit = true, sheen = true } })
    if k2 ~= nil or why ~= "all-owned" then return false, "all owned is its own verdict" end

    -- Everything cooling is NOT all-owned (must not arm the watcher).
    k2, why = Auto.NextZanzaPick({ picks = picks, offered = offered, now = 100,
        cooldowns = { swiftness = 90, spirit = 90, sheen = 90 }, cooldown = 30 })
    if k2 ~= nil or why ~= "all-cooling" then return false, "all cooling is distinct from all owned" end

    -- Nothing enabled.
    k2, why = Auto.NextZanzaPick({ picks = {}, now = 100 })
    if k2 ~= nil or why ~= "none-enabled" then return false, "no enabled picks" end

    -- A pick that is enabled but not on offer is skipped, not picked.
    key = Auto.NextZanzaPick({ picks = picks, offered = { sheen = true }, now = 100 })
    if key ~= "sheen" then return false, "only offered rewards are pickable" end
    return true
end

-- RULE: ownership = bags + session bank snapshot.
local function testOwnershipMath()
    if Auto.CountOwned(20081, 0, nil) ~= 0 then return false, "no bags, no snapshot" end
    if Auto.CountOwned(20081, 2, nil) ~= 2 then return false, "bags only" end
    if Auto.CountOwned(20081, 0, { [20081] = 1 }) ~= 1 then
        return false, "owned in the BANK SNAPSHOT alone still counts as owned"
    end
    if Auto.CountOwned(20081, 2, { [20081] = 3 }) ~= 5 then return false, "bags + bank sum" end
    if Auto.CountOwned(20079, 0, { [20081] = 3 }) ~= 0 then return false, "other items excluded" end
    -- "Forgotten on reload": a nil snapshot is the fresh-session state and
    -- reads as nothing known in the bank, NOT as a stale count.
    if Auto.CountOwned(20081, 0, nil) ~= 0 then return false, "a forgotten snapshot contributes nothing" end
    return true
end

-- RULE: delivery verified by bag delta, 5 s timeout backstop.
local function testDeliveryJudge()
    local p = { key = "spirit", itemID = 20079, before = 0, at = 100 }
    if Auto.JudgeDelivery(p, 1, 101, 5) ~= "delivered" then return false, "bag delta = delivered" end
    if Auto.JudgeDelivery(p, 0, 102, 5) ~= "pending" then return false, "no delta yet = pending" end
    if Auto.JudgeDelivery(p, 0, 105, 5) ~= "timeout" then return false, "5 s backstop fires" end
    if Auto.JudgeDelivery(nil, 0, 105, 5) ~= "idle" then return false, "nothing pending = idle" end
    -- A delta arriving exactly at the backstop still counts as delivered.
    if Auto.JudgeDelivery(p, 1, 105, 5) ~= "delivered" then return false, "delivery wins at the boundary" end
    return true
end

-- RULE: coin quest priority 8238 -> 8239 -> 8195, each needing its full set.
local function testCoinPriority()
    local have = {}
    local count = function(id) return have[id] or 0 end
    if Auto.PickCoinQuest(count) ~= nil then return false, "no coins, no quest" end
    have[19698], have[19699], have[19700] = 1, 1, 1
    if Auto.PickCoinQuest(count) ~= 8195 then return false, "third set alone -> 8195" end
    have[19701], have[19702] = 1, 1
    if Auto.PickCoinQuest(count) ~= 8195 then return false, "an INCOMPLETE higher set does not win" end
    have[19703] = 1
    if Auto.PickCoinQuest(count) ~= 8238 then return false, "a complete set 1 takes priority" end
    return true
end

-- RULE: reward choices are keyed by ITEM ID first, display name second.
local function testRewardKeying()
    local keyed = Auto.KeyRewardChoices({
        { index = 1, itemID = 20080, name = "Something Localised" },
        { index = 2, itemID = nil,   name = "Spirit of Zanza" },
        { index = 3, itemID = 12345, name = "Not A Zanza" },
    })
    if keyed[1].key ~= "sheen" then return false, "item ID wins over the display name" end
    if keyed[2].key ~= "spirit" then return false, "name fallback when the link did not resolve" end
    if keyed[3].key ~= nil then return false, "a foreign reward gets no key" end
    return true
end

-- RULE: NPC identity parse (the belt to the quest-ID braces).
local function testNpcParse()
    if Auto.ParseNpcID("Creature-0-3299-0-14-14921-0000027FA6") ~= 14921 then
        return false, "Rin'wosho creature GUID"
    end
    if Auto.ParseNpcID("Player-4395-01C7B4D5") ~= nil then return false, "a player GUID is not an NPC" end
    if Auto.ParseNpcID(nil) ~= nil then return false, "nil GUID" end
    if Auto.ParseNpcID("garbage") ~= nil then return false, "unparseable GUID" end
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
        { name = "keyword pools disjoint", fn = testKeywordPools },
        { name = "forbidden quests",    fn = testForbiddenQuests },
        { name = "gossip plan order",   fn = testGossipPlanOrder },
        { name = "zanza priority",      fn = testZanzaPriority },
        { name = "bag-space guard",     fn = testBagSpaceGuard },
        { name = "zanza entry gate",    fn = testZanzaGate },
        { name = "next-pick walk",      fn = testNextPick },
        { name = "ownership math",      fn = testOwnershipMath },
        { name = "delivery judge",      fn = testDeliveryJudge },
        { name = "coin priority",       fn = testCoinPriority },
        { name = "reward keying",       fn = testRewardKeying },
        { name = "npc guid parse",      fn = testNpcParse },
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
