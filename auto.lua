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
--              UnitIsGroupLeader, UnitIsGroupAssistant, UnitName,
--              IsEveryoneAssistant. UnitIsGroupAssistant is globals.txt +
--              functions.txt for 1.15.9.68808 (unit:UnitToken -> bool) and is
--              read-only: it answers the spec §12.3 "can I invite from here?"
--              question, it does not change anything.
--              NO PROTECTED group API is called from this file — see the
--              "Mesh-assembly gate" block for why, and harness.lua's
--              "protected-API gate" for the rule that keeps it that way.
--   * Chat:    SendChatMessage (GLOBAL). CHAT_MSG_SYSTEM (Event.ChatInfo.
--              ChatMsgSystem) is the spec's invite-failure evidence, §12.1.
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
--   * QuestLog: C_QuestLog.IsOnQuest(questID) -> bool. Used by ONE guard, the
--              Orb of Command's "not on 85556/85557/85558" test. Present in
--              functions.txt AND globals.txt for 1.15.9.68808; the guard
--              refuses (does not proceed) if it is ever absent.
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
--   * Repair:  CanMerchantRepair / GetRepairAllCost / RepairAllItems / GetMoney
--              / GetCoinTextureString (globals; all in globals.txt 1.15.9).
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

-- Diagnostic / self-test hook. The options page reaches the very same block
-- through Store.GetFactionSettings(ScopeFaction()); the options suite asserts
-- the two accessors land on the SAME table for the logged-in faction, because a
-- UI that edits one faction block while the engine reads the other is exactly
-- the class of bug that hid inside the owner's zanza pick list.
Auto.AQBlock          = aqBlock
Auto.FactionSettings  = factionSettings

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

----------------------------------------------------------------------
-- THE CANONICAL SOCIAL KEY  (spec §3 "Name-Realm — canonical key; realm
-- normalized", §2.1 "name-realm match, case-insensitive, realm normalized")
--
-- ONE convention for the guild/friends trust sets: base name lowered, realm
-- lowered and folded. It is deliberately friends.lua's Friends.Key spelling —
-- the same key the mesh auto-friend ledger and Daseeki-Conduit's ledger use —
-- so this module adds no second naming convention to the addon. The splitter
-- itself is friends.lua's, borrowed at call time; the inline twin only covers
-- the (impossible in the shipped .toc) case of that file being absent, and the
-- suite asserts the two agree row for row.
--
-- ONE DELIBERATE DELTA from Friends.Key: the realm is stripped of ALL
-- non-alphanumerics, not only spaces. Every name that reaches these gates has
-- passed through Auto.NormalizeName, which appends GetNormalizedRealmName() —
-- and that API drops apostrophes ("Nek'Rosh" -> "NekRosh"). Folding spaces
-- alone would make an apostrophe realm a permanent non-match, which is the
-- exact failure mode this whole capture exists to end. Asserted below.
----------------------------------------------------------------------

local function foldRealm(realm)
    return (tostring(realm or ""):gsub("[^%w]", "")):lower()
end
Auto._FoldRealm = foldRealm

function Auto.SocialKey(name, defaultRealm)
    name = trim(name)
    if name == "" then return nil end

    local base, realm
    local F = ns.MeshFriends
    if F and F.SplitNameRealm then
        base, realm = F.SplitNameRealm(name)
    else
        base, realm = name:match("^([^%-]+)%-(.+)$")
        if not base then base, realm = name, nil end
        base  = trim(base)
        realm = realm and trim(realm) or nil
    end
    if not base or base == "" then return nil end

    if realm == nil or realm == "" then
        realm = defaultRealm or selfRealm()
    end
    return base:lower() .. "-" .. foldRealm(realm)
end

-- Read one social trust set. The stored key is the canonical social key; a
-- literal "Name-Realm" key is honoured too, so a set written by an older build
-- or hand-placed in the SavedVariables still matches rather than silently
-- reading as "no match" — the failure this module exists to end.
local function socialHas(which, nameRealm)
    local social = Store.GetSocial()
    local set = social and social[which]
    if type(set) ~= "table" then return false end
    if set[nameRealm] == true then return true end
    local key = Auto.SocialKey(nameRealm)
    return (key ~= nil and set[key] == true) or false
end
Auto._SocialHas = socialHas

function Auto.IsGuild(nameRealm)
    return socialHas("guild", nameRealm)
end

function Auto.IsFriend(nameRealm)
    return socialHas("friends", nameRealm)
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

----------------------------------------------------------------------
-- THE LEADER REDIRECT  (spec §12.3, audit divergence 8 / rows 29-31)
--
-- "DSN:LEAD:Name-Realm" is OUR OWN protocol tag (not the spec source's), in two
-- directions:
--   inbound  "DSN:LEAD:X" — a peer tells us the real inviter is X, so we
--            re-whisper the keyword to X and route ourselves onto their group.
--   outbound someone whispers our keyword and WE CANNOT INVITE — so we answer
--            "DSN:LEAD:<leader>" and their client re-routes to whoever is
--            actually holding the group.
--
-- The outbound half used to key off `ag.redirectLeader`: a settings key with no
-- store default and no options control anywhere, so it read nil forever and the
-- branch was unreachable dead code. The audit's verdict on it is MISSING, and
-- the fix is not to give the dead key a UI — the spec never describes a
-- configured leader. It describes a LIVE one: "if we cannot invite (in a raid
-- without leader/assist, or in a party without lead), the addon finds the group
-- leader and — only if that leader is in our mesh — whispers the requester a
-- machine-readable redirect." So the key is gone and the live lookup is here.
--
-- The mesh test is the safety rule, not a nicety: without it we would hand a
-- stranger's name and realm to whoever whispered us, on their behalf, unasked.
----------------------------------------------------------------------

-- Can we actually issue an invite right now? Pure over group state.
function Auto.CanInviteIn(ctx)
    ctx = ctx or {}
    if not ctx.inGroup then return true end                        -- solo: always
    if ctx.inRaid then return (ctx.isLeader or ctx.isAssistant) and true or false end
    return ctx.isLeader and true or false
end

function Auto.CanInvite()
    return Auto.CanInviteIn({
        inGroup     = ((GetNumGroupMembers and GetNumGroupMembers()) or 0) > 1,
        inRaid      = (IsInRaid and IsInRaid()) and true or false,
        isLeader    = (UnitIsGroupLeader and UnitIsGroupLeader("player")) and true or false,
        isAssistant = (UnitIsGroupAssistant and UnitIsGroupAssistant("player")) and true or false,
    })
end

-- Canonical Name-Realm of the current group leader, or nil. READ-ONLY API.
function Auto.GroupLeaderName()
    local n = (GetNumGroupMembers and GetNumGroupMembers()) or 0
    if n <= 1 then return nil end
    if UnitIsGroupLeader and UnitIsGroupLeader("player") then return selfNameRealm() end
    local raid = (IsInRaid and IsInRaid()) and true or false
    local last = raid and n or (n - 1)
    for i = 1, last do
        local unit = (raid and "raid" or "party") .. i
        if UnitIsGroupLeader and UnitIsGroupLeader(unit) then
            local nm, rlm = UnitName and UnitName(unit)
            if nm and nm ~= "" then
                return (rlm and rlm ~= "") and (nm .. "-" .. rlm) or Auto.NormalizeName(nm)
            end
        end
    end
    return nil
end

-- Pure routing decision for an incoming keyword whisper.
-- ctx = { canInvite, leader, leaderInMesh, me }
-- Returns "invite" | "redirect" | "ignore" (plus the leader for "redirect").
function Auto.DecideWhisperRoute(ctx)
    ctx = ctx or {}
    if ctx.canInvite then return "invite" end
    local leader = ctx.leader
    if leader and leader ~= "" and leader ~= ctx.me and ctx.leaderInMesh then
        return "redirect", leader
    end
    return "ignore"
end

-- Whisper handler: keyword auto-invite + the leader-redirect protocol.
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

    -- Trust gate first: someone we would not invite gets no answer at all, not
    -- even the name of our group leader.
    local ok, cat = Auto.ShouldInviteKeyword(nameRealm)
    if not ok then return end

    local leader = Auto.GroupLeaderName()
    local route, to = Auto.DecideWhisperRoute({
        canInvite    = Auto.CanInvite(),
        leader       = leader,
        leaderInMesh = leader and Auto.IsRoster(leader) or false,
        me           = selfNameRealm(),
    })

    if route == "redirect" then
        if SendChatMessage then
            SendChatMessage("DSN:LEAD:" .. to, "WHISPER", nil, nameRealm)
        end
        ns:Print(("cannot invite — pointed %s at %s."):format(nameRealm, to))
        return
    end
    if route ~= "invite" then return end

    if C_PartyInfo and C_PartyInfo.InviteUnit then
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

----------------------------------------------------------------------
-- THE INVITE RUN  (spec §12.1, audit divergence 6)
--
-- What used to be here walked ns.Mesh.peers and fired every invite in one
-- frame. Six of the spec's rules were simply absent: the local-database half of
-- the target set, the active-faction filter, the already-in-group filter, the
-- alphabetical sort, the 60 ms spacing with its 700 ms pin on the 5th, and the
-- whole reverse-invite recovery. A burst of 8-20 simultaneous InviteUnit calls
-- is exactly the shape the client throttles, and a group that is already
-- assembled under somebody else never got the reverse invite.
--
-- KEPT AS-IS, DELIBERATELY: the assembly gate (60 s armed window + leader +
-- mesh-share) instead of the spec's flat 5 s. That is documented hardening
-- after a live ADDON_ACTION_BLOCKED incident (see the gate block above) and the
-- audit marks it APPROXIMATED-BY-DESIGN, not a defect. This rebuild does not
-- touch it; the convert pass is simply re-timed to fire after the ladder has
-- finished rather than a flat 2 s after the run started.
----------------------------------------------------------------------

Auto.INVITE_SPACING       = 0.06   -- spec: invites 60 ms apart
Auto.INVITE_FIFTH_INDEX   = 5      -- spec: …and the 5th is additionally delayed
Auto.INVITE_FIFTH_DELAY   = 0.70   -- …so it lands no earlier than 700 ms in
Auto.REVERSE_INVITE_DELAY = 0.30   -- spec: leave party, wait 0.3 s, then whisper
-- OURS. The spec says WHAT decides the reverse invite (every invite failed) but
-- not WHEN we stop waiting for the server to say so. One second past the last
-- invite is comfortably longer than a same-realm invite round-trip and short
-- enough to still feel like part of the same click. Judging early is not a
-- correctness risk in any case: FinishInviteRun re-reads the group at judge
-- time, so a straggler who joined blocks the reverse path on the "alone" test.
Auto.INVITE_JUDGE_DELAY   = 1.0
Auto.INVITE_SETTLE_DELAY  = 2      -- OURS: convert pass, after the ladder ends

-- Injectable scheduler. Everything timed in this file goes through it so the
-- headless self-tests can drive the ladder on a simulated clock — the harness
-- stubs C_Timer.After as a no-op, and a test that needs a real timer is a test
-- that never runs.
function Auto.After(delay, fn)
    if Auto._after then return Auto._after(delay, fn) end
    if C_Timer and C_Timer.After then return C_Timer.After(delay, fn) end
    return fn()
end

-- Spec §12.1 target set, pure over injected state. ctx:
--   accounts  -- Store data accounts table (the LOCAL DATABASE half)
--   peers     -- ns.Mesh.peers (the MESH ROSTER half)
--   faction   -- our active faction; DB characters must match it
--   me        -- our own Name-Realm
--   inGroup   -- { [nameRealm] = true } for everyone already grouped with us
--   isOnline  -- fn(nameRealm, rec, aid) -> boolean
-- Returns an alphabetically sorted array of Name-Realm.
--
-- FACTION NOTE. Mesh peers carry no faction field and need none: custom chat
-- channels are faction-bound, so the mesh channel can only ever hold
-- same-faction characters (mesh.lua's same-faction constraint). The filter
-- therefore applies to the database half, where a stored record really can be
-- the other side's. A DB record with NO faction stamped is not admitted on that
-- evidence — but if it is also a live mesh peer, the roster half admits it.
function Auto.BuildInviteTargets(ctx)
    ctx = ctx or {}
    local me      = ctx.me
    local inGroup = ctx.inGroup or {}
    local isOnline = ctx.isOnline or function() return false end

    local seen, out = {}, {}
    local function add(nameRealm)
        if not nameRealm or nameRealm == "" then return end
        if nameRealm == me then return end            -- not yourself
        if inGroup[nameRealm] then return end         -- not already in your group
        if seen[nameRealm] then return end
        seen[nameRealm] = true
        out[#out + 1] = nameRealm
    end

    -- Roster half first, so a mesh name is admitted even when the local record
    -- for it is stale, foreign-faction-looking or absent entirely.
    local roster = {}
    for _, p in pairs(ctx.peers or {}) do
        if p and p.online and p.name then roster[p.name] = true end
    end

    for aid, bucket in pairs(ctx.accounts or {}) do
        local function consider(nameRealm, rec)
            if rec and rec.faction ~= ctx.faction then return end
            if isOnline(nameRealm, rec, aid) or roster[nameRealm] then add(nameRealm) end
        end
        for nameRealm, rec in pairs((bucket and bucket.characters) or {}) do
            consider(nameRealm, rec)
        end
        for nameRealm, rec in pairs((bucket and bucket.homeless) or {}) do
            consider(nameRealm, rec)
        end
    end

    -- …plus every mesh-roster name not present in the local database at all.
    for nameRealm in pairs(roster) do add(nameRealm) end

    table.sort(out)
    return out
end

-- Live target set. Online-ness is the dashboard's answer when the UI layer is
-- loaded; headless (or with DaseekiUI absent, where ui_shell.lua top-level
-- returns) it falls back to the same 15 s last-seen recency the spec's §2.1
-- step 3 describes.
Auto.ONLINE_WINDOW = 15

function Auto.InviteTargets()
    local data  = Store.GetData()
    local peers = ns.Mesh and ns.Mesh.peers or nil
    local D     = ns.Dashboard
    local nowE  = (Store.Now and Store.Now()) or 0
    local isOnline
    if D and D.IsOnline then
        isOnline = function(nameRealm, rec, aid) return D.IsOnline(rec, nameRealm, aid) and true or false end
    else
        isOnline = function(_, rec)
            return rec ~= nil and (nowE - (rec.lastSeen or 0)) <= Auto.ONLINE_WINDOW
        end
    end
    local inGroup = {}
    for _, nm in ipairs(Auto.GroupMemberNames()) do inGroup[nm] = true end
    local faction = UnitFactionGroup and UnitFactionGroup("player") or nil
    return Auto.BuildInviteTargets({
        accounts = data and data.accounts,
        peers    = peers,
        faction  = faction,
        me       = selfNameRealm(),
        inGroup  = inGroup,
        isOnline = isOnline,
    })
end

-- Spec §12.1 pacing: invites 60 ms apart, with the 5th pinned to land no
-- earlier than 700 ms after the run started. The ladder stays MONOTONE past the
-- pin — invites 6..n continue 60 ms behind the delayed 5th rather than
-- overtaking it, which is the only reading under which the 5th is still 5th.
-- Pure; returns delays in seconds from run start.
function Auto.InviteSchedule(n)
    local out, t = {}, 0
    for i = 1, (n or 0) do
        if i > 1 then t = t + Auto.INVITE_SPACING end
        if i == Auto.INVITE_FIFTH_INDEX and t < Auto.INVITE_FIFTH_DELAY then
            t = Auto.INVITE_FIFTH_DELAY
        end
        out[i] = t
    end
    return out
end

-- Spec §12.1 failure counting: a system chat line containing "already" AND
-- either "group" or "party". Pure; case-insensitive.
function Auto.IsAlreadyInGroupMessage(msg)
    local m = lower(msg or "")
    if not m:find("already", 1, true) then return false end
    return (m:find("group", 1, true) or m:find("party", 1, true)) and true or false
end

-- Spec §12.1 outcome: EVERY invite failed with already-in-a-group, and we are
-- alone -> recover by asking for a reverse invite. Otherwise report success.
-- Pure over ctx = { sent, failures, alone }.
function Auto.DecideInviteOutcome(ctx)
    ctx = ctx or {}
    local sent     = ctx.sent or 0
    local failures = ctx.failures or 0
    if sent > 0 and failures >= sent and ctx.alone then return "reverse" end
    return "done"
end

-- Live run state. One at a time; a second invite run replaces the first.
Auto._inviteRun = nil

-- CHAT_MSG_SYSTEM sink. Only counts while a run is open, so the addon is not
-- parsing every system line the client ever prints.
function Auto.OnSystemMessage(msg)
    local run = Auto._inviteRun
    if not run or run.closed then return false end
    if not Auto.IsAlreadyInGroupMessage(msg) then return false end
    run.failures = run.failures + 1
    return true
end

-- Close the run and act on the outcome.
function Auto.FinishInviteRun()
    local run = Auto._inviteRun
    if not run or run.closed then return nil end
    run.closed = true

    local alone = ((GetNumGroupMembers and GetNumGroupMembers()) or 0) <= 1
    local outcome = Auto.DecideInviteOutcome({
        sent = run.sent, failures = run.failures, alone = alone,
    })

    if outcome ~= "reverse" then
        ns:Print(("All invites sent! (%d)"):format(run.sent))
        return outcome
    end

    -- Everyone we asked is already grouped up somewhere and we are on our own:
    -- drop whatever party shell we are in, let the server settle, then whisper
    -- the keyword at the first target so THEY invite US instead.
    local target = run.targets[1]
    if LeaveParty then LeaveParty() end
    Auto.After(Auto.REVERSE_INVITE_DELAY, function()
        if target and SendChatMessage then
            SendChatMessage(run.keyword, "WHISPER", nil, target)
            ns:Print(("everyone is already grouped — asked %s for an invite."):format(target))
        end
    end)
    return outcome
end

-- Mass-invite every eligible character (spec §12.1). Unless the caller opts
-- out, this ARMS the assembly window (see the gate block above) and schedules
-- the convert pass once the invites settle.
--
-- Public surface: minimap left-click, dashboard "Invite Online", /dsn invite.
function Auto.InviteOnline(skipConvert)
    -- Arm BEFORE the invites go out: the roster updates they provoke arrive
    -- while the invites are still landing, and those are exactly the ticks the
    -- convert pass needs to see.
    if not skipConvert then Auto.ArmAssembly() end

    local targets = Auto.InviteTargets()
    local n = #targets
    if n == 0 then
        Auto._inviteRun = nil
        ns:Print("no eligible characters to invite.")
        return 0
    end

    local schedule = Auto.InviteSchedule(n)
    Auto._inviteRun = {
        targets  = targets,
        sent     = n,
        failures = 0,
        closed   = false,
        keyword  = agBlock().inviteKeyword or "inv",
    }
    local run = Auto._inviteRun

    for i = 1, n do
        local name = targets[i]
        Auto.After(schedule[i], function()
            -- A newer run supersedes this one; never fire its stragglers.
            if Auto._inviteRun ~= run then return end
            if C_PartyInfo and C_PartyInfo.InviteUnit then
                C_PartyInfo.InviteUnit(name)
            end
        end)
    end

    local tail = schedule[n] or 0
    -- Give the server a beat past the last invite to answer, then judge the run.
    Auto.After(tail + Auto.INVITE_JUDGE_DELAY, function()
        if Auto._inviteRun ~= run then return end
        ns:SafeCall(Auto.FinishInviteRun)
    end)

    if not skipConvert then
        -- Let the whole ladder land before converting the group.
        Auto.After(tail + Auto.INVITE_SETTLE_DELAY, function()
            ns:SafeCall(Auto.MaybeConvertRaid)
        end)
    end
    return n
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
-- `slot` is the TRACKER's slot index (tracker.lua BUFF_SLOTS / BUFF_SPELL_IDS),
-- which is how identity is resolved now: spell ID first, apostrophe-normalized
-- name prefix as the fallback, both through Tracker.MatchAura. The `prefix` here
-- is kept ONLY as the last-ditch matcher for a build with no tracker loaded, and
-- `label` is what the accept line prints (spec §13: "prints which buffs
-- triggered it", not the reason word).
Auto.SUMMON_TRIGGER_BUFFS = {
    { key = "dragonslayer", slot = 1,  label = "Rallying Cry of the Dragonslayer",
      prefix = "rallying cry of the dragonslayer" },
    { key = "warchief",     slot = 2,  label = "Warchief's Blessing",
      prefix = "warchief's blessing" },
    { key = "zandalar",     slot = 3,  label = "Spirit of Zandalar",
      prefix = "spirit of zandalar" },
    { key = "songflower",   slot = 4,  label = "Songflower Serenade",
      prefix = "songflower serenade" },
    { key = "fengus",       slot = 6,  label = "Fengus' Ferocity",
      prefix = "fengus' ferocity" },
    { key = "moldar",       slot = 7,  label = "Mol'dar's Moxie",
      prefix = "mol'dar's moxie" },
    { key = "slipkik",      slot = 8,  label = "Slip'kik's Savvy",
      prefix = "slip'kik's savvy" },
    { key = "dmf",          slot = 5,  label = "Sayge's Dark Fortune",
      prefix = "sayge's dark fortune" },
    { key = "battleShout",  slot = 9,  label = "Battle Shout",
      prefix = "battle shout" },
    -- SEASONAL FFF. The prefix used to read "fervor of the first feast", which
    -- is not the name of anything: spec §4.1 names slot 10 **Fire Festival
    -- Fury** (29338 / 29846), and tracker.lua has carried the correct string
    -- all along. The trigger therefore could never match, so ticking the FFF box
    -- did nothing at all (audit divergence 5 / row 58).
    { key = "fff",          slot = 10, label = "Fire Festival Fury",
      prefix = "fire festival fury" },
}

-- Trigger key -> tracker slot, and the boonable subset. A chronoboon suspends
-- slots 1-8 only; Battle Shout (9) and FFF (10) are NOT boonable (spec §4.1), so
-- they are the two slots the unboon-window exclusion must NOT swallow.
Auto.TRIGGER_SLOT     = {}
Auto.TRIGGER_BOONABLE = {}
for _, def in ipairs(Auto.SUMMON_TRIGGER_BUFFS) do
    Auto.TRIGGER_SLOT[def.key]     = def.slot
    Auto.TRIGGER_BOONABLE[def.key] = (def.slot <= 8) or nil
end

-- Spec §13: a `live -> live` refresh only counts as fresh when the remaining
-- duration JUMPED by more than this. Anything smaller is the same buff ticking
-- (or a rounding wobble between two captures), not a re-application.
Auto.FRESH_REFRESH_JUMP = 75

-- Most-recent trigger-buff gain timestamp (GetTime seconds) and the names that
-- caused it. Both are cleared on accept (spec §13: "clears the fresh-buff
-- flags, and only then clicks accept").
Auto._lastTriggerGain  = nil
Auto._lastTriggerNames = nil
-- [key] = { state = "absent"|"live"|"booned", duration = seconds }
Auto._triggerState = {}

----------------------------------------------------------------------
-- FRESH-BUFF DETECTION  (spec §13, audit divergence 5)
--
-- What used to be here stamped a gain on `absent -> present` and nothing else,
-- over a private localised name-prefix scan with no notion of duration and no
-- notion of the chronoboon. Three of the spec's four clauses were missing, and
-- the missing ones are the dangerous ones:
--
--   * a `live -> live` refresh whose duration jumps by > 75 s is fresh — so a
--     Songflower or Rend re-application never armed the gate at all;
--   * `booned -> live` is NEVER fresh — but with no chronoboon awareness,
--     RELEASING A BOON read as a batch of brand-new buffs;
--   * boonable slots gained inside the 3 s unboon window are excluded — the
--     same hole from the other side, for the scan that lands mid-restore.
--
-- The consequence was the sharpest finding in the conformance audit: **pop your
-- chronoboon and the next summon is auto-accepted**, because unbooning looked
-- exactly like walking out of Orgrimmar with seven fresh world buffs.
--
-- The fix reads the state the tracker already maintains rather than inventing a
-- parallel one:
--   * LIVE + duration comes from the aura list, frame-fresh, matched through
--     Tracker.MatchAura (spell ID first — so this path is no longer broken on a
--     non-enUS client, audit row 57).
--   * BOONED comes from the store record's own `auraStates[slot].source == BOON`
--     cells. It CANNOT come from the aura list: a booned buff is not an aura at
--     all, which is precisely why the old scan could not see the difference
--     between "restored from a boon" and "just picked up".
--   * The unboon window comes from Tracker.InUnboonWindow(), which tracker.lua
--     has exposed (and flagged as unconsumed) since the chronoboon batch.
--
-- Everything below the readers is pure over injected tables, so the whole matrix
-- — including the unboon case — is driven headless with a fixture store.
----------------------------------------------------------------------

-- Live trigger auras RIGHT NOW: [key] = remaining seconds (>= 0). Identity is
-- resolved by the tracker's shared matcher; `auraFn` is injectable for tests.
function Auto.ReadLiveTriggerAuras(auraFn)
    local out = {}
    auraFn = auraFn or (C_UnitAuras and C_UnitAuras.GetBuffDataByIndex)
    if not auraFn then return out end
    local T = ns.Tracker
    local slotToKey = {}
    for _, def in ipairs(Auto.SUMMON_TRIGGER_BUFFS) do slotToKey[def.slot] = def.key end
    for i = 1, 40 do
        local aura = auraFn("player", i)
        if not aura then break end
        local slot
        if T and T.MatchAura then
            slot = T.MatchAura(aura.spellId or aura.spellID, aura.name)
        else
            -- Tracker-less fallback: the catalog's own prefixes.
            local nm = lower(aura.name)
            for _, def in ipairs(Auto.SUMMON_TRIGGER_BUFFS) do
                if nm:find(def.prefix, 1, true) == 1 then slot = def.slot break end
            end
        end
        local key = slot and slotToKey[slot]
        if key then
            -- Same arithmetic as tracker.lua's auraRemaining: floored whole
            -- seconds off expirationTime, 0 when the client reports none. The
            -- two readings MUST agree or the 75 s jump test would see phantom
            -- movement every time the sources swapped.
            local exp = tonumber(aura.expirationTime) or 0
            local rem = 0
            if exp > 0 then
                rem = exp - ((GetTime and GetTime()) or 0)
                if rem < 0 then rem = 0 end
                rem = math.floor(rem)
            end
            -- A slot can appear twice (variant re-application); keep the longest.
            if (out[key] or -1) < rem then out[key] = rem end
        end
    end
    return out
end

-- Trigger keys the STORE says are suspended in a chronoboon. Pure over `rec`.
function Auto.BoonedTriggersIn(rec)
    local out = {}
    local states = rec and rec.auraStates
    if type(states) ~= "table" then return out end
    local boonSrc = (ns.Store and ns.Store.AURA_SOURCE and ns.Store.AURA_SOURCE.BOON) or 2
    for _, def in ipairs(Auto.SUMMON_TRIGGER_BUFFS) do
        local cell = states[def.slot]
        if type(cell) == "table" and (tonumber(cell.source) or 0) == boonSrc then
            out[def.key] = true
        end
    end
    return out
end

-- Fold the two readings into one state per trigger key. The aura list wins when
-- a slot is both up and marked booned (that is the tail of a restore, and the
-- live aura is the newer evidence).
function Auto.BuildTriggerStates(liveDurations, boonedKeys)
    liveDurations, boonedKeys = liveDurations or {}, boonedKeys or {}
    local out = {}
    for _, def in ipairs(Auto.SUMMON_TRIGGER_BUFFS) do
        local key = def.key
        local dur = liveDurations[key]
        if dur ~= nil then
            out[key] = { state = "live", duration = dur }
        elseif boonedKeys[key] then
            out[key] = { state = "booned", duration = 0 }
        else
            out[key] = { state = "absent", duration = 0 }
        end
    end
    return out
end

-- THE SPEC §13 FRESH-BUFF TEST. Pure over (prev, cur, ctx); returns the sorted
-- list of trigger keys that just became fresh.
--   ctx.triggers        -- the user's enabled trigger set
--   ctx.inUnboonWindow  -- Tracker.InUnboonWindow()
function Auto.ClassifyTriggerGains(prev, cur, ctx)
    prev, cur, ctx = prev or {}, cur or {}, ctx or {}
    local triggers = ctx.triggers or {}
    local fresh = {}
    for _, def in ipairs(Auto.SUMMON_TRIGGER_BUFFS) do
        local key = def.key
        local c = cur[key]
        if triggers[key] and c and c.state == "live" then
            local p     = prev[key]
            local pstate = (p and p.state) or "absent"
            local isFresh
            if pstate == "booned" then
                -- Releasing a chronoboon RESTORES a buff you already had. Never
                -- fresh, no matter how long it has left.
                isFresh = false
            elseif pstate == "live" then
                isFresh = ((c.duration or 0) - (p.duration or 0)) > Auto.FRESH_REFRESH_JUMP
            else
                isFresh = true                      -- absent -> live
            end
            -- The same protection from the other side: for the 3 s after an
            -- unboon, a boonable slot appearing is the restore landing, not a
            -- gain. Battle Shout and FFF are not boonable and stay eligible.
            if isFresh and ctx.inUnboonWindow and Auto.TRIGGER_BOONABLE[key] then
                isFresh = false
            end
            if isFresh then fresh[#fresh + 1] = key end
        end
    end
    table.sort(fresh)
    return fresh
end

-- Is the tracker inside its post-unboon grace? Tolerates a tracker-less build.
function Auto.InUnboonWindow()
    local T = ns.Tracker
    if T and T.InUnboonWindow then return T.InUnboonWindow() and true or false end
    return false
end

-- The self record, read-only. nil when the store has nothing yet (pre-login).
local function selfRecord()
    if not (Store and Store.GetCharacter) then return nil end
    local ok, rec = pcall(Store.GetCharacter, selfNameRealm())
    return ok and rec or nil
end

-- Rescan player auras and stamp a gain time when a *configured* trigger buff
-- becomes fresh by the §13 definition. Bound to UNIT_AURA (already coalesced by
-- the client for the player unit).
function Auto.ScanTriggerBuffs()
    local cur = Auto.BuildTriggerStates(
        Auto.ReadLiveTriggerAuras(),
        Auto.BoonedTriggersIn(selfRecord()))
    local fresh = Auto.ClassifyTriggerGains(Auto._triggerState, cur, {
        triggers       = asBlock().triggers or {},
        inUnboonWindow = Auto.InUnboonWindow(),
    })
    Auto._triggerState = cur
    if #fresh > 0 then
        Auto._lastTriggerGain  = (GetTime and GetTime()) or 0
        Auto._lastTriggerNames = fresh
    end
    return fresh
end

-- Age (seconds) of the most-recent trigger-buff gain, or nil if none seen.
function Auto.TriggerBuffAge()
    if not Auto._lastTriggerGain then return nil end
    return ((GetTime and GetTime()) or 0) - Auto._lastTriggerGain
end

-- Human-readable names of the buffs behind the current fresh flag.
function Auto.TriggerBuffLabels()
    local keys = Auto._lastTriggerNames
    if type(keys) ~= "table" or #keys == 0 then return nil end
    local byKey = {}
    for _, def in ipairs(Auto.SUMMON_TRIGGER_BUFFS) do byKey[def.key] = def.label end
    local out = {}
    for i = 1, #keys do out[i] = byKey[keys[i]] or keys[i] end
    return table.concat(out, ", ")
end

-- Drop the fresh-buff flags. Spec §13 clears them as part of accepting, so a
-- SECOND summon inside the same window needs a NEW buff to be auto-accepted.
function Auto.ClearTriggerGain()
    Auto._lastTriggerGain  = nil
    Auto._lastTriggerNames = nil
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

-- Perform the accept, in the spec §13 order: snapshot to the database (the
-- accept fires an instant teleport and the aura APIs are unreliable across it),
-- print WHICH BUFFS triggered it, CLEAR the fresh-buff flags, and only then
-- click accept.
--
-- The clear is not cosmetic (audit divergence 5 / row 52). Without it the gain
-- timestamp stays armed for the rest of the 19 s window, so a second summon
-- landing inside that window — from anyone, for any reason — was auto-accepted
-- off the same buff. One fresh buff now buys exactly one accept.
function Auto.AcceptSummon(reason)
    -- Pre-teleport snapshot so the dashboard keeps our buffs/location.
    if ns.Tracker and ns.Tracker.Capture then ns:SafeCall(ns.Tracker.Capture) end

    local labels = Auto.TriggerBuffLabels()
    if labels then
        ns:Print(("auto-accepted summon (%s: %s)."):format(reason or "?", labels))
    else
        ns:Print(("auto-accepted summon (%s)."):format(reason or "?"))
    end
    Auto.ClearTriggerGain()

    if C_SummonInfo and C_SummonInfo.ConfirmSummon then
        C_SummonInfo.ConfirmSummon()
    end
    if StaticPopup_Hide then StaticPopup_Hide("CONFIRM_SUMMON") end
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
-- Gossip automation (spec §14) — C_GossipInfo namespace
--
-- NPC IDENTITY IS THE GATE (1.1.4 conformance wave, audit divergence 3).
--
-- What used to be here matched a pool of display-text KEYWORDS against the
-- option list of ANY gossip NPC in the game. The pools carried "spare", "free"
-- and "enter" — substrings that occur in unrelated Classic gossip — so ticking
-- the Dire Maul or Orb box armed a fuzzy auto-clicker world-wide, able to
-- accept a quest, start an escort or buy from a vendor at an NPC that has
-- nothing to do with either feature.
--
-- The pools are GONE. Not narrowed: deleted. Spec §14 never describes keyword
-- matching for these flows — it describes NPC identity plus an option INDEX
-- ("auto-picks option 1"), and that is now the whole mechanism. Every handler
-- below refuses unless UnitGUID("npc") parses to an ID the spec names.
--
-- UNKNOWN GUID REFUSES HERE. That is the opposite of the zanza gate, and
-- deliberately so: zanza is backed by an exact quest-ID whitelist (8243 only
-- exists at Rin'wosho), so an unparseable GUID there cannot cause a wrong
-- action. These handlers have no such backstop — a positional click is
-- evidence-free — so "I could not identify this NPC" must mean "do nothing".
----------------------------------------------------------------------

-- Dire Maul tribute guards (spec §14). Option 1 at the four buff guards.
Auto.DMT_NPCS = {
    [14326] = "Mol'dar",
    [14321] = "Fengus",
    [14323] = "Slip'kik",
    [14353] = "Mizzle the Crafty",
}
-- Captain Komcrush is the exception: he also GIVES a quest, so option 1 is only
-- safe when it is the ONLY option. This guard is the reason the flow does not
-- eat a quest.
Auto.DMT_NPC_KOMCRUSH = 14325

-- BWL Orb of Command (spec §14). A GameObject, not a creature — Auto.ParseNpcID
-- already accepts the "GameObject-…" GUID kind.
Auto.BWL_ORB = 179879
-- The orb must not be used while any of these are in the quest log.
Auto.BWL_BLOCKING_QUESTS = { 85556, 85557, 85558 }

-- Darkmoon Faire fortune teller (spec §14).
Auto.SAYGE_NPC           = 14822
Auto.SAYGE_DEFAULT_BUFF  = "damage"     -- spec: default Damage for every class
Auto.SAYGE_SPAM_REPEATS  = 100          -- spec: 100 repeats…
Auto.SAYGE_SPAM_INTERVAL = 0.05         -- …at 50 ms
Auto.SAYGE_REENTRY_LOCK  = 5            -- spec: 5 s re-entry lock

-- Spec §14 page maps, keyed by the number of options the page presents. This is
-- the whole selection mechanism for every buff type except Damage: an option
-- COUNT identifies the page, the page names the INDEX. No string is read.
Auto.SAYGE_PAGE = {
    -- page 1 (4 options)
    [4] = { damage = 1, resistance = 1, armor    = 1,
            intellect = 2, spirit = 2,
            agility = 3, stamina = 3, strength = 3 },
    -- page 2 (3 options)
    [3] = { damage = 1, spirit = 1, stamina  = 1,
            resistance = 2, intellect = 2, strength = 2,
            armor = 3, agility = 3 },
}
-- Tolerated spellings for a buffType value that did not come from our own
-- dropdown (an imported profile, a hand-edited SavedVariables).
Auto.SAYGE_ALIASES = { resist = "resistance", intelligence = "intellect" }

-- Debug channel for this subsystem: `/dsn debug gossip`. Off by default; the
-- shape-mismatch WARNING below prints regardless, because the owner cannot know
-- to turn a flag on for a page shape nobody has seen yet.
Auto.DEBUG_GOSSIP = false
local function gdbg(fmt, ...)
    if Auto.DEBUG_GOSSIP and ns and ns.Print then
        ns:Print("|cff9999ff[gossip]|r " .. string.format(fmt, ...))
    end
end
Auto._gdbg = gdbg

local function selectGossipOption(optionID)
    if optionID ~= nil and C_GossipInfo and C_GossipInfo.SelectOption then
        C_GossipInfo.SelectOption(optionID)
        return true
    end
    return false
end

-- Resolve the API selector for the Nth option. Returns nil when the option or
-- its ID is absent — callers treat that as "refuse", never as "use the index".
local function optionSelector(options, index)
    local opt = options and options[index]
    if not opt then return nil end
    return opt.gossipOptionID
end

-- PURE. Dire Maul tribute guard decision. ctx: enabled, npcID, optionCount.
-- Returns (optionIndex|nil, reason). Every refusal names its own gate.
function Auto.DecideDmtOption(ctx)
    ctx = ctx or {}
    if not ctx.enabled then return nil, "disabled" end
    if ctx.npcID == nil then return nil, "unknown-npc" end
    local n = tonumber(ctx.optionCount) or 0
    if ctx.npcID == Auto.DMT_NPC_KOMCRUSH then
        -- Exactly one option, or nothing. The anti-quest-eating guard.
        if n ~= 1 then return nil, "komcrush-not-single" end
        return 1, "komcrush-single"
    end
    if not Auto.DMT_NPCS[ctx.npcID] then return nil, "wrong-npc" end
    if n < 1 then return nil, "no-options" end
    return 1, "option-1"
end

-- PURE. Orb of Command decision. ctx: enabled, npcID, optionCount,
-- onBlockingQuest. Returns (optionIndex|nil, reason).
function Auto.DecideBwlOption(ctx)
    ctx = ctx or {}
    if not ctx.enabled then return nil, "disabled" end
    if ctx.npcID == nil then return nil, "unknown-npc" end
    if ctx.npcID ~= Auto.BWL_ORB then return nil, "wrong-npc" end
    if (tonumber(ctx.optionCount) or 0) ~= 1 then return nil, "not-single-option" end
    if ctx.onBlockingQuest then return nil, "blocking-quest" end
    return 1, "option-1"
end

-- Is the player on any of 85556 / 85557 / 85558?
--
-- A MISSING API REFUSES. If C_QuestLog.IsOnQuest is not there we cannot answer
-- the spec's question, and the safe answer to "may I advance the orb?" when the
-- guard cannot be evaluated is no.
function Auto.OnBwlBlockingQuest()
    if not (C_QuestLog and C_QuestLog.IsOnQuest) then
        gdbg("C_QuestLog.IsOnQuest unavailable -- orb guard refuses")
        return true
    end
    for _, qid in ipairs(Auto.BWL_BLOCKING_QUESTS) do
        local ok, on = pcall(C_QuestLog.IsOnQuest, qid)
        if ok and on then return true, qid end
    end
    return false
end

----------------------------------------------------------------------
-- Sayge (spec §14)
----------------------------------------------------------------------

Auto._saygeDone        = false   -- the fortune has been answered this visit
Auto._saygeAt          = nil     -- GetTime() of that answer (5 s re-entry lock)
Auto._saygeSpam        = 0       -- remaining ticks of the Damage spam ladder
Auto._saygeShapeWarned = false   -- one unknown-shape chat line per visit
Auto._saygeInteractAt  = nil     -- stamped on ANY Sayge gossip, setting or not

-- The class default answer path. Spec: default Damage for every class. The
-- store now seeds that for all nine classes, and this is the belt to that
-- brace — a nil/empty/foreign value still resolves to Damage rather than
-- silently disabling the feature the way it used to.
function Auto.SaygeBuffType(dmf, classTag)
    local want = dmf and dmf.buffType and classTag and dmf.buffType[classTag]
    want = lower(trim(want or ""))
    if want == "" then want = Auto.SAYGE_DEFAULT_BUFF end
    return Auto.SAYGE_ALIASES[want] or want
end

function Auto.SaygeLocked(now)
    if Auto._saygeAt == nil then return false end
    return ((now or nowSecs()) - Auto._saygeAt) < Auto.SAYGE_REENTRY_LOCK
end

-- PURE. Spec's positional selection for a non-Damage buff type.
-- Returns (optionIndex|nil, reason). "final" is true when answering this page
-- completes the fortune (page 2), false while we are still walking pages.
--
-- SHAPE GUARD. Any option count the spec does not describe returns nil. This is
-- the deliberately paranoid half of the feature: Sayge's fortune is a permanent
-- daily buff, so refusing costs the owner one manual click, while a misclick
-- costs a day. Row 75/76 of the audit are implemented from the spec's page maps
-- and the "Damage is option 1 on both pages" premise is flagged
-- UNKNOWN-NEEDS-INGAME-VERIFY — hence the guard rather than a best guess.
function Auto.DecideSaygeOption(want, optionCount)
    local n = tonumber(optionCount) or 0
    if n == 1 then return 1, "transitional", false end   -- single-option page
    local page = Auto.SAYGE_PAGE[n]
    if not page then return nil, "unexpected-shape", false end
    local idx = page[want]
    if not idx then return nil, "unknown-bufftype", false end
    if idx > n then return nil, "index-out-of-range", false end
    return idx, "page-" .. n, (n == 3)
end

-- One chat line per visit when the page shape is not one the spec describes,
-- plus the full detail on the debug channel so the owner can capture it.
function Auto.SaygeShapeWarn(reason, options, want)
    local n = options and #options or 0
    if not Auto._saygeShapeWarned then
        Auto._saygeShapeWarned = true
        ns:Print(("Sayge: refused to answer — a %d-option page is not a shape spec §14 "
            .. "describes (%s). No fortune was taken; choose it by hand. "
            .. "Run |cffffd100/dsn debug gossip|r and re-open him to capture the options.")
            :format(n, tostring(reason)))
    end
    gdbg("sayge shape mismatch: reason=%s options=%d want=%s", tostring(reason), n, tostring(want))
    for i, opt in ipairs(options or {}) do
        gdbg("  option %d: id=%s name=%s", i, tostring(opt.gossipOptionID), tostring(opt.name))
    end
end

-- The Damage fast path (spec §14): option 1 is Damage on BOTH pages, so the
-- flow blasts option 1 through the pages instead of waiting for a server
-- round-trip per page — 100 repeats at 50 ms.
--
-- IDENTITY IS RE-CHECKED ON EVERY TICK. A blind 5 s ladder of "click option 1"
-- is precisely the hazard this whole brief exists to remove: if the player
-- walks away from Sayge and opens another NPC mid-ladder, an un-gated tick
-- would click that NPC's first option. So each tick refuses (and stops) unless
-- UnitGUID("npc") still parses to 14822. It never WAITS on anything, so the
-- spec's reason for spamming is preserved.
function Auto.SaygeSpamTick()
    if (Auto._saygeSpam or 0) <= 0 then return end
    Auto._saygeSpam = Auto._saygeSpam - 1

    if Auto.NpcID() ~= Auto.SAYGE_NPC then
        gdbg("sayge spam: NPC is no longer Sayge -- ladder stopped with %d tick(s) left",
            Auto._saygeSpam)
        Auto._saygeSpam = 0
        return
    end
    local options = C_GossipInfo and C_GossipInfo.GetOptions and C_GossipInfo.GetOptions()
    if options and options[1] then
        selectGossipOption(optionSelector(options, 1))
    end
    if Auto._saygeSpam > 0 and C_Timer and C_Timer.After then
        C_Timer.After(Auto.SAYGE_SPAM_INTERVAL, function() ns:SafeCall(Auto.SaygeSpamTick) end)
    end
end

function Auto.StartSaygeSpam()
    Auto._saygeSpam = Auto.SAYGE_SPAM_REPEATS
    Auto.SaygeSpamTick()
end

-- Called ONLY from Auto.OnGossipShow, and only once the NPC is confirmed 14822.
function Auto.HandleSayge(options, dmf)
    -- The spam ladder owns the window while it runs: a cookie-close here would
    -- shut the gossip out from under it.
    if (Auto._saygeSpam or 0) > 0 then return true end

    -- Inside the 5 s re-entry lock the fortune is already answered. The only
    -- thing left to do is close the fortune-cookie dialog (default on).
    if Auto.SaygeLocked() then
        if Auto._saygeDone and dmf.skipCookie
           and C_GossipInfo and C_GossipInfo.CloseGossip then
            C_GossipInfo.CloseGossip()
        end
        return true
    end

    local _, classTag = UnitClass("player")
    local want = Auto.SaygeBuffType(dmf, classTag)

    if want == Auto.SAYGE_DEFAULT_BUFF then
        Auto._saygeAt   = nowSecs()
        Auto._saygeDone = true
        gdbg("sayge: Damage fast path -- spamming option 1 x%d", Auto.SAYGE_SPAM_REPEATS)
        Auto.StartSaygeSpam()
        return true
    end

    local idx, why, final = Auto.DecideSaygeOption(want, #options)
    if idx == nil then
        Auto.SaygeShapeWarn(why, options, want)
        return false
    end
    local selector = optionSelector(options, idx)
    if selector == nil then
        Auto.SaygeShapeWarn("no-option-id", options, want)
        return false
    end
    if not selectGossipOption(selector) then return false end
    gdbg("sayge: want=%s options=%d -> option %d (%s)", want, #options, idx, why)
    if final then
        -- Page 2 is the last page: the buff is chosen. Arm the lock so the
        -- fortune-cookie page that follows is closed, not answered.
        Auto._saygeAt   = nowSecs()
        Auto._saygeDone = true
    end
    return true
end

-- GOSSIP_SHOW entry point.
--
-- ORDER MATTERS (1.1.4 defect fix). The gossip-window QUEST path runs FIRST,
-- ahead of every option handler, and it only ever fires on an exact quest-ID
-- match. A pickable turn-in wins the one interaction we get — which is also the
-- shape the spec's "auto-repair only when the zanza flow is idle" rule needs.
--
-- Shift is checked before anything else: spec §14 / §19.23 — holding Shift while
-- opening gossip skips the whole flow (and auto-repair) at Mau'ari, Vinchaxa,
-- Rin'wosho and Drazial. It is the FIRST statement so the escape hatch covers
-- the DMT, Orb and Sayge handlers too, not just the four NPCs §19.23 names:
-- one modifier, one rule, no exceptions to remember.
function Auto.OnGossipShow()
    if IsShiftKeyDown and IsShiftKeyDown() then return end
    if Auto.HandleGossipQuests() then return end

    if not (C_GossipInfo and C_GossipInfo.GetOptions) then return end
    local ago = agoBlock()
    local options = C_GossipInfo.GetOptions()
    if not options or #options == 0 then return end

    local npcID = Auto.NpcID()
    local n     = #options

    -- Spec §14: "Interacting with Sayge is timestamped regardless of the
    -- setting." Stamped before the dmf.enabled test for exactly that reason.
    if npcID == Auto.SAYGE_NPC then Auto._saygeInteractAt = nowSecs() end

    local idx, why = Auto.DecideDmtOption({
        enabled = ago.dmt, npcID = npcID, optionCount = n,
    })
    if idx then
        if selectGossipOption(optionSelector(options, idx)) then return end
    elseif ago.dmt and (Auto.DMT_NPCS[npcID or -1] or npcID == Auto.DMT_NPC_KOMCRUSH) then
        gdbg("dmt: refused at %s -- %s (%d option(s))", tostring(npcID), tostring(why), n)
    end

    local onBlocking = (npcID == Auto.BWL_ORB) and Auto.OnBwlBlockingQuest() or false
    idx, why = Auto.DecideBwlOption({
        enabled = ago.bwl, npcID = npcID, optionCount = n, onBlockingQuest = onBlocking,
    })
    if idx then
        if selectGossipOption(optionSelector(options, idx)) then return end
    elseif ago.bwl and npcID == Auto.BWL_ORB then
        gdbg("bwl orb: refused -- %s (%d option(s))", tostring(why), n)
    end

    if ago.dmf and ago.dmf.enabled and npcID == Auto.SAYGE_NPC then
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
-- one parent checkbox, with no resurrection. PURE.
--
-- SHAPE HARDENING (owner bug, 1.1.4). The stored list is supposed to be an
-- ARRAY of ticked keys, and Store.MigrateZanzaPriorityShape now guarantees that
-- on every login. It did not always: an older options build wrote a MAP of
-- booleans (`{ sheen = false, spirit = true, swiftness = true }`), and the
-- current one appends ARRAY entries on top of whatever map keys were already
-- there. Walking only the array part read a map-shaped table as EMPTY, empty
-- meant "all three", and the owner was handed the Sheen he had unticked.
--
-- So this reader is now shape-tolerant as well, belt to the migration's braces —
-- if the rewrite ever fails to run (a read-only save, a crash before logout, a
-- hand-edited file) the engine still refuses to dispense a flask the owner
-- opted out of:
--   * an explicitly FALSE map key is NEVER enabled, in any shape;
--   * where the array part carries recognised keys, it decides membership (it
--     is the newer UI's write) and stray map keys are ignored;
--   * a MAP-ONLY table starts from all three and removes the explicit falses,
--     matching Store.NormalizeZanzaPriority exactly, so what the engine does
--     before the migration and after it are the same thing;
--   * "all three" is reserved for a table with NO array content and NO map keys
--     at all — a genuinely fresh `{}`, which is the only shape that has never
--     recorded a preference.
function Auto.ZanzaEnabledPicks(priority)
    local out = {}
    local function allThree()
        for _, r in ipairs(Auto.ZANZA_REWARDS) do out[#out + 1] = r.key end
        return out
    end
    if type(priority) ~= "table" then return allThree() end

    local n = #priority

    -- Array part, recognised keys only.
    local known, arrayHas, arrayN = {}, {}, 0
    for _, r in ipairs(Auto.ZANZA_REWARDS) do known[r.key] = true end
    for i = 1, n do
        local v = priority[i]
        if type(v) == "string" then
            local k = lower(v)
            if known[k] and not arrayHas[k] then arrayHas[k] = true; arrayN = arrayN + 1 end
        end
    end

    -- Map part: every non-array key counts as "a preference was recorded here",
    -- and an explicit false is an opt-out.
    local mapFalse, mapKeys = {}, 0
    for k, v in pairs(priority) do
        if not (type(k) == "number" and k % 1 == 0 and k >= 1 and k <= n) then
            mapKeys = mapKeys + 1
            if type(k) == "string" and v == false then mapFalse[lower(k)] = true end
        end
    end

    if arrayN == 0 and mapKeys == 0 then return allThree() end

    for _, r in ipairs(Auto.ZANZA_REWARDS) do
        local member
        if arrayN > 0 then member = (arrayHas[r.key] == true)   -- the array decides
        else               member = true end                    -- map-only: absent reads as on
        if member and not mapFalse[r.key] then out[#out + 1] = r.key end
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
        -- SHAPE (1.1.4): feed PickReward the ENABLED PICKS, never the raw stored
        -- list. PickReward walks its priority with ipairs, so a map-shaped store
        -- handed it nothing and it silently fell through to "take choice 1" —
        -- the same shape bug as the zanza reader, one call site over, and choice
        -- 1 can be a flask the owner unticked. ZanzaEnabledPicks normalises the
        -- shape AND re-imposes the spec order, and its keys ("swiftness", ...)
        -- are exactly the substrings PickReward matches reward names on.
        local stored = flags.zanza and aqBlock().zanza and aqBlock().zanza.priority or nil
        local priority = stored and Auto.ZanzaEnabledPicks(stored) or nil
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
-- Auto-repair — MERCHANT_SHOW + RepairAllItems (globals)
--
-- OWNER WAIVER (2026-08-05). Spec §14 scopes auto-repair to Rin'wosho, entered
-- by the addon selecting his vendor gossip option, and §19.21 states it as an
-- absolute: "Auto-repair only ever touches a merchant window the addon itself
-- opened." What ships here is the inverse — it repairs on a merchant window the
-- PLAYER opened, at ANY vendor — and Drew has APPROVED that as the shipped
-- behaviour ("im fine with auto repairing at any vendor"). It is a deliberate
-- divergence from spec, recorded here so the next audit reads it as a decision
-- and not as drift. Do not re-scope it to Rin'wosho without the owner.
--
-- What the waiver did NOT cover is HONESTY, and that is what this function
-- owes: the setting used to be labelled "Auto-repair at Rin'wosho" while
-- repairing everywhere, the repair printed a bare line with no cost, and an
-- unaffordable repair fell through in total silence — indistinguishable from a
-- broken feature. All three are fixed (label lives in options.lua).
----------------------------------------------------------------------

-- Money for humans. Prefers the client's coin-icon string; the plain-text
-- fallback is what the headless harness and any stripped client see.
function Auto.FormatMoney(copper)
    copper = math.floor(tonumber(copper) or 0)
    if GetCoinTextureString then
        local ok, s = pcall(GetCoinTextureString, copper)
        if ok and type(s) == "string" and s ~= "" then return s end
    end
    return string.format("%dg %ds %dc",
        math.floor(copper / 10000),
        math.floor((copper % 10000) / 100),
        copper % 100)
end

function Auto.OnMerchantShow()
    if not aqBlock().autoRepair then return end
    if not (CanMerchantRepair and CanMerchantRepair()) then return end
    local cost = math.floor(tonumber(GetRepairAllCost and GetRepairAllCost() or 0) or 0)
    if cost <= 0 then return end                       -- nothing damaged: silent
    local money = math.floor(tonumber(GetMoney and GetMoney() or 0) or 0)
    if money < cost then
        -- Spec §14's "not enough gold" line. Silence here used to look exactly
        -- like the feature being broken.
        ns:Print("auto-repair: not enough gold — repairing costs "
            .. Auto.FormatMoney(cost) .. ", you have " .. Auto.FormatMoney(money) .. ".")
        return
    end
    if RepairAllItems then RepairAllItems() end
    ns:Print("auto-repaired for " .. Auto.FormatMoney(cost) .. ".")
end

----------------------------------------------------------------------
-- Zone-change resets (Sayge/session guards clear when we move away)
----------------------------------------------------------------------

function Auto.OnZoneChanged()
    Auto._saygeDone        = false
    Auto._saygeShapeWarned = false
    -- The spam ladder is torn down on a zone change: its per-tick NPC check
    -- would stop it anyway, this just does not wait for the next tick. The 5 s
    -- re-entry lock (_saygeAt) is NOT cleared — spec makes it a time guard, and
    -- clearing it on zone change is the very approximation this wave removed.
    Auto._saygeSpam = 0
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
    -- Spec §12.1 failure counting: the client answers a doomed invite with a
    -- system line, and that line is the ONLY evidence there is. The sink is
    -- inert unless an invite run is open (Auto.OnSystemMessage returns on its
    -- first statement), so this is not a general system-chat parser.
    ns:RegisterEvent("CHAT_MSG_SYSTEM", function(_, text)
        ns:SafeCall(Auto.OnSystemMessage, text)
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

    -- Seed trigger-buff state so a buff already up at login isn't counted as a
    -- fresh gain (spec §4.3: fresh-buff detection is suppressed until the first
    -- scan has stabilised — login fires aura-applied for every existing buff).
    ns:SafeCall(Auto.ScanTriggerBuffs)
    Auto.ClearTriggerGain()
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

----------------------------------------------------------------------
-- SPEC §13 FRESH-BUFF RULE TABLE — one assertion per clause.
--
-- Every row here is a rule the shipped detector did not have. The unboon row is
-- the adversarial one: run it against the pre-fix code and it goes green on the
-- WRONG answer, because absent->live was the whole test.
--
-- Headless discipline: no timers, no aura API, no live store. The BOON facts
-- come from a fixture record shaped exactly like the tracker's own
-- rec.auraStates (source = Store.AURA_SOURCE.BOON = 2 on the boonable slots),
-- read through the same Auto.BoonedTriggersIn the live path uses.
----------------------------------------------------------------------

-- All ten triggers on, so a row that fails fails on the RULE, not on config.
local function allTriggers()
    local t = {}
    for _, def in ipairs(Auto.SUMMON_TRIGGER_BUFFS) do t[def.key] = true end
    return t
end

local function hasKey(list, key)
    for i = 1, #list do if list[i] == key then return true end end
    return false
end

local function testFreshBuffRules()
    local T = allTriggers()
    local function classify(prev, cur, unboon)
        return Auto.ClassifyTriggerGains(prev, cur, { triggers = T, inUnboonWindow = unboon })
    end
    local A = { state = "absent", duration = 0 }
    local function live(d) return { state = "live", duration = d } end
    local function boon(d) return { state = "booned", duration = d or 0 } end

    -- 1. absent -> live is fresh (the one clause the old code did have).
    local f = classify({ songflower = A }, { songflower = live(3600) })
    if not hasKey(f, "songflower") then return false, "absent->live must be fresh" end

    -- 2. live -> live with the duration TICKING DOWN is not a gain.
    f = classify({ songflower = live(3600) }, { songflower = live(3500) })
    if hasKey(f, "songflower") then return false, "live->live tick-down must not be fresh" end

    -- 3. live -> live jumping by MORE than 75 s is a refresh, and is fresh.
    f = classify({ songflower = live(600) }, { songflower = live(676) })
    if not hasKey(f, "songflower") then return false, "live->live +76s must be fresh" end

    -- 4. …and exactly 75 s is not more than 75 s. Boundary, both sides.
    f = classify({ songflower = live(600) }, { songflower = live(675) })
    if hasKey(f, "songflower") then return false, "live->live +75s must NOT be fresh" end

    -- 5. booned -> live is NEVER fresh. Releasing a chronoboon gives you back
    --    buffs you already had; it is not a pickup, at any duration.
    f = classify({ songflower = boon(3600) }, { songflower = live(3600) })
    if hasKey(f, "songflower") then return false, "booned->live must never be fresh" end
    f = classify({ warchief = boon(100) }, { warchief = live(3600) })
    if hasKey(f, "warchief") then return false, "booned->live is not fresh even on a jump" end

    -- 6. THE UNBOON WINDOW. Inside the tracker's 3 s post-unboon grace, a
    --    BOONABLE slot appearing is the restore landing — not a gain — even when
    --    the previous state read absent (the scan that catches the restore
    --    mid-flight sees exactly that).
    f = classify({ songflower = A, warchief = A, dragonslayer = A },
                 { songflower = live(3600), warchief = live(3600), dragonslayer = live(3600) },
                 true)
    if #f > 0 then return false, "unboon window must exclude every boonable gain" end

    -- 7. …but Battle Shout and FFF are NOT boonable (spec §4.1), so a real one
    --    landing during that same 3 s is still a real gain.
    f = classify({ battleShout = A, fff = A },
                 { battleShout = live(1800), fff = live(3600) }, true)
    if not (hasKey(f, "battleShout") and hasKey(f, "fff")) then
        return false, "unboon window must not swallow the non-boonable slots"
    end

    -- 8. A buff going away is not a gain, and an unconfigured trigger never is.
    f = classify({ songflower = live(600) }, { songflower = A })
    if #f > 0 then return false, "live->absent must not be fresh" end
    f = Auto.ClassifyTriggerGains({ songflower = A }, { songflower = live(3600) },
                                  { triggers = {} })
    if #f > 0 then return false, "an unticked trigger never counts" end

    -- 9. The state reader folds the store's BOON cells and the live aura list
    --    into the states the classifier consumes. This is the seam the fix turns
    --    on, so it is asserted against a real-shaped record, not a hand table.
    local BOON = (ns.Store and ns.Store.AURA_SOURCE and ns.Store.AURA_SOURCE.BOON) or 2
    local rec = { auraStates = {
        [4] = { duration = 3600, option = 0, source = BOON },   -- Songflower, booned
        [2] = { duration = 3000, option = 0, source = BOON },   -- Rend, booned
        [9] = { duration = 1800, option = 0, source = 0    },   -- Battle Shout, live
    } }
    local booned = Auto.BoonedTriggersIn(rec)
    if not (booned.songflower and booned.warchief) then
        return false, "BoonedTriggersIn must read source==BOON cells"
    end
    if booned.battleShout then return false, "a LIVE cell must not read as booned" end

    local states = Auto.BuildTriggerStates({ battleShout = 1800 }, booned)
    if states.songflower.state ~= "booned" then return false, "booned slot -> booned state" end
    if states.battleShout.state ~= "live"  then return false, "live aura -> live state" end
    if states.fff.state ~= "absent"        then return false, "unseen slot -> absent state" end

    -- 10. THE HEADLINE CASE, end to end. Seven buffs are in the boon; the player
    --     pops the displacer; every one of them flips to live in the same beat.
    --     Pre-fix this produced seven fresh gains and armed the summon gate.
    local before = Auto.BuildTriggerStates({}, booned)
    local afterLive = {}
    for _, k in ipairs({ "songflower", "warchief" }) do afterLive[k] = 3600 end
    local after = Auto.BuildTriggerStates(afterLive, {})
    f = Auto.ClassifyTriggerGains(before, after, { triggers = T, inUnboonWindow = true })
    if #f > 0 then return false, "unbooning must produce ZERO fresh gains" end
    -- …and it stays zero even if the unboon window has already elapsed, because
    -- booned->live carries the exclusion on its own.
    f = Auto.ClassifyTriggerGains(before, after, { triggers = T, inUnboonWindow = false })
    if #f > 0 then return false, "unbooning is not fresh even outside the 3s window" end

    return true
end

-- The whole point of the freshness gate is what it does to the SUMMON. Drives
-- the real gain state through the real decision matrix on a simulated clock.
local function testSummonFreshnessGate()
    local saveGain, saveNames = Auto._lastTriggerGain, Auto._lastTriggerNames
    local saveTime = _G.GetTime
    local clock = 1000
    _G.GetTime = function() return clock end

    local W = 19
    local function decide()
        return Auto.DecideSummon({ enabled = true, triggerAge = Auto.TriggerBuffAge(), window = W })
    end
    local function restore()
        _G.GetTime = saveTime
        Auto._lastTriggerGain, Auto._lastTriggerNames = saveGain, saveNames
    end

    -- A plain fresh gain inside the window opens the gate.
    Auto._lastTriggerGain, Auto._lastTriggerNames = clock, { "songflower" }
    clock = 1005
    local ok, why = decide()
    if not (ok and why == "freshbuff") then restore(); return false, "fresh gain within 19s accepts" end

    -- The same gain, stale, does not.
    clock = 1000 + W + 1
    if decide() then restore(); return false, "a gain older than the window must not accept" end

    -- ACCEPTING CLEARS THE FLAG (spec §13). A second summon inside the same
    -- window has to wait for a NEW buff — this is the row that stops one
    -- Songflower buying every summon for 19 seconds.
    clock = 1000
    Auto._lastTriggerGain, Auto._lastTriggerNames = clock, { "songflower" }
    clock = 1002
    if not (decide()) then restore(); return false, "first summon accepts" end
    Auto.ClearTriggerGain()
    if Auto.TriggerBuffAge() ~= nil then restore(); return false, "clear drops the gain age" end
    if decide() then restore(); return false, "second summon inside the window must NOT accept" end
    if Auto.TriggerBuffLabels() ~= nil then restore(); return false, "clear drops the labels too" end

    -- The accept line names the buffs, not the reason word (spec §13).
    Auto._lastTriggerNames = { "songflower", "warchief" }
    local labels = Auto.TriggerBuffLabels() or ""
    if not (labels:find("Songflower Serenade", 1, true)
            and labels:find("Warchief's Blessing", 1, true)) then
        restore(); return false, "TriggerBuffLabels must name the buffs"
    end

    restore()
    return true
end

-- Spec §4.1 slot 10 is Fire Festival Fury (29338 / 29846). The catalog carried
-- "fervor of the first feast", which is the name of nothing, so the FFF trigger
-- could never match anything the client reported.
local function testTriggerCatalog()
    local byKey = {}
    for _, def in ipairs(Auto.SUMMON_TRIGGER_BUFFS) do
        byKey[def.key] = def
        if not def.slot or not def.label then return false, "catalog row missing slot/label" end
    end
    if byKey.fff.prefix ~= "fire festival fury" then
        return false, "FFF prefix must be Fire Festival Fury"
    end
    if byKey.fff.slot ~= 10 or byKey.battleShout.slot ~= 9 then
        return false, "FFF/Battle Shout must be tracker slots 10/9"
    end
    -- …and those two are the ONLY non-boonable triggers.
    if Auto.TRIGGER_BOONABLE.fff or Auto.TRIGGER_BOONABLE.battleShout then
        return false, "slots 9/10 must not be boonable"
    end
    for _, k in ipairs({ "dragonslayer", "warchief", "zandalar", "songflower",
                         "dmf", "fengus", "moldar", "slipkik" }) do
        if not Auto.TRIGGER_BOONABLE[k] then return false, k .. " must be boonable" end
    end
    -- Identity resolves through the tracker's spell-ID-first matcher, so every
    -- catalog slot must be a slot the tracker actually knows.
    if ns.Tracker and ns.Tracker.MatchAura then
        if ns.Tracker.MatchAura(29338, nil) ~= 10 then return false, "29338 -> slot 10" end
        if ns.Tracker.MatchAura(nil, "Fire Festival Fury") ~= 10 then
            return false, "FFF name -> slot 10"
        end
        if ns.Tracker.MatchAura(15366, nil) ~= 4 then return false, "15366 -> slot 4" end
    end
    if Auto.FRESH_REFRESH_JUMP ~= 75 then return false, "the refresh jump must be 75s" end
    return true
end

----------------------------------------------------------------------
-- SPEC §12.1 INVITE-RUN RULE TABLE.
--
-- The ladder is driven through Auto._after, the injected scheduler, so the test
-- reads the DELAYS the run asked for rather than waiting for any of them. The
-- harness stubs C_Timer.After as a no-op; a test that relied on it would assert
-- nothing at all.
----------------------------------------------------------------------

local function testInviteTargets()
    -- Two accounts of ours, one of them holding an offline alt and a
    -- wrong-faction character; one live mesh peer with no local record at all;
    -- one alt already standing in the group; and ourselves.
    local accounts = {
        ["1"] = { characters = {
            ["Zeta-R"]    = { faction = "Horde", lastSeen = 100 },
            ["Alpha-R"]   = { faction = "Horde", lastSeen = 100 },
            ["Offline-R"] = { faction = "Horde", lastSeen = 0 },
            ["Ally-R"]    = { faction = "Alliance", lastSeen = 100 },
            ["Me-R"]      = { faction = "Horde", lastSeen = 100 },
        }, homeless = {
            ["Homie-R"] = { faction = "Horde", lastSeen = 100 },
        } },
        ["2"] = { characters = {
            ["Grouped-R"] = { faction = "Horde", lastSeen = 100 },
        }, homeless = {} },
    }
    local peers = {
        ["3"] = { name = "Peer-R",    online = true },
        ["4"] = { name = "Dropped-R", online = false },
    }
    local targets = Auto.BuildInviteTargets({
        accounts = accounts, peers = peers, faction = "Horde", me = "Me-R",
        inGroup  = { ["Grouped-R"] = true },
        isOnline = function(_, rec) return (rec.lastSeen or 0) > 0 end,
    })

    local want = { "Alpha-R", "Homie-R", "Peer-R", "Zeta-R" }
    if #targets ~= #want then
        return false, "target count: got " .. #targets .. " want " .. #want
    end
    for i = 1, #want do
        -- ALPHABETICAL. The old run used pairs(), so the order was whatever the
        -- hash gave it — non-deterministic between two runs on the same data.
        if targets[i] ~= want[i] then
            return false, "sorted targets[" .. i .. "] = " .. tostring(targets[i])
        end
    end
    return true
end

local function testInvitePacing()
    -- 60 ms apart, and the 5th pinned to 700 ms.
    local s = Auto.InviteSchedule(8)
    local function near(a, b) return math.abs(a - b) < 1e-9 end
    if not near(s[1], 0)    then return false, "first invite is immediate" end
    if not near(s[2], 0.06) then return false, "2nd at 60ms" end
    if not near(s[3], 0.12) then return false, "3rd at 120ms" end
    if not near(s[4], 0.18) then return false, "4th at 180ms" end
    if not near(s[5], 0.70) then return false, "5th pinned to 700ms" end
    -- …and the ladder stays monotone past the pin: the 6th does not overtake it.
    if not near(s[6], 0.76) then return false, "6th continues 60ms behind the 5th" end
    if not near(s[7], 0.82) then return false, "7th at 820ms" end
    for i = 2, 8 do
        if s[i] <= s[i - 1] then return false, "schedule must be strictly increasing" end
    end
    -- A run shorter than five invites never reaches the pin.
    local short = Auto.InviteSchedule(3)
    if #short ~= 3 or not near(short[3], 0.12) then return false, "short run keeps 60ms spacing" end
    if #Auto.InviteSchedule(0) ~= 0 then return false, "empty run schedules nothing" end
    return true
end

local function testInviteFailureParse()
    local yes = {
        "Zeta is already in a group.",
        "ALREADY IN A PARTY",
        "That player is already in another group",
    }
    for _, m in ipairs(yes) do
        if not Auto.IsAlreadyInGroupMessage(m) then return false, "should match: " .. m end
    end
    local no = {
        "Zeta is not online.",
        "You have already learned that spell.",   -- "already", no group/party
        "You have joined the group.",             -- group, no "already"
        "", nil,
    }
    for _, m in ipairs(no) do
        if Auto.IsAlreadyInGroupMessage(m) then return false, "should not match: " .. tostring(m) end
    end

    -- Outcome: only "every one failed, and we are alone" earns the fallback.
    if Auto.DecideInviteOutcome({ sent = 4, failures = 4, alone = true }) ~= "reverse" then
        return false, "all-failed + alone -> reverse invite"
    end
    if Auto.DecideInviteOutcome({ sent = 4, failures = 3, alone = true }) ~= "done" then
        return false, "one invite landed -> no reverse"
    end
    if Auto.DecideInviteOutcome({ sent = 4, failures = 4, alone = false }) ~= "done" then
        return false, "already in a group -> no reverse"
    end
    if Auto.DecideInviteOutcome({ sent = 0, failures = 0, alone = true }) ~= "done" then
        return false, "an empty run never reverses"
    end
    return true
end

-- The whole run, on the injected scheduler: what got invited, in what order,
-- at what delay, and what the failure path did.
local function testInviteRunLive()
    local saveAfter   = Auto._after
    local saveTargets = Auto.InviteTargets
    -- C_PartyInfo is a real-client namespace the headless world does not carry;
    -- stand one up for the run and take it back down afterwards.
    local savePartyInfo = _G.C_PartyInfo
    _G.C_PartyInfo = _G.C_PartyInfo or {}
    local saveInvite  = _G.C_PartyInfo.InviteUnit
    local saveLeave   = _G.LeaveParty
    local saveWhisper = _G.SendChatMessage
    local saveMembers = _G.GetNumGroupMembers
    local saveRun     = Auto._inviteRun

    local queue, invited, left, whispers = {}, {}, 0, {}
    Auto._after = function(delay, fn) queue[#queue + 1] = { delay = delay, fn = fn } end
    -- The target set has its own rule table above (testInviteTargets); this
    -- scenario is about the LADDER, so it is fed a fixed, already-sorted list
    -- rather than whatever the shared harness store happens to hold.
    Auto.InviteTargets = function() return { "Alpha-TestRealm", "Zeta-TestRealm" } end
    _G.C_PartyInfo.InviteUnit = function(n) invited[#invited + 1] = n end
    _G.LeaveParty = function() left = left + 1 end
    _G.SendChatMessage = function(msg, chan, _, to)
        whispers[#whispers + 1] = { msg = msg, chan = chan, to = to }
    end
    _G.GetNumGroupMembers = function() return 0 end

    local function drain()
        -- Fire in scheduled order, exactly once each. Bounded by the queue we
        -- built, so this cannot loop.
        local pending = queue
        queue = {}
        table.sort(pending, function(a, b) return a.delay < b.delay end)
        for i = 1, #pending do pending[i].fn() end
    end
    local function restore()
        Auto._after = saveAfter
        Auto.InviteTargets = saveTargets
        _G.C_PartyInfo.InviteUnit = saveInvite
        _G.C_PartyInfo = savePartyInfo
        _G.LeaveParty, _G.SendChatMessage = saveLeave, saveWhisper
        _G.GetNumGroupMembers = saveMembers
        Auto._inviteRun = saveRun
    end

    -- 1. NOTHING FIRES IN THE CALLING FRAME. The old run pushed every invite in
    --    one burst, which is the shape the client throttles.
    local n = Auto.InviteOnline(true)
    if n ~= 2 then restore(); return false, "two targets -> two invites, got " .. tostring(n) end
    if #invited ~= 0 then restore(); return false, "invites must be scheduled, not sent inline" end
    if #queue < 2 then restore(); return false, "the ladder must schedule one call per target" end
    if not (queue[1].delay == 0 and math.abs(queue[2].delay - 0.06) < 1e-9) then
        restore(); return false, "live ladder must use the 60ms spacing"
    end

    drain()
    if not (invited[1] == "Alpha-TestRealm" and invited[2] == "Zeta-TestRealm") then
        restore(); return false, "live run must invite in alphabetical order"
    end

    -- 2. THE REVERSE INVITE. Every invite comes back "already in a group" and we
    --    are on our own -> leave, then whisper the keyword to the first target.
    invited, left, whispers = {}, 0, {}
    Auto.InviteOnline(true)
    local kw = Auto._inviteRun.keyword
    for _ = 1, 2 do Auto.OnSystemMessage("Alpha-TestRealm is already in a group.") end
    drain()          -- ladder + the run-close callback
    drain()          -- the 0.3s post-LeaveParty whisper
    if left ~= 1 then restore(); return false, "reverse path must leave the party once" end
    if #whispers ~= 1 then restore(); return false, "reverse path must whisper exactly once" end
    if whispers[1].to ~= "Alpha-TestRealm" or whispers[1].msg ~= kw
       or whispers[1].chan ~= "WHISPER" then
        restore(); return false, "reverse whisper must send the keyword to the first target"
    end

    -- 3. One invite landing is enough to call the run a success: no leave, no
    --    whisper, however many of the others bounced.
    invited, left, whispers = {}, 0, {}
    Auto.InviteOnline(true)
    Auto.OnSystemMessage("Alpha-TestRealm is already in a group.")
    drain(); drain()
    if left ~= 0 or #whispers ~= 0 then
        restore(); return false, "a partly-successful run must not reverse-invite"
    end

    -- 4. The system sink is inert once the run is closed — it is not a general
    --    system-chat parser.
    if Auto.OnSystemMessage("someone is already in a group") ~= false then
        restore(); return false, "system sink must be inert outside a run"
    end

    restore()
    return true
end

-- Spec §12.3: when we cannot invite, point the requester at the live group
-- leader — and only when that leader is one of ours.
local function testWhisperRedirect()
    -- Can-invite truth table.
    if not Auto.CanInviteIn({ inGroup = false }) then return false, "solo can invite" end
    if not Auto.CanInviteIn({ inGroup = true, isLeader = true }) then
        return false, "party leader can invite"
    end
    if Auto.CanInviteIn({ inGroup = true, isLeader = false }) then
        return false, "party member without lead cannot invite"
    end
    if Auto.CanInviteIn({ inGroup = true, inRaid = true, isLeader = false, isAssistant = false }) then
        return false, "raid member without lead/assist cannot invite"
    end
    if not Auto.CanInviteIn({ inGroup = true, inRaid = true, isAssistant = true }) then
        return false, "raid assistant can invite"
    end

    -- Routing.
    local r = Auto.DecideWhisperRoute({ canInvite = true, leader = "Boss-R", leaderInMesh = true })
    if r ~= "invite" then return false, "if we can invite, we invite" end
    local to
    r, to = Auto.DecideWhisperRoute({
        canInvite = false, leader = "Boss-R", leaderInMesh = true, me = "Me-R" })
    if not (r == "redirect" and to == "Boss-R") then return false, "mesh leader -> redirect" end
    -- THE PRIVACY RULE: a leader who is NOT in our mesh is a stranger, and we do
    -- not hand a stranger's name out to whoever whispered us.
    r = Auto.DecideWhisperRoute({
        canInvite = false, leader = "Stranger-R", leaderInMesh = false, me = "Me-R" })
    if r ~= "ignore" then return false, "non-mesh leader must not be leaked" end
    r = Auto.DecideWhisperRoute({ canInvite = false, leader = nil, me = "Me-R" })
    if r ~= "ignore" then return false, "no leader -> ignore" end
    r = Auto.DecideWhisperRoute({
        canInvite = false, leader = "Me-R", leaderInMesh = true, me = "Me-R" })
    if r ~= "ignore" then return false, "never redirect to ourselves" end

    -- The dead key is GONE: nothing in this file may read it again.
    if Auto.RedirectLeader ~= nil then return false, "redirectLeader must not come back" end
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

----------------------------------------------------------------------
-- NPC-GATED GOSSIP RULE TABLE (spec §14) — one assertion per rule.
--
-- This block replaces testOptionMatcher, which asserted that the DMT keyword
-- pool picked "Spare King Gordok" out of an option list with no NPC context at
-- all. That test PASSED for the entire life of the defect: it codified the
-- divergence (the audit's row 64) instead of catching it. What follows asserts
-- identity first and index second, which is what the spec actually says.
----------------------------------------------------------------------

-- RULE: DMT is scoped to 14326 / 14321 / 14323 / 14353 and picks option 1;
-- Komcrush (14325) picks option 1 ONLY when exactly one option is present.
local function testDmtGate()
    for id, who in pairs(Auto.DMT_NPCS) do
        local idx, why = Auto.DecideDmtOption({ enabled = true, npcID = id, optionCount = 3 })
        if idx ~= 1 then return false, who .. " (" .. id .. ") must pick option 1, got " .. tostring(why) end
    end
    -- The four IDs the spec names, spelled out so a typo in the table is caught.
    for _, id in ipairs({ 14326, 14321, 14323, 14353 }) do
        if not Auto.DMT_NPCS[id] then return false, "spec NPC " .. id .. " missing from DMT_NPCS" end
    end
    if Auto.DMT_NPCS[Auto.DMT_NPC_KOMCRUSH] then
        return false, "Komcrush must NOT be in the plain option-1 set"
    end
    if Auto.DMT_NPC_KOMCRUSH ~= 14325 then return false, "Komcrush is NPC 14325" end

    -- Komcrush: exactly one option, or nothing. The anti-quest-eating guard.
    local idx, why = Auto.DecideDmtOption({ enabled = true, npcID = 14325, optionCount = 1 })
    if idx ~= 1 then return false, "Komcrush with one option picks it, got " .. tostring(why) end
    idx, why = Auto.DecideDmtOption({ enabled = true, npcID = 14325, optionCount = 2 })
    if idx ~= nil or why ~= "komcrush-not-single" then
        return false, "Komcrush with TWO options must refuse (it would eat a quest)"
    end
    idx = Auto.DecideDmtOption({ enabled = true, npcID = 14325, optionCount = 0 })
    if idx ~= nil then return false, "Komcrush with no options must refuse" end

    -- Identity gates.
    if Auto.DecideDmtOption({ enabled = false, npcID = 14326, optionCount = 1 }) ~= nil then
        return false, "disabled must refuse"
    end
    if Auto.DecideDmtOption({ enabled = true, npcID = 99999, optionCount = 1 }) ~= nil then
        return false, "an unrelated NPC must refuse"
    end
    local _, r = Auto.DecideDmtOption({ enabled = true, npcID = nil, optionCount = 1 })
    if r ~= "unknown-npc" then return false, "an unparseable GUID must refuse, got " .. tostring(r) end
    return true
end

-- RULE: the Orb is object 179879, picks option 1 only when exactly one option
-- exists, and only when not on 85556 / 85557 / 85558.
local function testBwlGate()
    if Auto.BWL_ORB ~= 179879 then return false, "the Orb is object 179879" end
    local want = { [85556] = true, [85557] = true, [85558] = true }
    local seen = {}
    for _, q in ipairs(Auto.BWL_BLOCKING_QUESTS) do
        if not want[q] then return false, "unexpected blocking quest " .. tostring(q) end
        seen[q] = true
    end
    for q in pairs(want) do
        if not seen[q] then return false, "blocking quest " .. q .. " missing" end
    end

    local base = { enabled = true, npcID = 179879, optionCount = 1, onBlockingQuest = false }
    local function with(over)
        local c = {}
        for k, v in pairs(base) do c[k] = v end
        for k, v in pairs(over or {}) do c[k] = v end
        return Auto.DecideBwlOption(c)
    end
    if with(nil) ~= 1 then return false, "single option, no blocking quest -> option 1" end
    local idx, why = Auto.DecideBwlOption({ enabled = true, npcID = 179879,
                                            optionCount = 2, onBlockingQuest = false })
    if idx ~= nil or why ~= "not-single-option" then
        return false, "TWO options must refuse (single-option guard)"
    end
    idx, why = Auto.DecideBwlOption({ enabled = true, npcID = 179879,
                                       optionCount = 1, onBlockingQuest = true })
    if idx ~= nil or why ~= "blocking-quest" then
        return false, "on 85556/85557/85558 the orb must refuse"
    end
    if with({ enabled = false }) ~= nil then return false, "disabled must refuse" end
    if with({ npcID = 14326 }) ~= nil then return false, "a DMT NPC must not drive the orb" end
    -- Spelled out rather than routed through with(): a nil in the override table
    -- is invisible to pairs(), so it would silently test the wrong thing.
    local _, r = Auto.DecideBwlOption({ enabled = true, npcID = nil,
                                        optionCount = 1, onBlockingQuest = false })
    if r ~= "unknown-npc" then return false, "an unparseable GUID must refuse" end
    return true
end

-- RULE: Sayge's two page maps (spec §14) are positional, and ANY page shape the
-- spec does not describe is refused rather than guessed.
local function testSaygePageMaps()
    local page1 = { damage = 1, resistance = 1, armor = 1,
                    intellect = 2, spirit = 2,
                    agility = 3, stamina = 3, strength = 3 }
    for want, expect in pairs(page1) do
        local idx, why, final = Auto.DecideSaygeOption(want, 4)
        if idx ~= expect then
            return false, ("page 1: %s -> %s, expected %d (%s)")
                :format(want, tostring(idx), expect, tostring(why))
        end
        if final then return false, "page 1 is not the final page" end
    end
    local page2 = { damage = 1, spirit = 1, stamina = 1,
                    resistance = 2, intellect = 2, strength = 2,
                    armor = 3, agility = 3 }
    for want, expect in pairs(page2) do
        local idx, _, final = Auto.DecideSaygeOption(want, 3)
        if idx ~= expect then
            return false, ("page 2: %s -> %s, expected %d"):format(want, tostring(idx), expect)
        end
        if not final then return false, "page 2 IS the final page (it arms the lock)" end
    end

    -- A single-option transitional page always picks 1, and does NOT count as
    -- the final answer (arming the lock there would block the real buff page).
    local idx, why, final = Auto.DecideSaygeOption("armor", 1)
    if idx ~= 1 or why ~= "transitional" or final then
        return false, "a single-option page picks 1 and is not final"
    end

    -- THE SHAPE GUARD. Refusing costs one manual click; a misclick costs a
    -- permanent daily buff. Every unknown shape refuses.
    for _, n in ipairs({ 0, 2, 5, 6, 12 }) do
        local i, r = Auto.DecideSaygeOption("damage", n)
        if i ~= nil or r ~= "unexpected-shape" then
            return false, ("a %d-option page must be refused, got %s/%s"):format(n, tostring(i), tostring(r))
        end
    end
    local i, r = Auto.DecideSaygeOption("nonsense", 4)
    if i ~= nil or r ~= "unknown-bufftype" then return false, "an unmappable buff type refuses" end

    -- The class-default answer path: nil / "" / an alias all resolve.
    if Auto.SaygeBuffType({ buffType = {} }, "MAGE") ~= "damage" then
        return false, "an unset class defaults to damage"
    end
    if Auto.SaygeBuffType({ buffType = { MAGE = "" } }, "MAGE") ~= "damage" then
        return false, "an empty string defaults to damage"
    end
    if Auto.SaygeBuffType(nil, nil) ~= "damage" then return false, "a nil block defaults to damage" end
    if Auto.SaygeBuffType({ buffType = { MAGE = "Resist" } }, "MAGE") ~= "resistance" then
        return false, "'resist' is tolerated as resistance"
    end
    if Auto.SaygeBuffType({ buffType = { MAGE = "intelligence" } }, "MAGE") ~= "intellect" then
        return false, "'intelligence' is tolerated as intellect"
    end
    return true
end

----------------------------------------------------------------------
-- LIVE PATH. Every rule above, re-asserted through Auto.OnGossipShow itself
-- against a stubbed gossip API — because the defect this replaces was never in
-- the matcher, it was in the ABSENCE of a caller-side gate. A pure test of a
-- pure function could not have caught it, and did not.
--
-- The adversarial fixture is the audit's own headline: an unrelated NPC whose
-- option list contains "Spare King Gordok", "Free the prisoner" and "Enter
-- Blackwing Lair" — every keyword the deleted pools carried. Nothing may fire.
--
-- Every global is saved and restored, including C_Timer (so the Damage spam
-- ladder cannot escape the test and click at a real NPC afterwards).
----------------------------------------------------------------------
local function testGossipLivePath()
    local SAVE = {}
    local NAMES = { "C_GossipInfo", "C_QuestLog", "UnitGUID", "IsShiftKeyDown",
                    "UnitClass", "GetTime", "C_Timer", "print" }
    for _, k in ipairs(NAMES) do SAVE[k] = _G[k] end

    local fs  = Auto.FactionSettings and Auto.FactionSettings() or nil
    if type(fs) ~= "table" or type(fs.autoGossip) ~= "table" then
        return false, "the live autoGossip block is reachable"
    end
    local savedAGO = fs.autoGossip
    local savedSayge = { Auto._saygeDone, Auto._saygeAt, Auto._saygeSpam,
                         Auto._saygeShapeWarned, Auto._saygeInteractAt }

    -- The world.
    local W = { guid = nil, shift = false, options = {}, onQuest = {}, class = "MAGE", clock = 5000 }
    local CALLS, said
    local function reset()
        CALLS = { select = {}, close = 0, getOptions = 0 }
        said  = {}
    end
    reset()

    _G.GetTime        = function() return W.clock end
    _G.IsShiftKeyDown = function() return W.shift end
    _G.UnitGUID       = function(unit) if unit == "npc" then return W.guid end return nil end
    _G.UnitClass      = function() return "Mage", W.class end
    _G.C_QuestLog     = { IsOnQuest = function(q) return W.onQuest[q] == true end }
    _G.C_Timer        = { After = function() end }      -- the ladder cannot escape
    _G.print          = function(...)
        local p = {}
        for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
        said[#said + 1] = table.concat(p, "\t")
    end
    _G.C_GossipInfo = {
        GetAvailableQuests = function() return {} end,
        GetActiveQuests    = function() return {} end,
        SelectAvailableQuest = function(id) CALLS.select[#CALLS.select + 1] = "quest:" .. tostring(id) end,
        SelectActiveQuest    = function(id) CALLS.select[#CALLS.select + 1] = "quest:" .. tostring(id) end,
        GetOptions = function() CALLS.getOptions = CALLS.getOptions + 1; return W.options end,
        SelectOption = function(id) CALLS.select[#CALLS.select + 1] = id end,
        CloseGossip  = function() CALLS.close = CALLS.close + 1 end,
    }

    -- Option-list builders. IDs are deliberately NOT 1..n so an index/ID mixup
    -- in the engine shows up as a wrong value rather than an accidental pass.
    local function opts(...)
        local out = {}
        for i, name in ipairs({ ... }) do out[i] = { name = name, gossipOptionID = 100 + i } end
        return out
    end
    -- Every keyword the deleted pools carried, in one list.
    local function poisonList()
        return opts("Spare King Gordok", "Free the prisoner", "Enter Blackwing Lair",
                    "I want to browse your goods")
    end

    local GUID = {
        moldar   = "Creature-0-3299-0-14-14326-0000027FA1",
        fengus   = "Creature-0-3299-0-14-14321-0000027FA2",
        slipkik  = "Creature-0-3299-0-14-14323-0000027FA3",
        mizzle   = "Creature-0-3299-0-14-14353-0000027FA4",
        komcrush = "Creature-0-3299-0-14-14325-0000027FA5",
        orb      = "GameObject-0-3299-469-11-179879-0000027FA6",
        sayge    = "Creature-0-3299-0-14-14822-0000027FA7",
        innkeep  = "Creature-0-3299-0-14-6740-0000027FA8",   -- an unrelated NPC
        garbage  = "not-a-guid",
    }

    local fail = nil
    local function ck(cond, why) if not fail and not cond then fail = why end end
    local function scene(t)
        reset()
        W.guid, W.shift, W.options, W.onQuest = nil, false, {}, {}
        W.class, W.clock = "MAGE", 5000
        Auto._saygeDone, Auto._saygeAt, Auto._saygeSpam = false, nil, 0
        Auto._saygeShapeWarned, Auto._saygeInteractAt = false, nil
        for k, v in pairs(t or {}) do W[k] = v end
    end
    local function picked() return CALLS.select[1] end
    local function saidMatching(frag)
        for _, l in ipairs(said) do if l:lower():find(frag, 1, true) then return true end end
        return false
    end

    fs.autoGossip = { dmt = true, bwl = true,
                      dmf = { enabled = true, skipCookie = true,
                              buffType = { MAGE = "damage" } } }

    ------------------------------------------------------------------
    -- 1. DMT: the right NPC and the right option.
    ------------------------------------------------------------------
    for who, guid in pairs({ moldar = GUID.moldar, fengus = GUID.fengus,
                             slipkik = GUID.slipkik, mizzle = GUID.mizzle }) do
        scene({ guid = guid, options = opts("Moxie for me", "No thanks", "Goodbye") })
        Auto.OnGossipShow()
        ck(picked() == 101, who .. ": must select option 1 (id 101), selected " .. tostring(picked()))
        ck(#CALLS.select == 1, who .. ": exactly one selection")
    end

    ------------------------------------------------------------------
    -- 2. THE ADVERSARIAL FIXTURE. The audit's headline case: an unrelated NPC
    --    whose options carry every keyword the old pools matched. With BOTH
    --    boxes ticked, nothing may be touched.
    ------------------------------------------------------------------
    scene({ guid = GUID.innkeep, options = poisonList() })
    Auto.OnGossipShow()
    ck(#CALLS.select == 0,
       "wrong NPC with 'spare'/'free'/'enter' options: selected " .. tostring(picked()) .. ", must select nothing")
    ck(CALLS.close == 0, "wrong NPC: the gossip window must not be closed either")

    -- …and the same list at an NPC we cannot identify at all.
    scene({ guid = GUID.garbage, options = poisonList() })
    Auto.OnGossipShow()
    ck(#CALLS.select == 0, "unparseable GUID + poison options must select nothing")
    scene({ guid = nil, options = poisonList() })
    Auto.OnGossipShow()
    ck(#CALLS.select == 0, "no NPC GUID at all + poison options must select nothing")

    ------------------------------------------------------------------
    -- 3. KOMCRUSH. Two options (the shape that means a quest is on offer) is
    --    the case the guard exists for.
    ------------------------------------------------------------------
    scene({ guid = GUID.komcrush, options = opts("Spare Captain Komcrush") })
    Auto.OnGossipShow()
    ck(picked() == 101, "Komcrush with ONE option selects it, got " .. tostring(picked()))
    scene({ guid = GUID.komcrush, options = opts("Spare Captain Komcrush", "I need a job") })
    Auto.OnGossipShow()
    ck(#CALLS.select == 0, "Komcrush with TWO options must not eat the quest")

    ------------------------------------------------------------------
    -- 4. THE ORB. Single option, and not on 85556/85557/85558.
    ------------------------------------------------------------------
    scene({ guid = GUID.orb, options = opts("Enter Blackwing Lair") })
    Auto.OnGossipShow()
    ck(picked() == 101, "orb, one option, no blocking quest -> option 1")
    scene({ guid = GUID.orb, options = opts("Enter Blackwing Lair", "Something else") })
    Auto.OnGossipShow()
    ck(#CALLS.select == 0, "orb with two options must refuse")
    for _, q in ipairs({ 85556, 85557, 85558 }) do
        scene({ guid = GUID.orb, options = opts("Enter Blackwing Lair"), onQuest = { [q] = true } })
        Auto.OnGossipShow()
        ck(#CALLS.select == 0, "orb while on quest " .. q .. " must refuse")
    end
    -- A missing quest API cannot be read as "not on the quest".
    scene({ guid = GUID.orb, options = opts("Enter Blackwing Lair") })
    _G.C_QuestLog = nil
    Auto.OnGossipShow()
    ck(#CALLS.select == 0, "orb refuses when C_QuestLog.IsOnQuest is unavailable")
    _G.C_QuestLog = { IsOnQuest = function(q) return W.onQuest[q] == true end }

    ------------------------------------------------------------------
    -- 5. PER-TOGGLE. Each box only arms its own NPC set.
    ------------------------------------------------------------------
    fs.autoGossip.dmt = false
    scene({ guid = GUID.moldar, options = opts("Moxie", "No") })
    Auto.OnGossipShow()
    ck(#CALLS.select == 0, "DMT disabled: Mol'dar must be left alone")
    scene({ guid = GUID.orb, options = opts("Enter Blackwing Lair") })
    Auto.OnGossipShow()
    ck(picked() == 101, "DMT disabled does not disarm the orb")
    fs.autoGossip.dmt, fs.autoGossip.bwl = true, false
    scene({ guid = GUID.orb, options = opts("Enter Blackwing Lair") })
    Auto.OnGossipShow()
    ck(#CALLS.select == 0, "orb disabled: the orb must be left alone")
    fs.autoGossip.bwl = true

    ------------------------------------------------------------------
    -- 6. SAYGE, expected shapes, answered per the class config.
    ------------------------------------------------------------------
    fs.autoGossip.dmf.buffType = { MAGE = "intellect" }
    scene({ guid = GUID.sayge, options = opts("A", "B", "C", "D") })   -- page 1
    Auto.OnGossipShow()
    ck(picked() == 102, "sayge page 1, intellect -> option 2 (id 102), got " .. tostring(picked()))
    ck(Auto._saygeAt == nil, "page 1 does not arm the 5 s lock -- page 2 still needs answering")
    scene({ guid = GUID.sayge, options = opts("A", "B", "C") })        -- page 2
    Auto.OnGossipShow()
    ck(picked() == 102, "sayge page 2, intellect -> option 2 (id 102), got " .. tostring(picked()))
    ck(Auto._saygeAt == 5000, "page 2 IS the answer: the 5 s re-entry lock arms")
    -- The fortune-cookie page that follows is CLOSED, not answered.
    CALLS.select, CALLS.close = {}, 0
    W.options = opts("Take a fortune cookie")
    Auto.OnGossipShow()
    ck(#CALLS.select == 0 and CALLS.close == 1, "inside the lock the cookie page is closed, not answered")
    -- …and the lock is a TIME guard, not a session flag.
    W.clock = 5006
    ck(Auto.SaygeLocked() == false, "the re-entry lock expires after 5 s")

    -- A class with no stored value still answers: the class default is Damage.
    fs.autoGossip.dmf.buffType = {}
    scene({ guid = GUID.sayge, options = opts("A", "B", "C", "D") })
    Auto.OnGossipShow()
    ck(picked() == 101, "an unconfigured class takes the Damage path (option 1), got " .. tostring(picked()))
    ck(Auto._saygeSpam >= 0 and Auto._saygeDone == true, "the Damage fast path answers immediately")

    -- Damage explicitly configured -> the spam ladder, bounded and NPC-checked.
    fs.autoGossip.dmf.buffType = { MAGE = "damage" }
    scene({ guid = GUID.sayge, options = opts("A", "B", "C", "D") })
    Auto.OnGossipShow()
    ck(picked() == 101, "damage spams option 1")
    ck(Auto.SAYGE_SPAM_REPEATS == 100 and Auto.SAYGE_SPAM_INTERVAL == 0.05,
       "spec's spam shape is 100 repeats at 50 ms")
    -- The ladder refuses to click once the NPC is no longer Sayge.
    Auto._saygeSpam = 5
    W.guid = GUID.innkeep
    CALLS.select = {}
    Auto.SaygeSpamTick()
    ck(#CALLS.select == 0 and Auto._saygeSpam == 0,
       "the spam ladder stops dead when the NPC is no longer Sayge")

    ------------------------------------------------------------------
    -- 7. SAYGE, UNEXPECTED SHAPE -> refuse + a debug line the owner can act on.
    --    (Spec's page maps rest on an in-game premise the audit flags UNKNOWN.)
    ------------------------------------------------------------------
    fs.autoGossip.dmf.buffType = { MAGE = "armor" }
    scene({ guid = GUID.sayge, options = opts("A", "B", "C", "D", "E") })   -- 5 options
    Auto.OnGossipShow()
    ck(#CALLS.select == 0, "an unknown Sayge page shape must NOT be answered")
    ck(saidMatching("refused to answer"), "an unknown shape prints a line the owner can capture")
    ck(saidMatching("5-option"), "the printed line names the shape it saw")
    -- One line per visit, not one per GOSSIP_SHOW.
    local before = #said
    Auto.OnGossipShow()
    ck(#said == before, "the unknown-shape line does not repeat inside a visit")

    ------------------------------------------------------------------
    -- 8. SAYGE IS TIMESTAMPED REGARDLESS OF THE SETTING (spec §14).
    ------------------------------------------------------------------
    fs.autoGossip.dmf.enabled = false
    scene({ guid = GUID.sayge, options = opts("A", "B", "C", "D") })
    Auto.OnGossipShow()
    ck(Auto._saygeInteractAt == 5000, "Sayge interaction is stamped even with the setting off")
    ck(#CALLS.select == 0, "…but with the setting off nothing is selected")
    scene({ guid = GUID.innkeep, options = opts("A", "B", "C", "D") })
    Auto.OnGossipShow()
    ck(Auto._saygeInteractAt == nil, "a non-Sayge NPC does not stamp a Sayge interaction")
    fs.autoGossip.dmf.enabled = true

    ------------------------------------------------------------------
    -- 9. SHIFT. §19.23's escape hatch covers every one of these NPCs, and it
    --    means ZERO gossip API touches — not "selects nothing".
    ------------------------------------------------------------------
    for _, guid in ipairs({ GUID.moldar, GUID.komcrush, GUID.orb, GUID.sayge }) do
        scene({ guid = guid, shift = true, options = opts("A") })
        Auto.OnGossipShow()
        ck(#CALLS.select == 0 and CALLS.close == 0 and CALLS.getOptions == 0,
           "held Shift at " .. guid:match("%-(%d+)%-[^%-]*$") .. ": the gossip API must not be touched")
        ck(Auto._saygeInteractAt == nil, "held Shift stamps nothing either")
    end

    ------------------------------------------------------------------
    -- 10. THE POOLS ARE GONE, not merely unused. A keyword matcher left in the
    --     file is a keyword matcher waiting to be re-wired.
    ------------------------------------------------------------------
    ck(Auto.FindOptionByKeywords == nil,
       "the gossip-option keyword matcher must not exist any more")

    -- Restore.
    fs.autoGossip = savedAGO
    Auto._saygeDone, Auto._saygeAt, Auto._saygeSpam = savedSayge[1], savedSayge[2], 0
    Auto._saygeShapeWarned, Auto._saygeInteractAt = savedSayge[4], savedSayge[5]
    for _, k in ipairs(NAMES) do _G[k] = SAVE[k] end

    if fail then return false, fail end
    return true
end

----------------------------------------------------------------------
-- AUTO-REPAIR HONESTY (owner waiver 2026-08-05).
--
-- The waived behaviour — repairing at ANY vendor window the player opens — is
-- asserted here as INTENDED, deliberately and explicitly, so the next audit
-- reads this assertion as the owner's decision and not as a test that codified
-- a divergence by accident. What the waiver did not cover is honesty, and the
-- other three rows are that: the cost is printed, an unaffordable repair says
-- so instead of failing silently, and (in the options suite) the label no
-- longer names an NPC it does not confine itself to.
----------------------------------------------------------------------
local function testRepairHonesty()
    local SAVE = {}
    local NAMES = { "CanMerchantRepair", "GetRepairAllCost", "RepairAllItems",
                    "GetMoney", "GetCoinTextureString", "print" }
    for _, k in ipairs(NAMES) do SAVE[k] = _G[k] end

    local aq = Auto.AQBlock and Auto.AQBlock() or nil
    if type(aq) ~= "table" then return false, "the live autoQuest block is reachable" end
    local savedRepair = aq.autoRepair

    local W = { canRepair = true, cost = 12345, money = 999999 }
    local said, repaired
    _G.print = function(...)
        local p = {}
        for i = 1, select("#", ...) do p[i] = tostring((select(i, ...))) end
        said[#said + 1] = table.concat(p, "\t")
    end
    _G.CanMerchantRepair    = function() return W.canRepair end
    _G.GetRepairAllCost     = function() return W.cost end
    _G.GetMoney             = function() return W.money end
    _G.RepairAllItems       = function() repaired = repaired + 1 end
    _G.GetCoinTextureString = nil          -- exercise the plain-text fallback
    local function run(t)
        for k, v in pairs(t or {}) do W[k] = v end
        said, repaired = {}, 0
        Auto.OnMerchantShow()
    end
    local function saidMatching(frag)
        for _, l in ipairs(said) do if l:lower():find(frag, 1, true) then return true end end
        return false
    end

    local fail = nil
    local function ck(cond, why) if not fail and not cond then fail = why end end

    aq.autoRepair = true

    -- OWNER-WAIVED BEHAVIOUR, ASSERTED AS INTENDED: this fires on a merchant
    -- window the PLAYER opened, at an arbitrary vendor, with no NPC gate and no
    -- armed flag. Spec §19.21 says otherwise; Drew approved this on 2026-08-05.
    run({})
    ck(repaired == 1, "auto-repair fires at an arbitrary vendor (owner-waived, INTENDED)")
    ck(saidMatching("1g 23s 45c"), "the repair cost is printed, got: " .. tostring(said[1]))

    -- Not enough gold: a plain line, not silence.
    run({ money = 100 })
    ck(repaired == 0, "an unaffordable repair does not repair")
    ck(saidMatching("not enough gold"), "an unaffordable repair prints a plain line")
    ck(saidMatching("1g 23s 45c"), "…naming the cost it could not pay")

    -- Exactly affordable is affordable.
    run({ money = 12345 })
    ck(repaired == 1, "exactly enough gold repairs")

    -- Nothing damaged: silent, as before.
    run({ money = 999999, cost = 0 })
    ck(repaired == 0 and #said == 0, "a zero-cost repair is silent")

    -- The vendor cannot repair at all.
    run({ cost = 12345, canRepair = false })
    ck(repaired == 0 and #said == 0, "a non-repair vendor is silent")

    -- The toggle is the only gate there is.
    aq.autoRepair = false
    run({})
    ck(repaired == 0 and #said == 0, "the toggle off means nothing happens")

    -- Money formatting is exact at the boundaries.
    ck(Auto.FormatMoney(0) == "0g 0s 0c", "0 copper formats")
    ck(Auto.FormatMoney(99) == "0g 0s 99c", "sub-silver formats")
    ck(Auto.FormatMoney(10000) == "1g 0s 0c", "one gold formats")

    aq.autoRepair = savedRepair
    for _, k in ipairs(NAMES) do _G[k] = SAVE[k] end
    if fail then return false, fail end
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

-- RULE (owner bug 1.1.4): the reader tolerates the legacy MAP and HYBRID shapes,
-- and an explicitly unticked flask is never enabled in ANY of them. "All three"
-- is reserved for a table that has recorded no preference at all.
local function testZanzaShapeTolerance()
    local function arr(t) return table.concat(t, ",") end

    -- The owner's two SavedVariables blocks, verbatim.
    local hordeMap = { ["sheen"] = false, ["spirit"] = true, ["swiftness"] = true }
    local allianceHybrid = { "swiftness", "spirit",
                             ["sheen"] = true, ["spirit"] = true, ["swiftness"] = true }

    -- WHY the bug existed: the array part of a map-shaped table is empty, which
    -- the pre-1.1.4 reader took as "all three".
    if #hordeMap ~= 0 then return false, "the owner's map block has no array part (premise)" end

    local ROWS = {
        { "owner HORDE map (sheen=false)", hordeMap,                "swiftness,spirit" },
        { "owner ALLIANCE hybrid",         allianceHybrid,          "swiftness,spirit" },
        { "fresh empty",                   {},                      "swiftness,spirit,sheen" },
        { "canonical array",               { "swiftness", "sheen" },"swiftness,sheen" },
        { "map, all true",                 { swiftness = true, spirit = true, sheen = true },
                                                                    "swiftness,spirit,sheen" },
        { "map, all false",                { swiftness = false, spirit = false, sheen = false }, "" },
        { "map, one opt-out only",         { sheen = false },       "swiftness,spirit" },
        { "false beats an array entry",    { "sheen", ["sheen"] = false }, "" },
        { "stray true never resurrects",   { "spirit", ["sheen"] = true }, "spirit" },
        { "case-insensitive array",        { "Sheen" },             "sheen" },
    }
    for _, row in ipairs(ROWS) do
        local got = arr(Auto.ZanzaEnabledPicks(row[2]))
        if got ~= row[3] then
            return false, ("%s -> {%s}, want {%s}"):format(row[1], got, row[3])
        end
    end
    if arr(Auto.ZanzaEnabledPicks(nil)) ~= "swiftness,spirit,sheen" then
        return false, "a missing priority table still means all three"
    end

    -- READ-THROUGH EQUIVALENCE: what the engine dispenses must not change when
    -- the store's one-shot rewrite lands. For every shape, reading the RAW table
    -- and reading the MIGRATED table have to give the same answer.
    --
    -- The one shape where the stored array cannot say it on its own is
    -- "everything is off": `{}` reads as all three, so the migration flags
    -- allOff and Store.MigrateZanzaPriorityShape switches the parent toggle off
    -- instead of storing a lie. Those rows are asserted that way instead.
    if ns.Store and ns.Store.NormalizeZanzaPriority then
        for _, row in ipairs(ROWS) do
            local normalized, _, allOff = ns.Store.NormalizeZanzaPriority(row[2])
            if row[3] == "" then
                if not allOff then
                    return false, row[1] .. ": an empty result must flag the parent off"
                end
            else
                if allOff then return false, row[1] .. ": allOff flagged with picks surviving" end
                local after = arr(Auto.ZanzaEnabledPicks(normalized))
                if after ~= row[3] then
                    return false, ("%s: reads {%s} before the migration and {%s} after")
                        :format(row[1], row[3], after)
                end
            end
        end
    end
    return true
end

-- RULE (owner bug 1.1.4, end to end): with the owner's stored shape and all
-- three flasks on the reward board, Sheen is NEVER requested — not through the
-- zanza machinery, and not through the generic reward picker either.
local function testZanzaSheenNeverRequested()
    local block = Auto.AQBlock and Auto.AQBlock() or nil
    if type(block) ~= "table" or type(block.zanza) ~= "table" then
        return false, "the live autoQuest.zanza block is reachable"
    end

    local SHEEN, SWIFT, SPIRIT = 20080, 20081, 20079
    local choices = {
        { index = 1, itemID = SHEEN,  name = "Sheen of Zanza",     key = "sheen"     },
        { index = 2, itemID = SWIFT,  name = "Swiftness of Zanza", key = "swiftness" },
        { index = 3, itemID = SPIRIT, name = "Spirit of Zanza",    key = "spirit"    },
    }

    -- Save every piece of live state this test drives.
    local savedPri, savedEnabled = block.zanza.priority, block.zanza.enabled
    local savedChoices, savedWatch = Auto._zanzaChoices, Auto._zanzaWatch
    local savedPending, savedCd    = Auto._zanzaPending, Auto._zanzaCooldown
    local savedOwned, savedGQR     = Auto.OwnedCount, _G.GetQuestReward

    local requested = {}
    _G.GetQuestReward = function(i) requested[#requested + 1] = i end

    local ownedIDs = {}
    Auto.OwnedCount = function(id) return ownedIDs[id] or 0 end

    local function attempt(owned)
        ownedIDs = owned
        requested = {}
        Auto._zanzaChoices  = choices
        Auto._zanzaWatch    = false
        Auto._zanzaPending  = nil
        Auto._zanzaCooldown = {}
        local ok, key = Auto.ZanzaPickAndRequest()
        return ok, key, requested
    end

    -- The owner's exact stored shape.
    block.zanza.enabled  = true
    block.zanza.priority = { ["sheen"] = false, ["spirit"] = true, ["swiftness"] = true }

    local fail = nil

    -- 1. Both enabled flasks already in the bags — the live symptom. The old
    --    reader said "all three", found Sheen unowned, and took it.
    local _, reason, req = attempt({ [SWIFT] = 1, [SPIRIT] = 1 })
    if req[1] ~= nil then fail = "Sheen was requested when both enabled flasks were owned" end
    if not fail and reason ~= "all-owned" then
        fail = "expected all-owned (dialog left open), got " .. tostring(reason)
    end

    -- 2. Nothing owned: it must take Swiftness first, and still never Sheen.
    if not fail then
        local ok2, key2, req2 = attempt({})
        if not (ok2 and key2 == "swiftness" and req2[1] == 2 and #req2 == 1) then
            fail = "an empty bag takes Swiftness (index 2), got " .. tostring(key2)
        end
    end

    -- 3. Swiftness owned: walk to Spirit, never to Sheen.
    if not fail then
        local ok3, key3, req3 = attempt({ [SWIFT] = 1 })
        if not (ok3 and key3 == "spirit" and req3[1] == 3 and #req3 == 1) then
            fail = "with Swiftness owned it takes Spirit (index 3), got " .. tostring(key3)
        end
    end

    -- 4. The generic reward picker (the other call site) with the same shape.
    if not fail then
        local named = { { index = 1, name = "Sheen of Zanza" },
                        { index = 2, name = "Swiftness of Zanza" },
                        { index = 3, name = "Spirit of Zanza" } }
        local picked = Auto.PickReward(named, Auto.ZanzaEnabledPicks(block.zanza.priority))
        if picked ~= 2 then
            fail = "PickReward on the map shape must choose Swiftness, got " .. tostring(picked)
        end
    end

    -- 5. Post-migration the very same block behaves identically.
    if not fail and ns.Store and ns.Store.NormalizeZanzaPriority then
        block.zanza.priority = (ns.Store.NormalizeZanzaPriority(block.zanza.priority))
        local _, reason5, req5 = attempt({ [SWIFT] = 1, [SPIRIT] = 1 })
        if req5[1] ~= nil or reason5 ~= "all-owned" then
            fail = "the migrated array shape must behave exactly like the raw map"
        end
    end

    block.zanza.priority, block.zanza.enabled = savedPri, savedEnabled
    Auto._zanzaChoices, Auto._zanzaWatch      = savedChoices, savedWatch
    Auto._zanzaPending, Auto._zanzaCooldown   = savedPending, savedCd
    Auto.OwnedCount,    _G.GetQuestReward     = savedOwned, savedGQR

    if fail then return false, fail end
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
        { name = "summon: §13 fresh-buff rules (75s / boon / unboon)",
                                        fn = testFreshBuffRules },
        { name = "summon: freshness -> gate, and accept clears it",
                                        fn = testSummonFreshnessGate },
        { name = "summon: trigger catalog (FFF identity, boonable set)",
                                        fn = testTriggerCatalog },
        { name = "invite: §12.1 target set + alphabetical sort", fn = testInviteTargets },
        { name = "invite: §12.1 pacing (60ms, 700ms 5th)",       fn = testInvitePacing },
        { name = "invite: failure parse + reverse-invite outcome", fn = testInviteFailureParse },
        { name = "invite: live run on the injected scheduler",   fn = testInviteRunLive },
        { name = "whisper: can-invite + live leader redirect",   fn = testWhisperRedirect },
        { name = "keyword matcher",     fn = testKeywordMatcher },
        { name = "roster membership",   fn = testRosterMembership },
        { name = "gossip: DMT npc gate + komcrush guard", fn = testDmtGate },
        { name = "gossip: BWL orb gate",  fn = testBwlGate },
        { name = "gossip: sayge page maps + shape guard", fn = testSaygePageMaps },
        { name = "gossip: npc-gated live path (adversarial)", fn = testGossipLivePath },
        { name = "auto-repair honesty",  fn = testRepairHonesty },
        { name = "quest title + reward", fn = testTitleAndReward },
        { name = "keyword pools disjoint", fn = testKeywordPools },
        { name = "forbidden quests",    fn = testForbiddenQuests },
        { name = "gossip plan order",   fn = testGossipPlanOrder },
        { name = "zanza priority",      fn = testZanzaPriority },
        { name = "zanza pick-list shape tolerance", fn = testZanzaShapeTolerance },
        { name = "zanza: sheen never requested (owner shape, end to end)",
                                        fn = testZanzaSheenNeverRequested },
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

-- /dsn debug gossip -> narrate the NPC-gated gossip handlers.
--
-- This exists for one purpose above all others: spec §14's Sayge page maps rest
-- on the premise that Damage is option 1 on BOTH pages, and the conformance
-- audit flags that premise UNKNOWN-NEEDS-INGAME-VERIFY. When Sayge presents a
-- page shape the maps do not describe, Auto.SaygeShapeWarn refuses out loud and
-- this channel prints the option list so the owner can capture the real thing.
if ns.RegisterDebugCommand then
    ns:RegisterDebugCommand("gossip", function()
        Auto.DEBUG_GOSSIP = not Auto.DEBUG_GOSSIP
        ns:Print("gossip debug " .. (Auto.DEBUG_GOSSIP and "ON" or "OFF")
            .. " -- DMT/Orb/Sayge gates narrate their refusals.")
        if Auto.DEBUG_GOSSIP then
            ns:Print(("  sayge: last interaction %s ; re-entry lock %s")
                :format(Auto._saygeInteractAt and (string.format("%.1fs ago",
                        nowSecs() - Auto._saygeInteractAt)) or "never this session",
                    Auto.SaygeLocked() and "ACTIVE" or "clear"))
        end
    end)
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
