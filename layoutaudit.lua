-- Daseeki Nexus — layoutaudit.lua
-- ---------------------------------------------------------------------------
-- GEOMETRY HARNESS (runtime half). Walks the dashboard window's visible frame
-- tree (and the Daseeki hub settings pages when shown) and records, per
-- frame / FontString / Texture, its *measurable* geometry: effective rect,
-- anchor points, effective scale, font (for FontStrings) and shown/visible
-- state. The dump lands in DaseekiNexusData.layoutAudit so the offline checker
-- (nexus-test-harness/harness/geocheck.lua) can evaluate it against a spec that
-- carries the numbers from an approved mockup.
--
-- WHY THIS FILE EXISTS
--   Build agents verify layout with headless tests that cannot see pixels, so
--   alignment defects reach the owner's screen. This makes layout MEASURABLE:
--   `/nexus debug layout` writes a numeric dump; geocheck.cmd grades it.
--
-- CONTRACT (this file owns two public grammars; keep them verbatim-stable —
-- the LAYOUT_SPEC and geocheck.lua are authored against them):
--
--   DUMP ENTRY FORMAT (DaseekiNexusData.layoutAudit)
--   ------------------------------------------------
--   DaseekiNexusData.layoutAudit = {
--     t       = <epoch seconds>,      -- when the dump was taken
--     screen  = "Characters",         -- active tab label (or root list joined)
--     roots   = { "shell.window" },   -- ids of the walked roots
--     w = <px>, h = <px>,             -- UIParent effective width/height
--     uiscale = <number>,             -- UIParent:GetEffectiveScale()
--     entries = {                     -- parents precede children; array order
--       {
--         id      = "roster.chipRow", -- STABLE id: tag > global name > path
--         otype   = "Frame",          -- GetObjectType()
--         parent  = "shell.window",   -- id of parent entry (nil for a root)
--         depth   = 2,                -- tree depth, root = 0
--         shown   = true,             -- IsShown()
--         visible = true,             -- IsVisible() (effective up the chain)
--         -- effective rect via GetRect(), rounded 0.1px, UIParent units:
--         left = 12.0, bottom = 340.0, width = 220.0, height = 24.0,
--         top  = 364.0, right = 232.0,   -- derived: top=bottom+height, right=left+width
--         scale = 1.0,                -- GetEffectiveScale()
--         points = {                  -- one per GetNumPoints(); [] if none
--           { point="TOPLEFT", relTo="shell.window",
--             relPoint="TOPLEFT", x=8.0, y=-40.0 },
--         },
--         font = { face="Fonts\\FRIZQT__.TTF", size=12.0, flags="" }, -- FontString only
--         text = "Characters",        -- FontString GetText(), <=64 chars, diagnostic
--       },
--       ...
--     },
--   }
--   Only ONE dump is retained (latest replaces prior). Every metric is
--   nil-safe: a value that a widget cannot supply is simply omitted.
--
-- ID RESOLUTION (stable across sessions in this priority order)
--   1. audit tag        ns.Audit.Tag(frame, "roster.chipRow")  -- UI files adopt over time
--   2. global name      frame:GetName()                        -- e.g. "DaseekiNexusDashboard"
--   3. derived path     "<parentId>/<ObjType><childIndex>"     -- works TODAY, untouched UI
--
-- Clean-room: this file names no third-party addon identifiers.
-- ---------------------------------------------------------------------------

local ADDON, ns = ...

----------------------------------------------------------------------
-- Audit namespace + the Tag helper UI files can adopt incrementally.
----------------------------------------------------------------------

local Audit = ns.Audit or {}
ns.Audit = Audit

-- Weak-keyed so tagging a frame never keeps it alive.
Audit._tags  = Audit._tags  or setmetatable({}, { __mode = "k" })
-- Extra roots UI files (or the hub) may register later without touching this
-- file: ns.Audit.AddRoot(frameOrGlobalName, "settings"). Optional; the dashboard
-- window and the hub are auto-discovered below regardless.
Audit._roots = Audit._roots or {}

-- Tag a frame/region with a stable id. Idempotent; last write wins.
function Audit.Tag(frame, id)
    if frame and type(id) == "string" and id ~= "" then
        Audit._tags[frame] = id
    end
    return frame
end

function Audit.GetTag(frame)
    return frame and Audit._tags[frame] or nil
end

-- Register an additional walk root. `ref` may be a frame or a global name.
-- `label` is an optional human tag echoed into the dump's screen string.
function Audit.AddRoot(ref, label)
    Audit._roots[#Audit._roots + 1] = { ref = ref, label = label }
end

----------------------------------------------------------------------
-- Numeric helpers (pure; unit-tested by the layout self-test).
----------------------------------------------------------------------

-- Round to 0.1px. nil in -> nil out so callers can chain safely.
local function r1(v)
    if type(v) ~= "number" then return nil end
    -- guard against inf/nan leaking into the dump
    if v ~= v or v == math.huge or v == -math.huge then return nil end
    return math.floor(v * 10 + 0.5) / 10
end
Audit._round1 = r1

-- Safe method call: returns nil rather than erroring when a widget lacks a
-- method (Textures have no GetText, FontStrings no GetChildren, etc.).
local function call(obj, method, ...)
    if type(obj) ~= "table" and type(obj) ~= "userdata" then return nil end
    local fn = obj[method]
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d, e = pcall(fn, obj, ...)
    if not ok then return nil end
    return a, b, c, d, e
end
Audit._call = call

----------------------------------------------------------------------
-- Core walker. PURE with respect to the WoW API surface — it touches widgets
-- only through documented reader methods, so the layout self-test can drive it
-- with a hand-built mock tree and get a real dump back.
--
--   WalkTree(root, opts) -> entriesArray
--   opts = {
--     rootId   = "shell.window",  -- id override for the root (else tag/name/derived)
--     idMap    = <table>,         -- frame -> id, shared across roots for relTo resolution
--     entries  = <array>,         -- append target, shared across roots
--     maxDepth = 30, maxEntries = 4000,
--   }
----------------------------------------------------------------------

local MAX_DEPTH   = 30
local MAX_ENTRIES = 4000
local TEXT_CAP    = 64

-- Resolve the id for a frame given its parent id and a per-parent child index.
local function resolveId(frame, parentId, obj, index, idMap)
    local existing = idMap[frame]
    if existing then return existing end
    local id = Audit._tags[frame]
    if not id then
        local name = call(frame, "GetName")
        if type(name) == "string" and name ~= "" then id = name end
    end
    if not id then
        local ot = obj or "Region"
        id = (parentId and (parentId .. "/") or "") .. ot .. tostring(index)
    end
    idMap[frame] = id
    return id
end

-- Resolve an anchor's relativeTo widget to an id/name string.
local function resolveRelTo(relTo, idMap)
    if not relTo then return nil end
    local mapped = idMap[relTo]
    if mapped then return mapped end
    local name = call(relTo, "GetName")
    if type(name) == "string" and name ~= "" then return name end
    return "?"
end

-- Build the anchor list for a widget (one entry per GetNumPoints()).
local function readPoints(frame, idMap)
    local n = call(frame, "GetNumPoints")
    if type(n) ~= "number" or n < 1 then return nil end
    local pts = {}
    for i = 1, n do
        local point, relTo, relPoint, x, y = call(frame, "GetPoint", i)
        if point then
            pts[#pts + 1] = {
                point    = point,
                relTo    = resolveRelTo(relTo, idMap),
                relPoint = relPoint,
                x        = r1(x),
                y        = r1(y),
            }
        end
    end
    if #pts == 0 then return nil end
    return pts
end

-- Read font info for a FontString.
local function readFont(frame)
    local face, size, flags = call(frame, "GetFont")
    if not face then return nil end
    return { face = face, size = r1(size), flags = flags or "" }
end

-- Emit one entry for `frame`; return its id (so children can name their parent).
local function emit(frame, parentId, depth, index, ctx)
    local obj = call(frame, "GetObjectType") or "Frame"
    local id  = resolveId(frame, parentId, obj, index, ctx.idMap)

    local left, bottom, width, height = call(frame, "GetRect")
    local entry = {
        id      = id,
        otype   = obj,
        parent  = parentId,
        depth   = depth,
        shown   = call(frame, "IsShown") and true or false,
        visible = call(frame, "IsVisible") and true or false,
        left    = r1(left),
        bottom  = r1(bottom),
        width   = r1(width),
        height  = r1(height),
        scale   = r1(call(frame, "GetEffectiveScale")),
        points  = readPoints(frame, ctx.idMap),
    }
    if entry.left and entry.height then entry.top   = r1(entry.bottom + entry.height) end
    if entry.left and entry.width  then entry.right = r1(entry.left + entry.width) end

    if obj == "FontString" then
        entry.font = readFont(frame)
        local txt = call(frame, "GetText")
        if type(txt) == "string" and txt ~= "" then
            entry.text = (#txt > TEXT_CAP) and (txt:sub(1, TEXT_CAP) .. "…") or txt
        end
    end

    ctx.entries[#ctx.entries + 1] = entry
    return id
end

-- Depth-first walk: emit self, then regions (textures/fontstrings), then child
-- frames. Regions precede children so a panel's labels sit next to it in order.
local function walk(frame, parentId, depth, index, ctx)
    if not frame or ctx.seen[frame] then return end
    if depth > ctx.maxDepth then return end
    if #ctx.entries >= ctx.maxEntries then return end
    ctx.seen[frame] = true

    local id = emit(frame, parentId, depth, index, ctx)

    -- Regions (FontStrings + Textures) — no further descent; they are leaves.
    local regions = { call(frame, "GetRegions") }
    for i = 1, #regions do
        local rgn = regions[i]
        if rgn and not ctx.seen[rgn] then
            if #ctx.entries >= ctx.maxEntries then break end
            ctx.seen[rgn] = true
            emit(rgn, id, depth + 1, i, ctx)
        end
    end

    -- Child frames — recurse.
    local children = { call(frame, "GetChildren") }
    for i = 1, #children do
        if #ctx.entries >= ctx.maxEntries then break end
        walk(children[i], id, depth + 1, i, ctx)
    end
end

-- Public: walk one root, appending into a shared context. Returns the entries.
function Audit.WalkTree(root, opts)
    opts = opts or {}
    local ctx = {
        idMap      = opts.idMap or {},
        entries    = opts.entries or {},
        seen       = opts.seen or {},
        maxDepth   = opts.maxDepth or MAX_DEPTH,
        maxEntries = opts.maxEntries or MAX_ENTRIES,
    }
    -- Seed the root's id first so its own anchors + children resolve against it.
    if root then
        if opts.rootId then ctx.idMap[root] = opts.rootId end
        walk(root, nil, 0, 1, ctx)
    end
    return ctx.entries, ctx.idMap
end

----------------------------------------------------------------------
-- Root discovery + the full dump.
----------------------------------------------------------------------

local function frameFromRef(ref)
    if type(ref) == "string" then return _G[ref] end
    return ref
end

-- Gather the roots to walk: the dashboard window (if shown), the hub settings
-- window (if shown), plus any AddRoot() registrations. Each -> {frame,id,label}.
local function gatherRoots()
    local out = {}
    local seenFrame = {}

    local function add(frame, id, label)
        if frame and not seenFrame[frame] and call(frame, "IsShown") then
            seenFrame[frame] = true
            out[#out + 1] = { frame = frame, id = id, label = label }
        end
    end

    -- Dashboard window (global name is stable: DaseekiNexusDashboard).
    add(_G.DaseekiNexusDashboard, "shell.window", "Dashboard")
    -- Daseeki hub settings window, when open on any page.
    add(_G.DaseekiSuiteHub, "settings.hub", "Settings")

    for i = 1, #Audit._roots do
        local r = Audit._roots[i]
        add(frameFromRef(r.ref), (type(r.ref) == "string" and r.ref) or ("root" .. i), r.label)
    end
    return out
end

-- Best-effort active-screen label: the dashboard's current tab, if resolvable.
local function activeScreenLabel()
    local d = ns.Dashboard
    if d and d.activeTabId then
        -- Prefer the human label from the tab slots when available.
        return tostring(d.activeTabId)
    end
    return nil
end

-- Produce and store the dump. Returns the dump table + entry count.
function Audit.Dump(screenLabel)
    local roots = gatherRoots()
    local entries, idMap = {}, {}
    local seen = {}
    local rootIds = {}

    for i = 1, #roots do
        local r = roots[i]
        Audit.WalkTree(r.frame, {
            rootId  = r.id,
            entries = entries,
            idMap   = idMap,
            seen    = seen,
        })
        rootIds[#rootIds + 1] = r.id
    end

    local up = _G.UIParent
    local uw, uh = call(up, "GetRect")
    -- GetRect on UIParent returns left,bottom,width,height; width/height wanted.
    local _, _, upW, upH = call(up, "GetRect")

    local dump = {
        t       = (time and time()) or (os and os.time and os.time()) or 0,
        screen  = screenLabel or activeScreenLabel() or (rootIds[1] or "unknown"),
        roots   = rootIds,
        w       = r1(upW),
        h       = r1(upH),
        uiscale = r1(call(up, "GetEffectiveScale")),
        entries = entries,
    }

    -- Additive key on the owner-owned SavedVariables; latest dump only.
    _G.DaseekiNexusData = _G.DaseekiNexusData or {}
    _G.DaseekiNexusData.layoutAudit = dump
    return dump, #entries
end

----------------------------------------------------------------------
-- Debug command: /nexus debug layout [screen]
--   no arg      -> dump whatever dashboard/hub windows are currently shown.
--   <screen>    -> switch the dashboard to that tab, wait one frame, then dump.
----------------------------------------------------------------------

-- Map a user-typed screen token to a tab id the shell understands.
local SCREEN_ALIASES = {
    characters = "characters", chars = "characters", roster = "characters",
    timers     = "timers",     timer  = "timers",
    instances  = "instances",  inst   = "instances", lockouts = "instances",
    help       = "help",
}

local function doDump(screenLabel)
    local dump, n = Audit.Dump(screenLabel)
    ns:Print(string.format("layout: dumped %d entries for screen '%s' (%d root(s)) -> DaseekiNexusData.layoutAudit. /reload + logout, then geocheck.cmd.",
        n, tostring(dump.screen), #dump.roots))
end

local function layoutCommand(args)
    local token = (args or ""):match("^%s*(%S*)")
    token = (token or ""):lower()

    if token == "" then
        doDump(nil)
        return
    end

    local tabId = SCREEN_ALIASES[token] or token
    local d = ns.Dashboard
    if d and d.Show and d.SelectTab then
        d.Show(tabId)            -- ensure visible + select
        d.SelectTab(tabId)
        -- Wait one frame so anchors settle, then dump under the tab's label.
        if _G.C_Timer and C_Timer.After then
            C_Timer.After(0, function() doDump(tabId) end)
        else
            doDump(tabId)
        end
    else
        ns:Print("layout: dashboard shell not available; dumping current frames.")
        doDump(token)
    end
end

if ns.RegisterDebugCommand then
    ns:RegisterDebugCommand("layout", layoutCommand)
end

----------------------------------------------------------------------
-- Self-test (runs under the headless harness). Builds a MOCK frame tree with
-- controllable geometry — NOT via CreateFrame, whose harness mock returns
-- no-op chainables — drives the real WalkTree over it, and asserts the dump
-- shape: id resolution (tag > name > derived), 0.1px rounding, anchor capture,
-- font capture, and parents-before-children ordering.
----------------------------------------------------------------------

local function buildMockTree()
    -- A minimal widget mock: fields carry the truth; methods read them.
    local function W(spec)
        spec = spec or {}
        spec._regions  = spec._regions  or {}
        spec._children = spec._children or {}
        function spec:GetObjectType() return self._otype or "Frame" end
        function spec:GetName() return self._name end
        function spec:IsShown() return self._shown ~= false end
        function spec:IsVisible() return self._visible ~= false end
        function spec:GetRect() return self._l, self._b, self._w, self._h end
        function spec:GetEffectiveScale() return self._scale or 1 end
        function spec:GetNumPoints() return self._points and #self._points or 0 end
        function spec:GetPoint(i)
            local p = self._points and self._points[i]
            if not p then return nil end
            return p[1], p[2], p[3], p[4], p[5]
        end
        function spec:GetRegions() return unpack(self._regions) end
        function spec:GetChildren() return unpack(self._children) end
        function spec:GetFont() if self._font then return self._font[1], self._font[2], self._font[3] end end
        function spec:GetText() return self._text end
        return spec
    end

    local win = W{ _name = "DaseekiNexusDashboard", _l = 100, _b = 200, _w = 400, _h = 300, _scale = 1 }
    -- Tagged chip row anchored to the window; fractional rect exercises rounding.
    local chipRow = W{ _otype = "Frame", _l = 112.04, _b = 460.06, _w = 220, _h = 24,
        _points = { { "TOPLEFT", win, "TOPLEFT", 12.04, -40.02 } } }
    -- A label FontString on the chip row with a known font.
    local label = W{ _otype = "FontString", _l = 116, _b = 470, _w = 60, _h = 14,
        _font = { "Fonts\\FRIZQT__.TTF", 12.4, "" }, _text = "All" }
    chipRow._regions = { label }
    win._children = { chipRow }
    return win, chipRow, label
end

local function selfTest(verbose)
    local pass, fails = true, {}
    local function check(cond, msg)
        if not cond then pass = false; fails[#fails + 1] = msg end
    end

    local win, chipRow, label = buildMockTree()
    -- Tag the chip row so we can assert tag beats derived-path id.
    Audit.Tag(chipRow, "roster.chipRow")

    local entries = Audit.WalkTree(win, { rootId = "shell.window" })

    check(#entries == 3, "expected 3 entries, got " .. #entries)

    local byId = {}
    for _, e in ipairs(entries) do byId[e.id] = e end

    -- Root id honoured; global-name fallback would also give a name, but rootId wins.
    check(byId["shell.window"] ~= nil, "root id 'shell.window' missing")
    -- Tag beats derived path.
    check(byId["roster.chipRow"] ~= nil, "tagged id 'roster.chipRow' missing")

    local cr = byId["roster.chipRow"]
    if cr then
        check(cr.parent == "shell.window", "chipRow parent should be shell.window, got " .. tostring(cr.parent))
        check(cr.depth == 1, "chipRow depth should be 1, got " .. tostring(cr.depth))
        check(cr.left == 112.0, "chipRow left should round to 112.0, got " .. tostring(cr.left))
        check(cr.top == r1(460.06 + 24), "chipRow top should be bottom+height rounded, got " .. tostring(cr.top))
        check(cr.right == r1(112.04 + 220), "chipRow right derived wrong: " .. tostring(cr.right))
        check(cr.points and cr.points[1], "chipRow anchor missing")
        if cr.points and cr.points[1] then
            local p = cr.points[1]
            check(p.point == "TOPLEFT", "anchor point wrong: " .. tostring(p.point))
            check(p.relTo == "shell.window", "anchor relTo should resolve to shell.window, got " .. tostring(p.relTo))
            check(p.x == 12.0, "anchor x should round to 12.0, got " .. tostring(p.x))
            check(p.y == -40.0, "anchor y should round to -40.0, got " .. tostring(p.y))
        end
    end

    -- FontString: font captured, size rounded, id derived from parent path.
    local labelEntry
    for _, e in ipairs(entries) do
        if e.otype == "FontString" then labelEntry = e end
    end
    check(labelEntry ~= nil, "FontString entry missing")
    if labelEntry then
        check(labelEntry.parent == "roster.chipRow", "label parent should be roster.chipRow, got " .. tostring(labelEntry.parent))
        check(labelEntry.id == "roster.chipRow/FontString1", "derived id wrong: " .. tostring(labelEntry.id))
        check(labelEntry.font and labelEntry.font.face == "Fonts\\FRIZQT__.TTF", "font face missing")
        check(labelEntry.font and labelEntry.font.size == 12.4, "font size should round to 12.4, got " .. tostring(labelEntry.font and labelEntry.font.size))
        check(labelEntry.text == "All", "font text missing: " .. tostring(labelEntry.text))
    end

    -- Ordering: every parent precedes its children.
    local seenIds = {}
    local ordered = true
    for _, e in ipairs(entries) do
        if e.parent and not seenIds[e.parent] then ordered = false end
        seenIds[e.id] = true
    end
    check(ordered, "entries not in parents-before-children order")

    if verbose then
        if pass then
            ns:Print("selftest layout: PASS (walker: id/round/anchor/font/order)")
        else
            for _, m in ipairs(fails) do ns:Print("selftest layout FAIL: " .. m) end
        end
    end
    return pass
end

if ns.RegisterSelfTest then
    ns:RegisterSelfTest("layout", selfTest)
end

-- Expose the mock builder + self-test so the harness geocheck cross-check can
-- reuse the exact same walker output as its dump fixture.
Audit._buildMockTree = buildMockTree
Audit._selfTest      = selfTest
