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
-- Daseeki.Sync — DaseekiWoWHelperRemote contract owner
--
-- CURRENT STATE (pre-N5): the `DaseekiWoWHelperRemote` SavedVariable is still
-- DECLARED by Daseeki-Bags' .toc and written by the offline helper
-- (DaseekiWoWHelper.ps1) file mirror. Network does NOT declare it yet. These
-- accessors therefore PROXY whatever global exists at runtime.
--
-- N5 MIGRATION (declaration swap — do these together, Bags + Network release):
--   1. Remove `DaseekiWoWHelperRemote` from Daseeki-Bags.toc SavedVariables.
--   2. Add `DaseekiWoWHelperRemote` to Daseeki-Nexus.toc SavedVariables.
--   3. One-time data migration honoring the SV-safety gate: with Network's SV
--      now authoritative, the first Network load inherits the existing on-disk
--      table (WoW loads it into the same global name), so NO copy step is
--      needed — but test on COPIES of all 4 accounts' WTF first (design D2).
--   4. Update DaseekiWoWHelper.ps1's target path/addon for the file mirror
--      (ops, hand-merged by the orchestrator — not this agent).
--   NONE of the API below changes across the swap: consumers keep calling
--   Daseeki.Sync.Get/Set/RegisterNamespace exactly as they do now.
----------------------------------------------------------------------

local SYNC_GLOBAL = "DaseekiWoWHelperRemote"

local Sync = {}
Daseeki.Sync = Daseeki.Sync or Sync
Sync = Daseeki.Sync

Sync._namespaces = Sync._namespaces or {}   -- key -> { onRemote = fn }

-- Resolve (and, on write, lazily create) the proxied remote table. Reading
-- never creates it, so a missing helper mirror simply reads as nil/empty.
local function remoteTable(createIfMissing)
    local G = _G or getfenv(0)
    local t = G[SYNC_GLOBAL]
    if type(t) ~= "table" and createIfMissing then
        t = {}
        G[SYNC_GLOBAL] = t
    end
    return (type(t) == "table") and t or nil
end

-- The whole remote table (or nil if the mirror isn't present this session).
function Sync.GetRemote()
    return remoteTable(false)
end

-- Read one per-addon namespace key from the remote mirror.
function Sync.Get(key)
    local t = remoteTable(false)
    return t and t[key] or nil
end

-- Write one per-addon namespace key into the remote mirror (lazily creating
-- the global if the mirror wasn't declared/loaded). This is the in-game write
-- path; the offline helper writes the same global from the file mirror.
function Sync.Set(key, value)
    local t = remoteTable(true)
    if not t then return false end
    t[key] = value
    return true
end

-- Register a consumer namespace. `spec.onRemote(key, data)` is invoked when the
-- remote mirror for `key` is (re)loaded — apply-at-login for file transport, or
-- on an explicit NotifyRemoteUpdated. Registration is idempotent.
function Sync.RegisterNamespace(key, spec)
    if type(key) ~= "string" or key == "" then return false end
    Sync._namespaces[key] = { onRemote = spec and spec.onRemote }
    return true
end

-- Fire a namespace's onRemote with its current remote data. Used at login and
-- whenever the mirror is known to have changed.
function Sync.NotifyRemoteUpdated(key)
    local reg = Sync._namespaces[key]
    if not reg or not reg.onRemote then return end
    local data = Sync.Get(key)
    if ns.SafeCall then ns:SafeCall(reg.onRemote, key, data)
    else reg.onRemote(key, data) end
end

-- Login pass: file-mirror transport applies at login (never mid-session — the
-- running client rewrites its SVs on logout, so a mid-session file write would
-- be clobbered; design constraint). Notify every registered namespace once.
function Sync.OnLogin()
    for key in pairs(Sync._namespaces) do
        Sync.NotifyRemoteUpdated(key)
    end
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

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("syncns", selfTest)
end
Config._SelfTest = selfTest
