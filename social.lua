--[[
    Daseeki Nexus — social.lua

    THE GUILD AND FRIENDS TRUST SETS  (behaviour spec §12.2 gates 3 and 4,
    §12.3's keyword-invite twins).

    §12.2 checks an incoming invite in order: whitelist, then "sender matches a
    character in the local database", then "sender is a GUILD MEMBER", then
    "sender is a FRIEND or Battle.net friend", then "anyone". Gates 3 and 4 read
    Store.data.social.guild / .friends. Until this file existed, NOTHING wrote
    those two tables: both gates ship default-on and could never admit a single
    person, so a guildmate's or a friend's invite was silently ignored with the
    box ticked and no way for the owner to tell. This module is the writer.

    ── WHAT IS CAPTURED ─────────────────────────────────────────────────────────
      guild    every name the guild roster reports.
      friends  every name on the character friends list, PLUS every Battle.net
               friend's current WoW character (§12.2 says "friend or Battle.net
               friend" — one category, one toggle, so one set).

    Keys are Auto.SocialKey — the canonical social key, which is friends.lua's
    Friends.Key spelling (lowered base name, folded realm). The gate keys the
    incoming sender with the SAME function, so a match is a match whatever case
    the server used and whether or not the name arrived realm-suffixed.

    ── THE ONE RULE THAT MATTERS: NEVER WRITE A DARK READ ───────────────────────
    Both lists are SERVER-SIDE and both answer "nothing" for the first seconds
    after login — not "you have no guild and no friends" but "the client has not
    been told yet". friends.lua learned this first and refuses to diff a list it
    has not confirmed; this module takes the same doctrine one step further,
    because its output is a TRUST GRANT:

        a read that is not confirmed writes NOTHING AT ALL, and the gate keeps
        consulting the previous (persisted) snapshot.

    Confirmation, per source:
      friends  friends.lua has asked (C_FriendList.ShowFriends) and a
               FRIENDLIST_UPDATE has come back — it announces that on the bus as
               FRIENDS_LIST_CONFIRMED. We never keep a second copy of that state.
      guild    NOT in a guild (IsInGuild false) is itself a confirmed answer, and
               the truthful snapshot is the empty set. In a guild with a roster
               that reads zero usable names is DARK: write nothing, ask again.
      BNet     BNConnected() is the gate. Battle.net being down or absent removes
               only the BNet contribution; the character list still writes.

    There is no "give up and write it anyway after N seconds" backstop, by
    design. Doing nothing keeps yesterday's snapshot, which is recoverable; a
    wrong write silently revokes trust from every guildmate at once.

    ── FRESHNESS ────────────────────────────────────────────────────────────────
    The spec sets no polling cadence for either set, so there is none. Snapshots
    are event-driven only:
      * login — one bounded request ladder each (guild 2/10/30 s, friends is
        friends.lua's 5/15/30 s ladder), stopping as soon as it is answered.
      * GUILD_ROSTER_UPDATE — rebuild. Never re-request from inside the handler:
        that is the loop trap, since a request fires the event.
      * PLAYER_GUILD_UPDATE — membership itself changed. A snapshot labelled with
        a guild we are no longer in is not truthful, so leaving (or moving) drops
        the set immediately rather than trusting the old roster until the new one
        lands.
      * FRIENDLIST_UPDATE (only once confirmed) and BN_FRIEND_INFO_CHANGED
        (debounced) — rebuild.
    Every write is diff-gated in Store.SetSocialSet, so the update storms those
    events produce cost one table walk and touch SavedVariables only on a real
    change.

    ── PURE / IMPURE SPLIT ──────────────────────────────────────────────────────
    Everything above the RUNTIME section is pure and takes its world injected;
    the runtime section is the only place a WoW API is touched.

    API surface, verified against wow-api-catalog 1.15.9.68808:
        IsInGuild() -> bool                         (functions.txt + globals.txt)
        C_GuildInfo.GuildRoster()                   (functions.txt + globals.txt)
        GetNumGuildMembers / GetGuildRosterInfo / GetGuildInfo
                                                    (globals.txt — EXISTENCE only,
            no signature is recorded, so the roster walk reads return value 1 as
            the name, type-checks it, and skips anything else.)
        C_FriendList.GetNumFriends / .GetFriendInfoByIndex — reached through
            friends.lua's Friends.FriendSet(), which already owns that walk.
        BNConnected / BNGetNumFriends               (globals.txt)
        C_BattleNet.GetFriendNumGameAccounts / .GetFriendGameAccountInfo
                                                    (functions.txt)
    The catalog records no STRUCTURE fields, so every field read off a BNet game
    account (clientProgram / characterName / realmName) is type-guarded and the
    whole BNet contribution fails CLOSED: an unrecognised shape grants nothing.

    EVENTS (events.txt 1.15.9.68808): Event.GuildInfo.GuildRosterUpdate,
    Event.GuildInfo.PlayerGuildUpdate, Event.FriendList.FriendlistUpdate,
    Event.FriendList.BnFriendInfoChanged.
--]]

local ADDON, ns = ...

local Social = {}
ns.Social = Social

local Store = ns.Store

-- Headless discipline: bounded walks, whatever the server says.
Social.MAX_GUILD  = 800     -- Store.SOCIAL_MAX is the storage-side twin
Social.MAX_BNET   = 200

-- ════════════════════════════════════════════════════════════════════════════
--  PURE LOGIC  (selftest targets — no WoW API below this line until RUNTIME)
-- ════════════════════════════════════════════════════════════════════════════

-- The canonical key, borrowed from the gates that read it. auto.lua owns
-- Auto.SocialKey precisely so the writer cannot drift from the reader.
function Social.Key(name, defaultRealm)
    local Auto = ns.Auto
    if not (Auto and Auto.SocialKey) then return nil end
    return Auto.SocialKey(name, defaultRealm)
end

-- Fold an array of raw names ("Bob", "Bob-Nek'Rosh", " bob ") into a canonical
-- social set. Returns set, count. Bounded; junk entries are skipped, never
-- guessed at.
function Social.SetFromNames(names, defaultRealm, cap)
    local set, n = {}, 0
    cap = cap or Social.MAX_GUILD
    if type(names) ~= "table" then return set, 0 end
    for i = 1, #names do
        if n >= cap then break end
        local raw = names[i]
        if type(raw) == "string" and raw ~= "" then
            local key = Social.Key(raw, defaultRealm)
            if key and not set[key] then
                set[key] = true
                n = n + 1
            end
        end
    end
    return set, n
end

----------------------------------------------------------------------
-- THE GUILD VERDICT  (pure)
--
-- ctx = { inGuild = bool, names = { "Name", ... }, guildName = "...",
--         realm = "<my realm>" }
-- Returns action, set, label:
--   "write"  a CONFIRMED snapshot. Empty + label "" when we are in no guild —
--            that is a real answer, not an absence of one.
--   "dark"   in a guild whose roster has told us nothing usable. Write nothing;
--            the previous snapshot stands and the next event tries again.
----------------------------------------------------------------------
function Social.JudgeGuild(ctx)
    ctx = ctx or {}
    if not ctx.inGuild then return "write", {}, "" end

    local set, n = Social.SetFromNames(ctx.names, ctx.realm, Social.MAX_GUILD)
    if n == 0 then return "dark", nil, nil end
    return "write", set, tostring(ctx.guildName or "")
end

----------------------------------------------------------------------
-- THE FRIENDS VERDICT  (pure)
--
-- ctx = { listConfirmed = bool, names = {...}, bnetNames = {...},
--         realm = "<my realm>" }
-- Returns action, set:
--   "write"  the character list has been confirmed. An EMPTY confirmed list is
--            a real answer ("you have no friends"), so it is written.
--   "dark"   nothing has answered us. Write nothing.
--
-- The BNet half is additive and never blocks: a BNet friend's character is only
-- knowable while they are online, which is exactly when they could be inviting
-- us, so its coming and going is truth, not loss.
----------------------------------------------------------------------
function Social.JudgeFriends(ctx)
    ctx = ctx or {}
    if not ctx.listConfirmed then return "dark", nil end

    local set, n = Social.SetFromNames(ctx.names, ctx.realm, Store.SOCIAL_MAX or 800)
    for _, raw in ipairs(ctx.bnetNames or {}) do
        if n >= (Store.SOCIAL_MAX or 800) then break end
        local key = Social.Key(raw, ctx.realm)
        if key and not set[key] then
            set[key] = true
            n = n + 1
        end
    end
    return "write", set
end

-- ════════════════════════════════════════════════════════════════════════════
--  RUNTIME  (in-game only)
-- ════════════════════════════════════════════════════════════════════════════

Social._guildRequested = false
Social._guildCaptured  = false   -- a CONFIRMED guild read has landed this session
Social._bnPending      = false

local function serverNow()
    return (_G.GetServerTime and GetServerTime()) or (_G.time and time()) or 0
end

local function myRealm()
    local realm = _G.GetNormalizedRealmName and GetNormalizedRealmName()
    if not realm or realm == "" then
        realm = (_G.GetRealmName and GetRealmName()) or ""
    end
    return realm
end

----------------------------------------------------------------------
-- GUILD
----------------------------------------------------------------------

-- Ask the server for the roster. Blizzard throttles this to roughly one call
-- per 10 s and answers with GUILD_ROSTER_UPDATE; extra calls are dropped, not
-- queued, so the bounded ladder below is the whole of our asking.
function Social.RequestGuildRoster()
    if not (_G.IsInGuild and IsInGuild()) then return end
    Social._guildRequested = true
    if _G.C_GuildInfo and C_GuildInfo.GuildRoster then
        pcall(C_GuildInfo.GuildRoster)
    elseif _G.GuildRoster then
        pcall(_G.GuildRoster)
    end
end

-- Walk the roster into an array of raw names.
--
-- GetGuildRosterInfo carries no signature in the catalog (globals.txt records
-- existence only), so return value 1 is taken as the name and type-checked.
-- The walk is also deliberately tolerant of index holes: GetNumGuildMembers
-- counts the whole guild while the roster enumerates only what the client's
-- show-offline setting exposes, so trailing indices can answer nil. That is
-- normal, not an error — we never touch SetGuildRosterShowOffline, because it
-- is the player's own UI state and an invite comes from someone online anyway.
function Social.ReadGuildNames()
    if not (_G.GetNumGuildMembers and _G.GetGuildRosterInfo) then return nil end
    local okN, total = pcall(_G.GetNumGuildMembers)
    total = okN and tonumber(total) or 0
    if total <= 0 then return {} end
    local out = {}
    for i = 1, math.min(total, Social.MAX_GUILD) do
        local ok, nm = pcall(_G.GetGuildRosterInfo, i)
        if ok and type(nm) == "string" and nm ~= "" then
            out[#out + 1] = nm
        end
    end
    return out
end

function Social.GuildContext()
    local name = nil
    if _G.GetGuildInfo then
        local ok, gname = pcall(_G.GetGuildInfo, "player")
        if ok and type(gname) == "string" then name = gname end
    end
    return {
        inGuild   = (_G.IsInGuild and IsInGuild()) and true or false,
        names     = Social.ReadGuildNames(),
        guildName = name,
        realm     = myRealm(),
    }
end

-- Returns action, changed, count — narrated by /dsn debug social, asserted by
-- the suite through the real store writer.
function Social.CaptureGuild()
    local ctx = Social.GuildContext()
    local action, set, label = Social.JudgeGuild(ctx)
    if action ~= "write" then return "dark", false, 0 end
    local changed, n = Store.SetSocialSet("guild", set, serverNow(), label)
    Social._guildCaptured = true      -- this session's login ladder can stop
    return "write", changed, n
end

----------------------------------------------------------------------
-- FRIENDS
----------------------------------------------------------------------

-- The character friends list, through friends.lua's own walk. That module owns
-- the C_FriendList enumeration and the confirmed-list doctrine; duplicating
-- either here is how two readers drift apart. FriendSet returns keys that are
-- already lowered base names — Classic Era character friends are same-realm by
-- construction, so our realm is the right suffix for every one of them.
function Social.ReadFriendNames()
    local F = ns.MeshFriends
    if not (F and F.FriendSet) then return nil end
    local set = F.FriendSet()
    if not set then return nil end          -- API absent: a dark read, not "none"
    local out = {}
    for base in pairs(set) do
        if type(base) == "string" and base ~= "" then out[#out + 1] = base end
    end
    table.sort(out)                          -- deterministic order for the cap
    return out
end

-- Battle.net friends' current WoW characters (§12.2 gate 4 names them
-- explicitly). Fails CLOSED on every uncertainty: no Battle.net connection, a
-- missing API, an unfamiliar record shape or a non-WoW game account all
-- contribute nothing rather than a guess.
function Social.ReadBNetNames()
    local out = {}
    if not (_G.BNConnected and _G.BNGetNumFriends) then return out end
    local okC, connected = pcall(_G.BNConnected)
    if not (okC and connected) then return out end

    local C = _G.C_BattleNet
    if not (C and C.GetFriendNumGameAccounts and C.GetFriendGameAccountInfo) then
        return out
    end

    local okN, total = pcall(_G.BNGetNumFriends)
    total = okN and tonumber(total) or 0
    local wow = _G.BNET_CLIENT_WOW or "WoW"

    for i = 1, math.min(total, Social.MAX_BNET) do
        local okG, num = pcall(C.GetFriendNumGameAccounts, i)
        num = okG and tonumber(num) or 0
        for j = 1, num do
            local okA, ga = pcall(C.GetFriendGameAccountInfo, i, j)
            if okA and type(ga) == "table"
               and ga.clientProgram == wow
               and type(ga.characterName) == "string" and ga.characterName ~= "" then
                local realm = type(ga.realmName) == "string" and ga.realmName ~= ""
                              and ga.realmName or myRealm()
                out[#out + 1] = ga.characterName .. "-" .. realm
            end
        end
    end
    return out
end

function Social.FriendsContext()
    local F = ns.MeshFriends
    local names = Social.ReadFriendNames()
    return {
        -- Confirmed means BOTH: friends.lua saw an answer from the server, and
        -- the list actually read back. Either one missing is dark.
        listConfirmed = (F and F.ListConfirmed and F.ListConfirmed()) and names ~= nil,
        names         = names,
        bnetNames     = Social.ReadBNetNames(),
        realm         = myRealm(),
    }
end

function Social.CaptureFriends()
    local ctx = Social.FriendsContext()
    local action, set = Social.JudgeFriends(ctx)
    if action ~= "write" then return "dark", false, 0 end
    local changed, n = Store.SetSocialSet("friends", set, serverNow())
    return "write", changed, n
end

----------------------------------------------------------------------
-- TRIGGERS
----------------------------------------------------------------------

local GUILD_REQUEST_AT = { 2, 10, 30 }   -- seconds after login; bounded, then stop

-- Session-scoped, deliberately: social.guildAt persists, so it would tell us
-- "already confirmed" about LAST login and silence the whole ladder.

-- NOT ON THE LOGIN FRAME ITSELF, deliberately. "Not in a guild" is a confirmed
-- answer here and writes the empty set — which is right when you left a guild,
-- and wrong if IsInGuild() has simply not been populated yet on the very first
-- frame. Waiting for the first rung costs two seconds and removes the only path
-- by which this module could revoke a whole roster's trust on a bad read.
ns:On("LOGIN", function()
    Social._guildRequested = false
    Social._guildCaptured  = false
    for _, at in ipairs(GUILD_REQUEST_AT) do
        if _G.C_Timer and C_Timer.After then
            C_Timer.After(at, function()
                if Social._guildCaptured then return end
                ns:SafeCall(Social.RequestGuildRoster)
                ns:SafeCall(Social.CaptureGuild)
            end)
        end
    end
end)

-- The answer. NEVER re-request from in here: a request fires this event.
ns:RegisterEvent("GUILD_ROSTER_UPDATE", function()
    ns:SafeCall(Social.CaptureGuild)
end)

-- Membership itself changed (joined, left, or was kicked). A set labelled with a
-- guild we are no longer in must not keep granting trust for one more second, so
-- the leave case writes the empty set immediately (JudgeGuild's confirmed "not
-- in a guild" answer) and the join case asks for the new roster.
ns:RegisterEvent("PLAYER_GUILD_UPDATE", function(_, unit)
    if unit and unit ~= "player" then return end
    Social._guildRequested = false
    ns:SafeCall(Social.CaptureGuild)
    ns:SafeCall(Social.RequestGuildRoster)
end)

-- friends.lua announces the moment its list stops being dark.
ns:On("FRIENDS_LIST_CONFIRMED", function()
    ns:SafeCall(Social.CaptureFriends)
end)

-- Every later update keeps the set current (a friend added or removed fires
-- this). CaptureFriends is itself refusal-gated, so an update that arrives
-- before confirmation writes nothing.
ns:RegisterEvent("FRIENDLIST_UPDATE", function()
    ns:SafeCall(Social.CaptureFriends)
end)

-- Battle.net churn is noisier and cheaper to coalesce: one rebuild per 2 s.
ns:RegisterEvent("BN_FRIEND_INFO_CHANGED", function()
    if Social._bnPending then return end
    Social._bnPending = true
    if _G.C_Timer and C_Timer.After then
        C_Timer.After(2, function()
            Social._bnPending = false
            ns:SafeCall(Social.CaptureFriends)
        end)
    else
        Social._bnPending = false
        ns:SafeCall(Social.CaptureFriends)
    end
end)

----------------------------------------------------------------------
-- Diagnostics — /dsn debug social [name]
--
-- The gates used to fail invisibly; this is how the owner sees them working.
-- With a name it answers the exact question the gate asks, through the gate's
-- own functions.
----------------------------------------------------------------------
ns:RegisterDebugCommand("social", function(args)
    local social = Store.GetSocial() or {}
    local function count(t)
        local n = 0
        for _ in pairs(type(t) == "table" and t or {}) do n = n + 1 end
        return n
    end
    local function ago(at)
        at = tonumber(at) or 0
        if at <= 0 then return "never captured" end
        return ("%ds ago"):format(math.max(0, serverNow() - at))
    end

    ns:Print(("guild set: %d name(s), %s%s"):format(count(social.guild), ago(social.guildAt),
        (social.guildName and social.guildName ~= "") and (" — <" .. social.guildName .. ">") or ""))
    ns:Print(("friends set: %d name(s), %s"):format(count(social.friends), ago(social.friendsAt)))

    local F = ns.MeshFriends
    ns:Print("  friends list: " .. ((F and F.ListConfirmed and F.ListConfirmed())
        and "confirmed" or "NOT confirmed (dark — nothing will be written)"))
    ns:Print("  in a guild: " .. ((_G.IsInGuild and IsInGuild()) and "yes" or "no"))
    ns:Print("  battle.net: " .. ((_G.BNConnected and BNConnected()) and "connected" or "absent/offline"))

    local name = (args or ""):match("^%s*(.-)%s*$")
    if name ~= "" then
        local Auto = ns.Auto
        local nr  = Auto.NormalizeName(name)
        local key = Auto.SocialKey(nr)
        ns:Print(("  %s -> key %s : guild=%s friends=%s"):format(nr, tostring(key),
            tostring(Auto.IsGuild(nr)), tostring(Auto.IsFriend(nr))))
        local accept, cat = Auto.ShouldAcceptInvite(nr)
        ns:Print(("  invite from them would be %s%s"):format(accept and "ACCEPTED" or "ignored",
            cat and (" (" .. cat .. ")") or ""))
    end
end)

-- ════════════════════════════════════════════════════════════════════════════
--  SELFTEST  (rule per rule — the trust assertions drive the REAL gate
--  functions, Auto.ShouldAcceptInvite / Auto.ShouldInviteKeyword, against the
--  REAL store writer. Nothing here restates the logic it is testing.)
-- ════════════════════════════════════════════════════════════════════════════

ns:RegisterSelfTest("social", function(verbose)
    local pass = true
    local function ck(cond, msg)
        if not cond then
            pass = false
            if verbose then ns:Print("  FAIL social/" .. msg) end
        end
    end

    local Auto = ns.Auto
    local data = Store.GetData()
    if not (Auto and type(data) == "table") then
        if verbose then ns:Print("  FAIL social/store or auto module missing") end
        return false
    end

    -- Save and restore everything this suite touches.
    local savedSocial = data.social
    local ag = Auto.FactionSettings().autoGroup
    local savedAG = {}
    for k, v in pairs(ag) do savedAG[k] = v end

    local function resetStore()
        data.social = { guild = {}, friends = {}, guildName = "", guildAt = 0, friendsAt = 0 }
    end
    local function onlyGate(which)
        ag.whitelist        = nil
        ag.whitelistEnabled = false
        ag.acceptFromAnyone, ag.acceptFromRoster = false, false
        ag.acceptFromGuild   = (which == "guild")
        ag.acceptFromFriends = (which == "friends")
        ag.sendToAnyone, ag.sendToRoster = false, false
        ag.sendToGuild   = (which == "guild")
        ag.sendToFriends = (which == "friends")
    end

    local REALM = "TestRealm"

    ------------------------------------------------------------------
    -- 0. THE KEY. One convention, shared with friends.lua's ledger key.
    ------------------------------------------------------------------
    local F = ns.MeshFriends
    for _, row in ipairs({
        { "Bob",                      "bob-testrealm" },
        { "bob",                      "bob-testrealm" },
        { "BOB",                      "bob-testrealm" },
        { "  Bob  ",                  "bob-testrealm" },
        { "Bob-TestRealm",            "bob-testrealm" },
        { "Bob-testrealm",            "bob-testrealm" },
        { "Bob-Blood Sail Buccaneers","bob-bloodsailbuccaneers" },
    }) do
        ck(Auto.SocialKey(row[1], REALM) == row[2],
            ("key: %q -> %s"):format(row[1], row[2]))
        -- ...and byte-identical to friends.lua's key, so the addon has ONE
        -- naming convention rather than two that look alike.
        if F and F.Key then
            ck(Auto.SocialKey(row[1], REALM) == F.Key(row[1], REALM),
                ("key: %q agrees with Friends.Key"):format(row[1]))
        end
    end
    -- The deliberate delta: an apostrophe realm. Auto.NormalizeName appends
    -- GetNormalizedRealmName(), which has already dropped the apostrophe, so
    -- both spellings MUST land on one key or Nek'Rosh never matches anything.
    ck(Auto.SocialKey("Bob-Nek'Rosh") == Auto.SocialKey("Bob-NekRosh"),
        "key: an apostrophe realm folds to the same key as the normalized one")
    ck(Auto.SocialKey("") == nil, "key: an empty name has no key")
    ck(Auto.SocialKey("   ") == nil, "key: whitespace has no key")

    ------------------------------------------------------------------
    -- 1. ADVERSARIAL, FIRST: the gate is consulted before any snapshot has
    --    EVER been captured (fresh install). No match, no error.
    ------------------------------------------------------------------
    onlyGate("guild")
    data.social = nil
    local okFresh, freshAccept = pcall(Auto.ShouldAcceptInvite, "Someone-TestRealm")
    ck(okFresh, "fresh install: consulting the gate with no social table does not error")
    ck(okFresh and freshAccept == false, "fresh install: and admits nobody")
    local okFreshK, freshInvite = pcall(Auto.ShouldInviteKeyword, "Someone-TestRealm")
    ck(okFreshK and freshInvite == false, "fresh install: the keyword send gate admits nobody either")
    resetStore()
    local okEmpty, emptyAccept = pcall(Auto.ShouldAcceptInvite, "Someone-TestRealm")
    ck(okEmpty and emptyAccept == false, "fresh install: an empty captured set admits nobody")

    ------------------------------------------------------------------
    -- 2. GUILD. A member of the captured roster clears the real gate; a
    --    stranger does not. Driven end to end: JudgeGuild -> Store writer ->
    --    Auto.ShouldAcceptInvite.
    ------------------------------------------------------------------
    local action, set, label = Social.JudgeGuild({
        inGuild = true, realm = REALM, guildName = "Testers",
        names = { "Guildy", "OtherGuildy-TestRealm", "cAsEy" },
    })
    ck(action == "write" and label == "Testers", "guild: a populated roster is a confirmed write")
    Store.SetSocialSet("guild", set, 1700000000, label)

    local a, cat = Auto.ShouldAcceptInvite(Auto.NormalizeName("Guildy"))
    ck(a and cat == "guild", "guild: a guildmate's invite is accepted, as guild")
    a, cat = Auto.ShouldInviteKeyword(Auto.NormalizeName("Guildy"))
    ck(a and cat == "guild", "guild: and their keyword whisper earns an invite")
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Stranger")) == false,
        "guild: a non-member is not accepted")
    -- Normalization rows, through the gate: case and realm suffix.
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("guildy")) == true,
        "guild: a lowercase sender still matches")
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("GUILDY")) == true,
        "guild: an uppercase sender still matches")
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Casey")) == true,
        "guild: a mixed-case ROSTER entry still matches a plainly-cased sender")
    ck(Auto.ShouldAcceptInvite("Guildy-TestRealm") == true,
        "guild: a realm-suffixed sender matches a bare roster name")
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("OtherGuildy")) == true,
        "guild: a bare sender matches a realm-suffixed roster name")
    -- The gate is the guild gate: with the toggle off, membership is irrelevant.
    ag.acceptFromGuild = false
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Guildy")) == false,
        "guild: the toggle off means a guildmate is not accepted")
    ag.acceptFromGuild = true

    ------------------------------------------------------------------
    -- 3. NOT IN A GUILD is a confirmed answer, not a dark one — and it drops
    --    the previous guild's roster instead of trusting it forever.
    ------------------------------------------------------------------
    action, set, label = Social.JudgeGuild({ inGuild = false, realm = REALM })
    ck(action == "write" and next(set) == nil and label == "",
        "guild: no guild is a confirmed EMPTY snapshot")
    Store.SetSocialSet("guild", set, 1700000100, label)
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Guildy")) == false,
        "guild: leaving the guild revokes the guildmates' trust")

    ------------------------------------------------------------------
    -- 4. THE DARK READ. In a guild, roster silent -> write NOTHING, and the
    --    gate keeps reading the previous snapshot.
    ------------------------------------------------------------------
    action, set = Social.JudgeGuild({ inGuild = true, realm = REALM, names = {} })
    ck(action == "dark" and set == nil, "dark guild: an unanswered roster is not a snapshot")
    action, set = Social.JudgeGuild({ inGuild = true, realm = REALM, names = nil })
    ck(action == "dark", "dark guild: a missing roster API is not a snapshot either")

    Store.SetSocialSet("guild", { ["guildy-testrealm"] = true }, 1700000200, "Testers")
    local before = Store.GetSocial().guild
    action = Social.JudgeGuild({ inGuild = true, realm = REALM, names = {} })
    ck(action == "dark", "dark guild: still dark with a snapshot already stored")
    ck(Store.GetSocial().guild == before, "dark guild: the stored snapshot is untouched")
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Guildy")) == true,
        "dark guild: the gate answers from the PREVIOUS snapshot, not from silence")

    ------------------------------------------------------------------
    -- 5. FRIENDS. Same three rules, plus the Battle.net half of gate 4.
    ------------------------------------------------------------------
    onlyGate("friends")
    local fAction, fSet = Social.JudgeFriends({
        listConfirmed = true, realm = REALM,
        names = { "buddy" }, bnetNames = { "Bnetpal-TestRealm" },
    })
    ck(fAction == "write", "friends: a confirmed list is a write")
    Store.SetSocialSet("friends", fSet, 1700000300)
    a, cat = Auto.ShouldAcceptInvite(Auto.NormalizeName("Buddy"))
    ck(a and cat == "friends", "friends: a friend's invite is accepted, as friends")
    a, cat = Auto.ShouldInviteKeyword(Auto.NormalizeName("Buddy"))
    ck(a and cat == "friends", "friends: and their keyword whisper earns an invite")
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Bnetpal")) == true,
        "friends: a Battle.net friend's WoW character is in the same category (§12.2 gate 4)")
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Stranger")) == false,
        "friends: a non-friend is not accepted")
    ag.acceptFromFriends = false
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Buddy")) == false,
        "friends: the toggle off means a friend is not accepted")
    ag.acceptFromFriends = true

    ------------------------------------------------------------------
    -- 6. THE UNCONFIRMED FRIENDS LIST — the trap friends.lua exists to avoid,
    --    restated for the trust set: an unconfirmed read must never be able to
    --    revoke a friend's trust.
    ------------------------------------------------------------------
    fAction, fSet = Social.JudgeFriends({ listConfirmed = false, realm = REALM, names = {} })
    ck(fAction == "dark" and fSet == nil, "dark friends: an unconfirmed list is not a snapshot")
    local fBefore = Store.GetSocial().friends
    ck(Social.JudgeFriends({ listConfirmed = false, realm = REALM,
                             names = { "buddy" } }) == "dark",
        "dark friends: not even a non-empty unconfirmed read is written")
    ck(Store.GetSocial().friends == fBefore, "dark friends: the stored snapshot is untouched")
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Buddy")) == true,
        "dark friends: the gate answers from the PREVIOUS snapshot")
    -- ...while a confirmed EMPTY list is a real answer and does revoke.
    fAction, fSet = Social.JudgeFriends({ listConfirmed = true, realm = REALM, names = {} })
    ck(fAction == "write", "friends: a confirmed EMPTY list is a real answer")
    Store.SetSocialSet("friends", fSet, 1700000400)
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Buddy")) == false,
        "friends: unfriending someone revokes their trust")

    ------------------------------------------------------------------
    -- 7. REFRESH ON A ROSTER EVENT, through the REAL capture path and the real
    --    globals the handler reads.
    ------------------------------------------------------------------
    onlyGate("guild")
    resetStore()
    local G = _G
    local savedIn, savedNum, savedInfo, savedGI =
        G.IsInGuild, G.GetNumGuildMembers, G.GetGuildRosterInfo, G.GetGuildInfo
    local roster = { "Newguildy" }
    G.IsInGuild          = function() return true end
    G.GetNumGuildMembers = function() return #roster end
    G.GetGuildRosterInfo = function(i) return roster[i] end
    G.GetGuildInfo       = function() return "Testers" end

    local act, changed = Social.CaptureGuild()
    ck(act == "write" and changed == true, "refresh: the first roster event captures a snapshot")
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Newguildy")) == true,
        "refresh: the captured member clears the real gate")
    ck(Store.GetSocial().guildName == "Testers", "refresh: the snapshot records which guild it is of")
    ck((tonumber(Store.GetSocial().guildAt) or 0) > 0, "refresh: and when it was taken")

    -- An identical re-read is idempotent: no rewrite, no churn.
    act, changed = Social.CaptureGuild()
    ck(act == "write" and changed == false, "refresh: an unchanged roster rewrites nothing")

    -- A member joins: the very next event carries them.
    roster[#roster + 1] = "Recruit"
    act, changed = Social.CaptureGuild()
    ck(act == "write" and changed == true, "refresh: a roster that grew is a change")
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Recruit")) == true,
        "refresh: the new member clears the gate on the next event")

    -- A member leaves: wholesale replacement forgets them (a merge never could).
    roster = { "Recruit" }
    Social.CaptureGuild()
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Newguildy")) == false,
        "refresh: a member who left is forgotten, not merged forward")

    -- The roster goes dark mid-session (a /reload's first frames): nothing is
    -- written and the standing snapshot still answers.
    roster = {}
    act, changed = Social.CaptureGuild()
    ck(act == "dark" and changed == false, "refresh: a dark re-read writes nothing")
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Recruit")) == true,
        "refresh: and the standing snapshot still answers")

    -- Index holes (show-offline off: the count exceeds what the walk exposes)
    -- are skipped, not treated as a corrupt roster.
    roster = { "Onlineguy" }
    G.GetNumGuildMembers = function() return 40 end
    act = Social.CaptureGuild()
    ck(act == "write", "refresh: a count larger than the walk is not an error")
    ck(Auto.ShouldAcceptInvite(Auto.NormalizeName("Onlineguy")) == true,
        "refresh: and the names it DID expose are captured")

    G.IsInGuild, G.GetNumGuildMembers, G.GetGuildRosterInfo, G.GetGuildInfo =
        savedIn, savedNum, savedInfo, savedGI

    ------------------------------------------------------------------
    -- 8. CEILINGS. An absurd roster cannot grow the saved variables without
    --    bound, and the store's cap is the same cap.
    ------------------------------------------------------------------
    local huge = {}
    for i = 1, Social.MAX_GUILD + 200 do huge[i] = ("Bulk%d"):format(i) end
    local _, hSet = Social.JudgeGuild({ inGuild = true, realm = REALM, names = huge })
    local hN = 0
    for _ in pairs(hSet) do hN = hN + 1 end
    ck(hN <= Social.MAX_GUILD, "ceiling: the roster walk stops at MAX_GUILD")
    local _, storedN = Store.SetSocialSet("guild", hSet, 1700000500, "Big")
    ck(storedN <= (Store.SOCIAL_MAX or 800), "ceiling: the store caps what it keeps")

    -- Junk in the roster is skipped, never keyed.
    local _, jSet, _ = Social.JudgeGuild({ inGuild = true, realm = REALM,
        names = { "Realguy", "", 42, false, "  " } })
    local jN = 0
    for _ in pairs(jSet) do jN = jN + 1 end
    ck(jN == 1, "ceiling: junk roster entries are skipped, not keyed")

    -- The store writer refuses a set it does not own the name of.
    ck(select(1, Store.SetSocialSet("enemies", { x = true }, 0)) == false,
        "store: only guild and friends are writable sets")
    ck(select(1, Store.SetSocialSet("guild", "not a table", 0)) == false,
        "store: a non-table is refused, not stored")

    ------------------------------------------------------------------
    -- Restore.
    ------------------------------------------------------------------
    data.social = savedSocial
    for k in pairs(ag) do ag[k] = nil end
    for k, v in pairs(savedAG) do ag[k] = v end

    if verbose and pass then
        ns:Print("  PASS social/key + guild + friends + dark-read + refresh + ceilings")
    end
    return pass
end)
