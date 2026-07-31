-- Daseeki Nexus — syncns.lua  (WAVE N4b: SUITE-INTEGRATION NAMESPACES)
--
-- Two suite-wide namespaces that Daseeki-Nexus owns and publishes so the
-- rest of the addon suite (Bags today, everything later) can consume shared
-- transport without re-implementing it:
--
--   Daseeki.Sync    — ownership of the `DaseekiWoWHelperRemote` file-mirror
--                     contract (per-addon keys). This wave ships the registry
--                     + read/write accessors that PROXY the existing global so
--                     the N5 Bags cutover is a declaration swap, not an API
--                     change. See "N5 MIGRATION" below.
--
--   Daseeki.Config  — the global-config-sync registry: each suite addon
--                     registers { get, apply, revision }; Network transports the
--                     changed config over the mesh (revision-counter,
--                     last-writer-wins) and, offline, via the helper file mirror
--                     (apply-at-login). Supersedes the spec's manual
--                     "Send Settings to Mesh"; the manual push survives as
--                     "Sync now" (Config.SyncNow).
--
-- MESH COUPLING (no mesh.lua edits): config frames ride the existing
-- settings-sync frame family (Mesh.OP.SETTINGS on Protocol.PREFIX.SYNC). Mesh
-- already decodes that op and fires "MESH_SETTINGS_RECEIVED"; we subscribe to
-- that bus and demux our own blobs by a `__dsnConfig` marker. The soft-guard
-- hook `Mesh.RegisterConfigChannel(codec)` is DEFINED HERE (added to the Mesh
-- table at load) rather than by editing mesh.lua.

local ADDON, ns = ...

----------------------------------------------------------------------
-- The suite-global `Daseeki` table (shared across all Daseeki addons).
-- Create-if-missing so load order between suite addons doesn't matter.
----------------------------------------------------------------------

Daseeki = Daseeki or {}
local Daseeki = Daseeki

----------------------------------------------------------------------
-- Daseeki.Sync v2 — mesh-transported namespace store (wave N5)
--
-- REDEFINITION (2026-07-28, helper retired): Daseeki.Sync is no longer a proxy
-- over a file-mirrored SavedVariable. It is a real store, backed by
-- DaseekiNexusData.syncNamespaces and transported over the Nexus mesh:
--
--   * A consumer registers a PROVIDER namespace:
--       Daseeki.Sync.RegisterNamespace(key, {
--           provide  = function() return <table> end,   -- our current payload
--           rev      = function() return <number> end,  -- OPTIONAL monotonic rev
--                                                        --   (auto-incremented if
--                                                        --    omitted)
--           onRemote = function(ownerKey, data) ... end, -- a peer's payload
--           ownerKey = "<string>" | function() return "<string>" end,
--                        -- OPTIONAL: identifies OUR data owner (a character,
--                        --   for "bags"); defaults to this Nexus account id.
--       })
--   * Daseeki.Sync.Get(key) returns the MERGED local+remote view keyed by
--     ownerKey: { [ownerKey] = data, ... }.
--   * Daseeki.Sync.MarkDirty(key) snapshots our provide() into the store under
--     our ownerKey (bumping rev) and hands it to the mesh for debounced,
--     chunked, revision-gated propagation (store-and-forward to peers that
--     appear later).
--   * The mesh calls Daseeki.Sync.ApplyInbound(...) for received payloads
--     (owner-wins-by-rev; delivers winners to onRemote) and reads
--     Daseeki.Sync.AllNamespaceHashes() for its heartbeat rev-diffing.
--
-- LEGACY key-value API (Get/Set/GetRemote/NotifyRemoteUpdated) is retained for
-- non-provider namespaces — Daseeki.Config's offline catch-up still calls
-- Get/Set(key). Its backing moved from the vanished DaseekiWoWHelperRemote
-- global to DaseekiNexusData.syncKV.
----------------------------------------------------------------------

local Sync = {}
Daseeki.Sync = Daseeki.Sync or Sync
Sync = Daseeki.Sync

Sync.VERSION = 2
Sync._namespaces = Sync._namespaces or {}   -- key -> { provide, rev, onRemote, ownerKey }

local function store()
    return ns.Store
end

-- The legacy key-value table (backed by the SV; lazily created on write).
local function kv(create)
    local S = store()
    if not (S and S.data) then return nil end
    if create then S.data.syncKV = S.data.syncKV or {} end
    return S.data.syncKV
end

-- Resolve OUR local owner key for a namespace. Providers may pin it via
-- spec.ownerKey (string or fn); default is this account's Nexus id.
function Sync.LocalOwnerKey(key)
    local spec = Sync._namespaces[key]
    local ok = spec and spec.ownerKey
    if type(ok) == "function" then
        local good, res = pcall(ok)
        if good and type(res) == "string" and res ~= "" then return res end
    elseif type(ok) == "string" and ok ~= "" then
        return ok
    end
    return (ns.GetAccountID and ns:GetAccountID()) or ""
end

function Sync.IsProviderNamespace(key)
    local spec = Sync._namespaces[key]
    return spec ~= nil and spec.provide ~= nil
end

-- Safe-call a namespace provider. Returns ok, payload.
function Sync._Provide(key)
    local spec = Sync._namespaces[key]
    if not spec or not spec.provide then return false, nil end
    local ok, res = pcall(spec.provide)
    if not ok then geterrorhandler()(res); return false, nil end
    return true, res
end

-- The whole legacy key-value table (back-compat accessor).
function Sync.GetRemote()
    return kv(false)
end

-- Read a namespace. For a PROVIDER namespace this is the merged local+remote
-- view keyed by ownerKey; for a legacy key-value namespace it is the stored
-- value for `key`.
function Sync.Get(key)
    if Sync.IsProviderNamespace(key) then
        local view = {}
        local S = store()
        if S and S.SyncNSAll then
            for ownerKey, entry in pairs(S.SyncNSAll(key)) do
                view[ownerKey] = entry.data
            end
        end
        local ok, data = Sync._Provide(key)
        if ok and data ~= nil then
            view[Sync.LocalOwnerKey(key)] = data
        end
        return view
    end
    local t = kv(false)
    return t and t[key] or nil
end

-- Write a legacy key-value namespace value (Config offline catch-up).
function Sync.Set(key, value)
    local t = kv(true)
    if not t then return false end
    t[key] = value
    return true
end

-- Register a namespace. A `provide` field makes it a v2 provider namespace;
-- without one it is a legacy key-value namespace (onRemote receives the stored
-- value at login). Registration is idempotent; re-registering updates the spec.
function Sync.RegisterNamespace(key, spec)
    if type(key) ~= "string" or key == "" then return false end
    spec = spec or {}
    Sync._namespaces[key] = {
        provide  = spec.provide,
        rev      = spec.rev,
        onRemote = spec.onRemote,
        ownerKey = spec.ownerKey,
    }
    return true
end

-- The next local revision for our payload in a provider namespace. Providers
-- may supply their own monotonic rev(); otherwise auto-increment past whatever
-- we last stored under our own owner key.
function Sync.NextLocalRev(key)
    local spec = Sync._namespaces[key]
    if spec and spec.rev then
        local ok, r = pcall(spec.rev)
        if ok and type(r) == "number" then return r end
    end
    local S = store()
    local existing = S and S.SyncNSGet and S.SyncNSGet(key, Sync.LocalOwnerKey(key))
    return (existing and existing.rev or 0) + 1
end

-- Snapshot our provider payload into the store (bumping rev) and hand it to the
-- mesh for debounced propagation. Safe with the mesh absent/disabled — the
-- store is still seeded so Get() and store-and-forward see the change.
function Sync.MarkDirty(key)
    local spec = Sync._namespaces[key]
    if not spec or not spec.provide then return false end
    local ok, data = Sync._Provide(key)
    if not ok or data == nil then return false end
    local S = store()
    if not (S and S.SyncNSPut) then return false end
    local ownerKey = Sync.LocalOwnerKey(key)
    local rev = Sync.NextLocalRev(key)
    S.SyncNSPut(key, ownerKey, rev, data, S.Now and S.Now() or nil)
    if ns.Mesh and ns.Mesh.PushNamespace then
        ns.Mesh.PushNamespace(key, ownerKey)
    end
    return true
end

-- Deliver one owner's payload to a namespace's onRemote (guarded).
function Sync._DeliverOne(key, ownerKey, data)
    local spec = Sync._namespaces[key]
    if not spec or not spec.onRemote then return end
    local okc, err = pcall(spec.onRemote, ownerKey, data)
    if not okc then geterrorhandler()(err) end
end

-- Apply a payload received from the mesh: owner-wins-by-rev into the store,
-- and on a winning apply deliver it to onRemote. Never overwrites OUR own live
-- owner key (self-immunity). Returns "applied"/"stale".
function Sync.ApplyInbound(key, ownerKey, rev, data, now)
    local S = store()
    if not (S and S.SyncNSPut) then return "stale" end
    if Sync.IsProviderNamespace(key) and ownerKey == Sync.LocalOwnerKey(key) then
        return "stale"   -- a peer must never clobber our own live payload
    end
    local result = S.SyncNSPut(key, ownerKey, rev, data, now)
    if result == "applied" then
        Sync._DeliverOne(key, ownerKey, data)
    end
    return result
end

-- Deliver every stored remote owner (excluding our own live owner) to a
-- provider namespace's onRemote. Used at login so consumers see all cached
-- cross-account data immediately, before any live mesh frame arrives.
function Sync.DeliverRemote(key)
    local spec = Sync._namespaces[key]
    if not spec or not spec.onRemote then return end
    local S = store()
    if not (S and S.SyncNSAll) then return end
    local mine = Sync.LocalOwnerKey(key)
    for ownerKey, entry in pairs(S.SyncNSAll(key)) do
        if ownerKey ~= mine then
            Sync._DeliverOne(key, ownerKey, entry.data)
        end
    end
end

-- A deterministic hash of a provider namespace's owner->rev map, advertised in
-- heartbeats so a peer with a differing hash pulls the divergent namespace.
function Sync.NamespaceRevHash(key)
    local S = store()
    local parts = {}
    if S and S.SyncNSAll then
        for ownerKey, entry in pairs(S.SyncNSAll(key)) do
            parts[#parts + 1] = ownerKey .. "=" .. tostring(entry.rev or 0)
        end
    end
    table.sort(parts)
    local joined = table.concat(parts, "\30")
    if ns.Mesh and ns.Mesh.Fnv1a then return ns.Mesh.Fnv1a(joined) end
    local h = 5381
    for i = 1, #joined do h = (h * 33 + joined:byte(i)) % 2147483647 end
    return tostring(h)
end

-- All provider namespaces' rev hashes, for the heartbeat bundle.
function Sync.AllNamespaceHashes()
    local out = {}
    for key, spec in pairs(Sync._namespaces) do
        if spec.provide then out[key] = Sync.NamespaceRevHash(key) end
    end
    return out
end

-- Provider namespace keys (mesh iterates these when answering a pull).
function Sync.ProviderKeys()
    local out = {}
    for key, spec in pairs(Sync._namespaces) do
        if spec.provide then out[#out + 1] = key end
    end
    return out
end

-- Snapshot + queue every local provider payload for the mesh (login + on
-- account-id change).
function Sync.PublishAll()
    for _, key in ipairs(Sync.ProviderKeys()) do
        Sync.MarkDirty(key)
    end
end

-- Legacy compat: fire a namespace's onRemote with its current data. Provider
-- namespaces deliver all cached remote owners; legacy namespaces deliver the
-- stored key-value (Config offline catch-up).
function Sync.NotifyRemoteUpdated(key)
    local spec = Sync._namespaces[key]
    if not spec or not spec.onRemote then return end
    if spec.provide then
        Sync.DeliverRemote(key)
        return
    end
    local data = Sync.Get(key)
    if ns.SafeCall then ns:SafeCall(spec.onRemote, key, data)
    else spec.onRemote(key, data) end
end

-- Login pass: deliver cached cross-account data to every consumer, then
-- advertise our own payloads to the mesh.
function Sync.OnLogin()
    for key, spec in pairs(Sync._namespaces) do
        if spec.provide then
            Sync.DeliverRemote(key)
        elseif spec.onRemote then
            Sync.NotifyRemoteUpdated(key)
        end
    end
    Sync.PublishAll()
end

----------------------------------------------------------------------
-- Daseeki.Config — global config-sync registry (revision-counter, LWW)
----------------------------------------------------------------------

local Config = {}
Daseeki.Config = Daseeki.Config or Config
Config = Daseeki.Config

Config._registry  = Config._registry  or {}   -- addonId -> { get, apply, revision }
Config._revisions = Config._revisions or {}   -- addonId -> last-known revision (LWW state)
Config._codec     = Config._codec     or nil  -- optional inner-payload codec

-- The helper file-mirror namespace key this registry reads/writes for OFFLINE
-- catch-up (via Daseeki.Sync). The ps1 file mirror should expose a matching
-- `config` namespace: DaseekiWoWHelperRemote.config[addonId] = { revision, payload }.
local CONFIG_SYNC_KEY = "config"

-- Register a suite addon's config group.
--   spec.get()             -> the current config payload (table) to broadcast
--   spec.apply(payload,rev)-> apply an incoming payload (re-render, no /reload)
--   spec.revision          -> optional seed revision (number); defaults 0
-- Registration is idempotent; re-registering updates the spec.
function Config.Register(addonId, spec)
    if type(addonId) ~= "string" or addonId == "" or type(spec) ~= "table" then
        return false
    end
    Config._registry[addonId] = { get = spec.get, apply = spec.apply, revision = spec.revision }
    if Config._revisions[addonId] == nil then
        Config._revisions[addonId] = tonumber(spec.revision) or 0
    end
    return true
end

-- Current local revision for an addon's config group.
function Config.LocalRevision(addonId)
    return Config._revisions[addonId] or 0
end

----------------------------------------------------------------------
-- PURE core: revision-counter last-writer-wins.
--
-- `state` = { registry = {addonId->spec}, revisions = {addonId->rev} }.
-- Returns "applied" | "stale" | "unknown". STRICTLY-greater revision wins;
-- equal revisions keep the local value (deterministic tie -> local).
----------------------------------------------------------------------

function Config._ApplyIncoming(state, blob)
    if type(blob) ~= "table" or type(blob.addonId) ~= "string" then return "unknown" end
    local spec = state.registry[blob.addonId]
    if not spec then return "unknown" end
    local incoming = tonumber(blob.revision) or 0
    local current  = state.revisions[blob.addonId] or 0
    if incoming > current then
        state.revisions[blob.addonId] = incoming
        if spec.apply then
            if ns.SafeCall then ns:SafeCall(spec.apply, blob.payload, incoming)
            else spec.apply(blob.payload, incoming) end
        end
        return "applied"
    end
    return "stale"
end

-- Live-state wrapper around the pure core.
function Config._Receive(blob, sender)
    return Config._ApplyIncoming(
        { registry = Config._registry, revisions = Config._revisions }, blob)
end

----------------------------------------------------------------------
-- Mesh transport (rides the settings-sync frame family; no mesh.lua edits)
----------------------------------------------------------------------

-- Soft-guard hook: lets a consumer supply a compact codec for the INNER
-- payload (spec.get() result) before it is LibSerialize-packed into the
-- settings frame. Default is identity. Defined on the Mesh table from THIS
-- file so mesh.lua stays untouched.
local function installConfigChannel()
    local Mesh = ns.Mesh
    if not Mesh then return end
    if not Mesh.RegisterConfigChannel then
        function Mesh.RegisterConfigChannel(codec)
            Config._codec = codec
        end
    end
end

local function encodePayload(payload)
    if Config._codec and Config._codec.encode then return Config._codec.encode(payload) end
    return payload
end
local function decodePayload(payload)
    if Config._codec and Config._codec.decode then return Config._codec.decode(payload) end
    return payload
end

-- Build one config blob for an addon. Marker `__dsnConfig` demuxes it from
-- real settings-sync blobs sharing the same op.
function Config._BuildBlob(addonId)
    local spec = Config._registry[addonId]
    if not spec or not spec.get then return nil end
    local payload
    if ns.SafeCall then
        local ok, res = ns:SafeCall(spec.get)
        payload = ok and res or nil
    else
        payload = spec.get()
    end
    return {
        __dsnConfig = true,
        addonId     = addonId,
        revision    = Config.LocalRevision(addonId),
        payload     = encodePayload(payload),
        syncId      = "cfg-" .. addonId .. "-" .. tostring(Config.LocalRevision(addonId)),
    }
end

-- Push one addon's (or all) config group(s) to every online mesh peer.
function Config._PushBlob(blob)
    local Mesh = ns.Mesh
    local Protocol = ns.Protocol
    if not (Mesh and Protocol and Mesh.IsEnabled and Mesh.IsEnabled()) then return false end
    if not (Mesh.Pack and Mesh.BuildFrame and Mesh.WhisperKnownPeers and Mesh.OP) then return false end
    local wire = Mesh.Pack(blob)
    if not wire then return false end
    local seq = (Mesh._outSeq or 0) + 1
    local frame = Mesh.BuildFrame(Mesh.OP.SETTINGS, wire, { seq = seq })
    Mesh.WhisperKnownPeers(Protocol.PREFIX.SYNC, frame, { op = "settings", seq = seq })
    return true
end

-- Broadcast a single addon's config now.
function Config.Push(addonId)
    local blob = Config._BuildBlob(addonId)
    if not blob then return false end
    return Config._PushBlob(blob)
end

-- Broadcast every registered addon's config (the "Sync now" action).
function Config.SyncNow()
    local any = false
    for addonId in pairs(Config._registry) do
        if Config.Push(addonId) then any = true end
    end
    return any
end

-- Increment an addon's revision (local edit happened) and push it. Also mirror
-- the new revision+payload into the helper file namespace for offline peers.
function Config.Bump(addonId)
    if not Config._registry[addonId] then return false end
    Config._revisions[addonId] = (Config._revisions[addonId] or 0) + 1
    Config._MirrorToFile(addonId)
    return Config.Push(addonId)
end

-- Write an addon's current config into the helper file-mirror namespace so
-- OFFLINE peers catch up at their next login (Daseeki.Sync transport).
function Config._MirrorToFile(addonId)
    local spec = Config._registry[addonId]
    if not spec or not spec.get then return end
    local cfg = Daseeki.Sync.Get(CONFIG_SYNC_KEY)
    if type(cfg) ~= "table" then cfg = {} end
    local payload
    if ns.SafeCall then local ok, res = ns:SafeCall(spec.get); payload = ok and res or nil
    else payload = spec.get() end
    cfg[addonId] = { revision = Config.LocalRevision(addonId), payload = payload }
    Daseeki.Sync.Set(CONFIG_SYNC_KEY, cfg)
end

-- Apply offline catch-up from the file mirror at login. Registered as the
-- `config` namespace's onRemote so Daseeki.Sync.OnLogin drives it.
function Config._ApplyFromFile(_key, data)
    if type(data) ~= "table" then return end
    for addonId, entry in pairs(data) do
        if type(entry) == "table" then
            Config._Receive({
                __dsnConfig = true, addonId = addonId,
                revision = entry.revision, payload = entry.payload,
            })
        end
    end
end

----------------------------------------------------------------------
-- RAID ATTUNEMENT namespace ("attune") — cross-ACCOUNT personal attunement.
--
-- Nexus's own first provider namespace (Bags was the first external consumer).
-- It exists because raid attunement is a per-character fact that the mesh's
-- character graph does not carry: protocol.lua's binary record schema is FROZEN
-- (no SCHEMA_VERSION bump for this feature), so the flags ride the additive
-- namespace transport instead. That is the whole point of the N5 namespace
-- store — new cross-account data without touching the wire schema.
--
--   ownerKey  the DEFAULT (this Nexus account id). Attunement is published
--             per ACCOUNT, one payload covering every character we own, rather
--             than per character as "bags" does: the matrix is seven booleans,
--             so a whole account's worth is smaller than a single bags payload,
--             and one owner entry means one rev to gate instead of N.
--   payload   { [nameRealm] = { [raidKey] = bool } } — see Tracker.AttunePayload.
--   onRemote  drops the projected read index; Store.RaidAttuned rebuilds it
--             lazily on the next read. Nothing is merged into peer character
--             records — the mesh wholesale-replaces those on every state push,
--             so a merge would be erased (see the note in tracker.lua).
--
-- NO PROTOCOL BUMP, and old peers are safe by construction:
--   * Mesh.HandleNSPayload -> Sync.ApplyInbound stores ANY namespace key it is
--     handed, registered or not, then Sync._DeliverOne finds no spec and
--     returns. An un-updated peer therefore CACHES our attunement payload
--     silently and errors on nothing.
--   * Because it cached it, Sync.OnLogin -> DeliverRemote replays that payload
--     to the consumer the moment that peer does update — no re-sync needed.
--   * Mesh.DiffNamespaceHashes iterates the REMOTE hash map, so an old peer
--     still pulls "attune" from us (its local hash reads "0"), and a new peer
--     pulls whatever an old peer relayed. Every path is rev-gated.
----------------------------------------------------------------------

local ATTUNE_SYNC_KEY = "attune"

local function attuneProvide()
    local T = ns.Tracker
    if not (T and T.AttunePayload) then return nil end
    return T.AttunePayload()
end

local function attuneOnRemote(ownerKey, data)
    local T = ns.Tracker
    if T and T.OnRemoteAttune then T.OnRemoteAttune(ownerKey, data) end
end

Sync._AttuneProvide  = attuneProvide
Sync._AttuneOnRemote = attuneOnRemote
Sync.ATTUNE_KEY      = ATTUNE_SYNC_KEY

----------------------------------------------------------------------
-- Wiring: subscribe to the mesh settings bus + login hooks
----------------------------------------------------------------------

local function onMeshSettings(blob, sender)
    if type(blob) == "table" and blob.__dsnConfig then
        -- Decode inner payload symmetrically before applying.
        if Config._codec then blob.payload = decodePayload(blob.payload) end
        Config._Receive(blob, sender)
    end
    -- Non-config settings blobs are ignored here (handled elsewhere).
end

local function wire()
    installConfigChannel()
    -- Offline catch-up namespace.
    Daseeki.Sync.RegisterNamespace(CONFIG_SYNC_KEY, { onRemote = Config._ApplyFromFile })
    -- Cross-account raid attunement (account-granular provider namespace).
    Daseeki.Sync.RegisterNamespace(ATTUNE_SYNC_KEY, {
        provide  = attuneProvide,
        onRemote = attuneOnRemote,
    })
    -- Inbound live transport over the settings-sync frame family.
    if ns.On then ns:On("MESH_SETTINGS_RECEIVED", onMeshSettings) end
    -- Login: run the file-mirror apply pass once the world is up.
    if ns.On then ns:On("LOGIN", function() Daseeki.Sync.OnLogin() end) end
end

-- Install now if the bus already exists; also (re)install on STORE_READY so
-- ordering with core.lua is irrelevant.
wire()
if ns.On then ns:On("STORE_READY", function() installConfigChannel() end) end

----------------------------------------------------------------------
-- Self-test: revision-counter conflict matrix (pure; no mesh/globals)
----------------------------------------------------------------------

local function selfTest(verbose)
    local pass = true
    local applied = {}
    local function check(name, cond)
        if not cond then
            pass = false
            if verbose and ns.Print then ns:Print("  syncns selftest FAIL: " .. name) end
        end
    end

    -- Build an isolated state with one registered addon.
    local state = {
        registry = { bags = { apply = function(p, r) applied[#applied + 1] = { p = p, r = r } end } },
        revisions = { bags = 0 },
    }
    local function inc(rev, payload)
        return Config._ApplyIncoming(state, { __dsnConfig = true, addonId = "bags", revision = rev, payload = payload })
    end

    check("rev1 applies over 0", inc(1, "a") == "applied")
    check("state advanced to 1", state.revisions.bags == 1)
    check("rev1 again is stale (tie=local)", inc(1, "b") == "stale")
    check("rev0 stale", inc(0, "z") == "stale")
    check("rev3 applies (skips 2)", inc(3, "c") == "applied")
    check("state advanced to 3", state.revisions.bags == 3)
    check("rev2 now stale", inc(2, "y") == "stale")
    check("unknown addon", Config._ApplyIncoming(state, { addonId = "nope", revision = 9 }) == "unknown")
    check("malformed blob", Config._ApplyIncoming(state, { revision = 9 }) == "unknown")

    -- apply() only fired for the two winning writes, with correct payload/rev.
    check("apply fired twice", #applied == 2)
    check("first apply payload/rev", applied[1] and applied[1].p == "a" and applied[1].r == 1)
    check("second apply payload/rev", applied[2] and applied[2].p == "c" and applied[2].r == 3)

    -- File-mirror apply pass demuxes a {addonId->{revision,payload}} map.
    local state2applied = {}
    local saveReg, saveRev = Config._registry, Config._revisions
    Config._registry  = { bags = { apply = function(p, r) state2applied[#state2applied + 1] = r end } }
    Config._revisions = { bags = 0 }
    Config._ApplyFromFile("config", { bags = { revision = 5, payload = "f" } })
    check("file-mirror applied rev5", Config._revisions.bags == 5 and state2applied[1] == 5)
    Config._registry, Config._revisions = saveReg, saveRev

    if verbose and ns.Print then
        ns:Print(pass and "  syncns selftest: PASS" or "  syncns selftest: FAIL")
    end
    return pass
end

----------------------------------------------------------------------
-- Self-test: Daseeki.Sync v2 store (rev-gating, inbound apply + delivery,
-- merged Get, MarkDirty). Uses the real Store on a disposable namespace.
----------------------------------------------------------------------

local function syncSelfTest(verbose)
    local pass = true
    local function check(name, cond)
        if not cond then
            pass = false
            if verbose and ns.Print then ns:Print("  sync selftest FAIL: " .. name) end
        end
    end
    local S = ns.Store
    if not (S and S.SyncNSApply) then
        if verbose and ns.Print then ns:Print("  sync selftest SKIP (store unavailable)") end
        return true
    end

    -- Pure rev-gating matrix on Store.SyncNSApply (owner-wins-by-rev).
    local nsp = {}
    check("rev0 applies over empty", S.SyncNSApply(nsp, "A", 0, { v = 1 }, 100) == "applied")
    check("stored rev0/data", nsp.A and nsp.A.rev == 0 and nsp.A.data.v == 1)
    check("rev0 again stale", S.SyncNSApply(nsp, "A", 0, { v = 2 }, 101) == "stale")
    check("data unchanged after stale", nsp.A.data.v == 1)
    check("rev1 applies", S.SyncNSApply(nsp, "A", 1, { v = 3 }, 102) == "applied" and nsp.A.data.v == 3)
    check("rev3 skips 2", S.SyncNSApply(nsp, "A", 3, { v = 4 }, 103) == "applied")
    check("rev2 now stale", S.SyncNSApply(nsp, "A", 2, { v = 5 }, 104) == "stale")
    check("second owner independent", S.SyncNSApply(nsp, "B", 0, { v = 9 }, 105) == "applied" and nsp.B.data.v == 9)
    check("empty ownerKey stale", S.SyncNSApply(nsp, "", 5, {}, 106) == "stale")

    -- Round-trip through ApplyInbound + onRemote delivery + merged Get on a
    -- disposable provider namespace.
    local delivered = {}
    Sync.RegisterNamespace("__synctest", {
        ownerKey = function() return "self" end,
        provide  = function() return { mine = true } end,
        onRemote = function(ownerKey, data) delivered[ownerKey] = data end,
    })
    local temp = S.SyncNSNamespace("__synctest", true)
    for k in pairs(temp) do temp[k] = nil end

    check("inbound applies", Sync.ApplyInbound("__synctest", "peer1", 1, { hello = 1 }, 200) == "applied")
    check("onRemote delivered", delivered.peer1 and delivered.peer1.hello == 1)
    check("inbound stale rejected", Sync.ApplyInbound("__synctest", "peer1", 1, { hello = 2 }, 201) == "stale")
    check("self-owner inbound rejected", Sync.ApplyInbound("__synctest", "self", 9, { evil = 1 }, 202) == "stale")

    local view = Sync.Get("__synctest")
    check("merged has remote peer", view.peer1 and view.peer1.hello == 1)
    check("merged has local live", view.self and view.self.mine == true)

    check("markdirty ok", Sync.MarkDirty("__synctest") == true)
    local mine = S.SyncNSGet("__synctest", "self")
    check("markdirty stored our payload", mine and mine.data.mine == true)

    -- Namespace rev hash diverges after a change.
    local h1 = Sync.NamespaceRevHash("__synctest")
    Sync.ApplyInbound("__synctest", "peer2", 1, { x = 1 }, 203)
    local h2 = Sync.NamespaceRevHash("__synctest")
    check("rev hash changes on new owner", h1 ~= h2)

    -- Cleanup disposable namespace + registration.
    S.SyncNS()["__synctest"] = nil
    Sync._namespaces["__synctest"] = nil

    if verbose and ns.Print then
        ns:Print(pass and "  sync selftest: PASS" or "  sync selftest: FAIL")
    end
    return pass
end

----------------------------------------------------------------------
-- Self-test: Bags syncBridge API-shape compatibility (wave N5)
--
-- The Daseeki-Bags core/features/syncBridge.lua module is the FIRST consumer of
-- Daseeki.Sync v2. This asserts the EXACT surface it depends on, so a future
-- refactor of this file can't silently break the cutover:
--   * SuiteSync() capability probe: RegisterNamespace + MarkDirty + Get all
--     present as functions (MarkDirty is the v2-only marker).
--   * RegisterNamespace(key, { ownerKey=fn, provide=fn, onRemote=fn }) accepted.
--   * Get(key) returns a merged { [ownerKey] = data } view including our own
--     provide() payload under our ownerKey.
--   * onRemote fires for an inbound peer owner; last-writer-wins (a lower rev is
--     rejected, a strictly-higher rev applied) exactly as the mesh will drive it.
--   * The mesh NS transport surface the bridge relies on indirectly exists.
----------------------------------------------------------------------

local function bridgeCompatTest(verbose)
    local pass = true
    local function check(name, cond)
        if not cond then
            pass = false
            if verbose and ns.Print then ns:Print("  syncbridge selftest FAIL: " .. name) end
        end
    end

    -- 1) The literal SuiteSync() probe from syncBridge.lua.
    local S = _G and _G.Daseeki and _G.Daseeki.Sync
    check("Daseeki.Sync present", type(S) == "table")
    check("RegisterNamespace is fn", S and type(S.RegisterNamespace) == "function")
    check("MarkDirty is fn (v2 marker)", S and type(S.MarkDirty) == "function")
    check("Get is fn", S and type(S.Get) == "function")
    local probe = (S and S.RegisterNamespace and S.MarkDirty and S.Get) and S or nil
    check("SuiteSync() probe passes", probe ~= nil)

    local store = ns.Store
    if not (probe and store and store.SyncNSApply) then
        if verbose and ns.Print then ns:Print("  syncbridge selftest SKIP (sync/store unavailable)") end
        return pass
    end

    -- 2) Register a "bags"-shaped provider EXACTLY as syncBridge:OnLoad does.
    local ownerKey = "Tester-TestRealm"
    local delivered = {}
    local ok = probe.RegisterNamespace("__bridgetest", {
        ownerKey = function() return ownerKey end,
        provide  = function() return { itemCounts = { [1] = 3 }, money = 42, ts = 100 } end,
        onRemote = function(who, data) delivered[who] = data end,
    })
    check("RegisterNamespace accepts bridge spec", ok == true)

    -- Clear any residue in the disposable namespace.
    local temp = store.SyncNSNamespace("__bridgetest", true)
    for k in pairs(temp) do temp[k] = nil end

    -- 3) MarkDirty snapshots our provide() under our ownerKey.
    check("MarkDirty returns true", probe.MarkDirty("__bridgetest") == true)
    local mine = store.SyncNSGet("__bridgetest", ownerKey)
    check("MarkDirty stored our snapshot", mine and mine.data and mine.data.money == 42)

    -- 4) Get() returns the merged { [ownerKey] = data } view syncBridge iterates.
    local view = probe.Get("__bridgetest")
    check("Get returns table", type(view) == "table")
    check("Get merges our own owner", view[ownerKey] and view[ownerKey].money == 42)

    -- 5) Inbound peer -> onRemote fires; last-writer-wins on rev.
    check("peer rev1 applies", probe.ApplyInbound("__bridgetest", "Peer-TestRealm", 1,
        { itemCounts = { [2] = 9 }, money = 7, ts = 101 }, 101) == "applied")
    check("onRemote delivered peer", delivered["Peer-TestRealm"] and delivered["Peer-TestRealm"].money == 7)
    check("peer stale rev rejected (LWW)", probe.ApplyInbound("__bridgetest", "Peer-TestRealm", 1,
        { money = 999 }, 102) == "stale")
    check("peer higher rev applies (LWW)", probe.ApplyInbound("__bridgetest", "Peer-TestRealm", 2,
        { money = 55, ts = 103 }, 103) == "applied")
    check("onRemote got the winner", delivered["Peer-TestRealm"] and delivered["Peer-TestRealm"].money == 55)
    local merged = probe.Get("__bridgetest")
    check("Get merges peer + self", merged[ownerKey] and merged["Peer-TestRealm"]
        and merged["Peer-TestRealm"].money == 55 and merged[ownerKey].money == 42)

    -- 6) The mesh NS transport surface the bridge relies on indirectly.
    local M = ns.Mesh
    if M then
        check("Mesh.PushNamespace is fn", type(M.PushNamespace) == "function")
        check("Mesh.RequestNamespace is fn", type(M.RequestNamespace) == "function")
        check("Mesh.SendNamespace is fn", type(M.SendNamespace) == "function")
        check("Mesh.DiffNamespaceHashes is fn", type(M.DiffNamespaceHashes) == "function")
        check("Mesh.HandleNSPayload is fn", type(M.HandleNSPayload) == "function")
        check("Mesh.HandleNSReq is fn", type(M.HandleNSReq) == "function")
        -- hash-diff advertises the changed namespace so a diverging peer pulls it.
        local h1 = Sync.NamespaceRevHash("__bridgetest")
        probe.ApplyInbound("__bridgetest", "Peer2-TestRealm", 1, { money = 1 }, 104)
        local h2 = Sync.NamespaceRevHash("__bridgetest")
        check("rev hash shifts on change", h1 ~= h2)
        local diffs = M.DiffNamespaceHashes({ ["__bridgetest"] = h1 }, { ["__bridgetest"] = h2 })
        check("hash-diff flags the changed namespace", diffs[1] == "__bridgetest")
    end

    -- Cleanup disposable namespace + registration.
    store.SyncNS()["__bridgetest"] = nil
    Sync._namespaces["__bridgetest"] = nil

    if verbose and ns.Print then
        ns:Print(pass and "  syncbridge selftest: PASS" or "  syncbridge selftest: FAIL")
    end
    return pass
end

----------------------------------------------------------------------
-- Self-test: the "attune" namespace round-trip.
--
-- Asserts the namespace is really registered as a PROVIDER (so it is advertised
-- in the heartbeat rev-hash bundle and answered on a pull), that a peer's
-- payload lands through ApplyInbound -> onRemote and becomes readable through
-- Store.RaidAttuned, that rev-gating is last-writer-wins, and — the
-- back-compat claim the whole no-protocol-bump design rests on — that an
-- UNREGISTERED namespace key is cached without error, which is exactly what an
-- un-updated peer does with our attunement payload.
----------------------------------------------------------------------

local function attuneSelfTest(verbose)
    local pass = true
    local function check(name, cond)
        if not cond then
            pass = false
            if verbose and ns.Print then ns:Print("  attune selftest FAIL: " .. name) end
        end
    end

    local KEY = ATTUNE_SYNC_KEY
    check("attune namespace registered", Sync._namespaces[KEY] ~= nil)
    check("attune is a PROVIDER namespace", Sync.IsProviderNamespace(KEY) == true)
    check("attune advertises a rev hash", Sync.AllNamespaceHashes()[KEY] ~= nil)
    local isProvider = false
    for _, k in ipairs(Sync.ProviderKeys()) do if k == KEY then isProvider = true end end
    check("attune is in ProviderKeys (answered on a pull)", isProvider)

    -- provide() is wired to the tracker and returns a table (possibly empty).
    local okp, payload = Sync._Provide(KEY)
    check("provide() succeeds", okp == true)
    check("provide() returns a table", type(payload) == "table")

    local S = ns.Store
    local T = ns.Tracker
    if not (S and S.SyncNSPut and T and T.AttuneIndex) then
        if verbose and ns.Print then ns:Print("  attune selftest SKIP (store/tracker unavailable)") end
        return pass
    end

    local OWNER = "__attunens-peer"
    local savedIdx, savedDirty = T._attuneIndex, T._attuneIndexDirty
    S.SyncNSDrop(KEY, OWNER)

    -- A peer account's payload arrives from the mesh.
    check("peer rev1 applies", Sync.ApplyInbound(KEY, OWNER, 1, {
        ["Attuned-Realm"]   = { MC = true,  BWL = true,  Ony = true,  Naxx = true },
        ["Unattuned-Realm"] = { MC = false, BWL = false, Ony = false, Naxx = false },
    }, 500) == "applied")
    check("onRemote invalidated the index", T._attuneIndexDirty == true)

    -- ...and is readable through the public tri-state API.
    local RA = S.RaidAttuned
    check("peer attuned char reads true (MC)",  RA({ nameRealm = "Attuned-Realm" }, "MC") == true)
    check("peer attuned char reads true (Naxx)", RA({ nameRealm = "Attuned-Realm" }, "Naxx") == true)
    check("peer unattuned char reads FALSE (MC)", RA({ nameRealm = "Unattuned-Realm" }, "MC") == false)
    check("peer unattuned char reads FALSE (Ony)", RA({ nameRealm = "Unattuned-Realm" }, "Ony") == false)
    check("ungated raid still true for the unattuned char",
          RA({ nameRealm = "Unattuned-Realm" }, "AQ40") == true)
    check("a character nobody published stays nil",
          RA({ nameRealm = "Absent-Realm" }, "MC") == nil)

    -- Rev-gating: a stale rev is rejected, a higher rev wins and re-projects.
    check("peer stale rev rejected", Sync.ApplyInbound(KEY, OWNER, 1, {
        ["Unattuned-Realm"] = { MC = true } }, 501) == "stale")
    check("stale rev did not change the read",
          RA({ nameRealm = "Unattuned-Realm" }, "MC") == false)
    check("peer rev2 applies", Sync.ApplyInbound(KEY, OWNER, 2, {
        ["Unattuned-Realm"] = { MC = true, BWL = false, Ony = false, Naxx = false },
    }, 502) == "applied")
    check("the newly attuned char now reads true",
          RA({ nameRealm = "Unattuned-Realm" }, "MC") == true)
    check("a char dropped from the newer payload goes back to nil",
          RA({ nameRealm = "Attuned-Realm" }, "MC") == nil)

    -- The merged Get() view exposes the peer owner alongside our own.
    local view = Sync.Get(KEY)
    check("Get() merges the peer owner", type(view[OWNER]) == "table")
    check("Get() includes our own owner key", view[Sync.LocalOwnerKey(KEY)] ~= nil)

    -- BACK-COMPAT: an un-updated peer receives an unknown namespace key. It has
    -- no spec, so _DeliverOne no-ops -- it must CACHE without erroring, which is
    -- what lets it replay the payload to its consumer once it does update.
    local UNK = "__attunens-unknownkey"
    check("unknown namespace is not a provider", Sync.IsProviderNamespace(UNK) == false)
    local okUnk, resUnk = pcall(Sync.ApplyInbound, UNK, "someone", 1, { a = 1 }, 503)
    check("unknown namespace applies without error", okUnk == true and resUnk == "applied")
    check("unknown namespace payload was cached",
          (S.SyncNSGetData(UNK, "someone") or {}).a == 1)
    check("unknown namespace not advertised in our hashes", Sync.AllNamespaceHashes()[UNK] == nil)
    S.SyncNS()[UNK] = nil

    S.SyncNSDrop(KEY, OWNER)
    T._attuneIndex, T._attuneIndexDirty = savedIdx, savedDirty
    T.InvalidateAttuneIndex()

    if verbose and ns.Print then
        ns:Print(pass and "  attune selftest: PASS" or "  attune selftest: FAIL")
    end
    return pass
end

Sync._AttuneSelfTest = attuneSelfTest

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("syncns", function(verbose)
        local a = selfTest(verbose)
        local b = attuneSelfTest(verbose)
        return a and b
    end)
    ns:RegisterSelfTest("sync", syncSelfTest)
    ns:RegisterSelfTest("syncbridge", bridgeCompatTest)
end
Config._SelfTest = selfTest
Sync._SelfTest = syncSelfTest
Sync._BridgeCompatTest = bridgeCompatTest
