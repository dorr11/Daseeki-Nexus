-- Daseeki Nexus — pins.lua
-- Felwood songflower / tuber node pins on the world map and minimap, driven by
-- Timers.NODES (16 fixed nodes) + the NODE_UPDATED callback.
--
-- Map-pin strategy (decision): own minimal placement, NOT a vendored map lib.
-- The node set is fixed (10 flowers + 6 tubers on one zone, uiMap 1448), so a
-- self-contained C_Map placement is smaller than vendoring HereBeDragons +
-- CallbackHandler and adds no cross-agent toc/lib merge surface.
--   World-map pins use exact C_Map canvas coordinates (already correct).
--   Minimap pins now use a PROPER world projection (R2-c): each node's fixed
--   normalized map position is converted to continent/world yards ONCE via
--   C_Map.GetWorldPosFromMapPos; the player's world position is converted each
--   refresh; the world-space delta is scaled to minimap pixels by the live
--   zoom radius. This is correct at every zoom level (replacing the old planar
--   normalized-scale approximation) and handles a rotating minimap via
--   GetPlayerFacing. Projection math is fresh HereBeDragons-style geometry, no
--   third-party code.
--
-- PIN PRESENTATION (ROUND-28, two owner notes on one Felwood screenshot):
--   1. "the timers are unreadable" — the world-map countdown was a bare
--      FontString below the icon, sitting straight on the map art. It is now a
--      dark suite-dressed CHIP ABOVE the icon, and its ink comes from the timers
--      dock's own songflower colour rule (Dashboard.SongflowerCountdownToken) via
--      Pins.TimerToken — called, never copied, so map and dock cannot drift.
--   2. "the pins are generic diamond markers" — the diamond backing is gone
--      (BRAND_SPEC §5 banned repeated diamonds anyway) and each pin now draws the
--      GAME's own art for its node, resolved at runtime through ui_shell's shared
--      icon resolvers. Three pin kinds exist and all three are covered: flower
--      (10 nodes), tuber (6), dragon (4).
--
-- ROUND-29 (owner screenshot of the Felwood MINIMAP): the ROUND-28 chip landed on
-- the world map ONLY — minimap pins had the real icon and the state ring but no
-- countdown. The chip now renders on minimap pins too, on the same model at
-- derived (smaller) metrics, for every pin kind the minimap draws. See the CHIP
-- GEOMETRY block below for the scaling rule and the overflow decision.
--
-- Clean-room build: functional reimplementation from spec; no third-party code.

local ADDON, ns = ...

local UI = DaseekiUI

local Pins = {}
ns.Pins = Pins

local FELWOOD_MAP = 1448
local WHITE = "Interface\\Buttons\\WHITE8X8"

----------------------------------------------------------------------
-- Node kind ART (ROUND-28, owner: "the pins are generic diamond markers — I want
-- the real game icons").
--
-- The three KIND_ICON paths below were HAND-PICKED guesses at "a herb-ish icon",
-- which is exactly the class of error ui_shell already retired for buff art
-- ("buff icons arent correct"). They are demoted to FALLBACKS. The icon a pin
-- actually draws is now the game's OWN art for that node, resolved at runtime
-- through the shared resolvers ui_shell already owns and caches:
--
--   flower  -> Dashboard.AuraIcon(AURA_META slot 4 = Songflower Serenade, 15366).
--              A songflower is a clickable world object with no item, so the buff
--              it grants is the art the game itself shows the player for it.
--   tuber   -> Dashboard.ItemIcon(11951)  Whipper Root Tuber
--   dragon  -> Dashboard.ItemIcon(11952)  Night Dragon's Breath
--
-- The two item IDs are FACTS recorded in the Room-1 spec (NWB_BEHAVIOR_SPEC.md
-- §6.3, "11951 = Whipper Root Tuber / 11952 = Night Dragon's Breath") — the same
-- IDs timers.lua already matches loot lines on. The spec does NOT record which
-- textures the reference addon draws, and no third-party source was read: these
-- are the game's own assets for the game's own objects.
--
-- Catalog-verified for 11509 (wow-api-catalog 1.15.9.68808): C_Spell.GetSpellTexture,
-- C_Item.GetItemIconByID, plus the legacy GetSpellTexture / GetItemIcon globals
-- the resolvers fall back to.
----------------------------------------------------------------------

-- Static fallbacks: Blizzard built-ins, used only when the client cannot resolve
-- the real art (a missing path renders blank, never an error).
local KIND_ICON = {
    flower = "Interface\\Icons\\INV_Misc_Herb_Fellotus",
    tuber  = "Interface\\Icons\\INV_Misc_Food_59",
    dragon = "Interface\\Icons\\INV_Misc_Herb_10",
}

-- Blizzard's built-in unknown marker. Dashboard.AuraIcon returns THIS when a spell
-- will not resolve, and our own fallback art is a better answer than a question
-- mark on the map — so the sentinel is named here to be compared against. (ItemIcon
-- takes an explicit fallback, so only the spell path needs the comparison.)
local QUESTION_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"

local FLOWER_AURA_SLOT = 4                                  -- Dashboard.AURA_META slot: Songflower Serenade
local KIND_ITEM = { tuber = 11951, dragon = 11952 }         -- NWB_BEHAVIOR_SPEC §6.3

-- Resolved art per kind. A SUCCESSFUL resolve is cached forever (the node set is
-- fixed and item/spell art never changes mid-session); a FAILED one is not, so a
-- later refresh retries once the client has the item/spell cached — same policy as
-- Dashboard.AuraIcon/ItemIcon themselves.
local _kindIcon = {}
local function kindIcon(kind)
    local cached = _kindIcon[kind]
    if cached then return cached end
    local D = ns.Dashboard
    local tex
    if D then
        local itemID = KIND_ITEM[kind]
        if itemID and D.ItemIcon then
            tex = D.ItemIcon(itemID, KIND_ICON[kind])
        elseif kind == "flower" and D.AuraIcon then
            tex = D.AuraIcon(FLOWER_AURA_SLOT)
            if tex == QUESTION_ICON then tex = nil end
        end
    end
    if tex and tex ~= KIND_ICON[kind] then _kindIcon[kind] = tex; return tex end
    return KIND_ICON[kind]
end
-- Exposed for the headless suite (the in-game consumers below sit under the
-- DaseekiUI guard, so the self-test cannot reach a file-local).
Pins._KindIcon = kindIcon

local function fmtCountdown(sec)
    sec = math.max(0, math.floor(sec + 0.5))
    if sec >= 60 then
        return string.format("%d:%02d", math.floor(sec / 60), sec % 60)
    end
    return sec .. "s"
end

----------------------------------------------------------------------
-- World-pin TIMER CHIP content (pure; above the DaseekiUI guard so the headless
-- suite covers it).
--
-- ROUND-28 (owner screenshot of Felwood): the countdown used to render as bare
-- text under the icon, unreadable over map art. It now renders in a dark chip
-- ABOVE the icon — and its INK is not a pin-local invention.
--
-- COLOUR RULE — ONE SOURCE OF TRUTH. The Nexus timers dock already owns the
-- owner's ROUND-27 songflower ramp (ui_timersdock.lua):
--     Dashboard.SongflowerCountdownToken(remaining)  ->  "ok" / "warn" / "danger"
-- The pin calls that function READ-ONLY rather than restating its two thresholds,
-- so the map chip and the dock cell can never drift apart. The thresholds
-- themselves live in exactly one place and are deliberately NOT repeated here.
--
-- States that do not carry a countdown (up / stale / unknown / unrecognised)
-- return nil for BOTH text and token — the caller draws NO CHIP AT ALL, which is
-- the pre-existing behaviour (the old code set the label to "") preserved exactly.
----------------------------------------------------------------------

-- Chip text, or nil for "no chip". `expired` counts UP from the respawn, so it
-- reads as a negative counter; abs() accepts either sign convention, matching
-- Dashboard.SongflowerCellContent.
function Pins.TimerText(st)
    local state = st and st.state
    if state == "down" then return fmtCountdown(st.remaining or 0) end
    if state == "expired" then return "-" .. fmtCountdown(math.abs(st.remaining or 0)) end
    return nil
end

-- Chip ink token, or nil for "no chip".
function Pins.TimerToken(st)
    local state = st and st.state
    if state == "down" then
        local D = ns.Dashboard
        if D and D.SongflowerCountdownToken then
            return D.SongflowerCountdownToken(st.remaining or 0)
        end
        -- Pure layer without the dock loaded (never the case in a real client,
        -- where the .toc loads ui_timersdock.lua before this file). Neutral
        -- caution; restating the ramp here is precisely what this indirection
        -- exists to prevent.
        return "warn"
    end
    -- The expired band is a "came back N ago" counter, not a countdown, so the
    -- ROUND-27 ramp does not apply to it — it keeps the pin's established ok/green.
    if state == "expired" then return "ok" end
    return nil
end

----------------------------------------------------------------------
-- CHIP GEOMETRY + CONTENT (pure; above the DaseekiUI guard so the headless suite
-- covers it).
--
-- ROUND-29 (owner screenshot of the Felwood MINIMAP): ROUND-28 gave the countdown
-- chip to the WORLD MAP only — minimap pins drew the real icon and the state ring
-- but carried no timer at all, deliberately. The owner wants the timer there too,
-- so the same chip now renders on the minimap, scaled for the space.
--
-- ONE MODEL, TWO SIZES. The minimap chip is NOT a second design with its own
-- numbers: every minimap value below is the world value put through the single
-- ratio MINI_CHIP_SCALE. Retune the world chip and the minimap chip follows it,
-- which is the whole reason no fresh magic numbers appear here.
--
-- OVERFLOW — DECISION: the minimap chip is NOT clipped to the minimap circle.
--   * Minimap does not clip its children in the first place; enforcing a clip
--     would mean wrapping the pins in a masked/scroll container, which would clip
--     the ICONS and RINGS too — a much larger change to fix a cosmetic edge case.
--   * A clipped chip renders as truncated numerals, which is precisely the
--     unreadability the owner reported in ROUND-28. Half a timer is worse than a
--     timer poking a few pixels past the rim.
--   * Overflowing badges at the rim is what every mainstream minimap-pin addon
--     already does, so it reads as normal rather than broken.
-- The one case that WOULD look broken — a pin at the very top of the minimap
-- throwing its chip clear off the minimap and over the zone text — is handled by
-- position instead of by clipping: Pins.ChipSide flips the chip BELOW the pin in
-- that band. What remains is a few pixels of deliberate spill.
----------------------------------------------------------------------

local CHIP_PAD_X, CHIP_PAD_Y = 4, 2   -- text padding inside the chip
local CHIP_GAP               = 3      -- gap between the chip and the icon
local CHIP_MIN_W, CHIP_MIN_H = 16, 11 -- floor, so a "5s" chip is not a sliver
local CHIP_FILL_ALPHA        = 0.94
local CHIP_EDGE_ALPHA        = 0.9
local CHIP_LEVEL_LIFT        = 5      -- frame levels above the pin

-- The single ratio the minimap chip is derived through.
local MINI_CHIP_SCALE = 0.8
-- Font floor: the options timer-font slider's own lower bound (6-20pt). The scaled
-- minimap size is clamped to THAT rather than to a freshly invented minimum.
local CHIP_FONT_MIN = 6

local function miniScale(v)
    local s = math.floor(v * MINI_CHIP_SCALE + 0.5)
    if s < 1 then s = 1 end
    return s
end

-- Read-only metric tables, one per surface. Fields are the same names on both, so
-- every consumer below is surface-agnostic.
local CHIP_METRICS = {
    world = {
        padX = CHIP_PAD_X, padY = CHIP_PAD_Y, gap = CHIP_GAP,
        minW = CHIP_MIN_W, minH = CHIP_MIN_H,
    },
    minimap = {
        padX = miniScale(CHIP_PAD_X), padY = miniScale(CHIP_PAD_Y), gap = miniScale(CHIP_GAP),
        minW = miniScale(CHIP_MIN_W), minH = miniScale(CHIP_MIN_H),
    },
}

-- Chip metrics for a surface ("world" | "minimap"). Unknown surfaces get the world
-- chip, which is the conservative answer (bigger, always legible).
function Pins.ChipMetrics(surface)
    return CHIP_METRICS[surface] or CHIP_METRICS.world
end

-- Chip font size in points. The world chip uses the user's configured size
-- verbatim; the minimap chip uses that same size through the ratio, never below
-- the slider's own floor — so the minimap timer still tracks the slider.
function Pins.ChipFontSize(surface, worldPt)
    worldPt = tonumber(worldPt) or 10
    if surface ~= "minimap" then return worldPt end
    local pt = math.floor(worldPt * MINI_CHIP_SCALE + 0.5)
    if pt < CHIP_FONT_MIN then pt = CHIP_FONT_MIN end
    return pt
end

-- Which side of a MINIMAP pin its chip sits on. Above by default (matching the
-- world map); below when an above-chip would leave the minimap entirely.
--   pinTopY  offset of the pin's TOP edge from the minimap centre (+ = up)
--   radius   the minimap's radius in pixels
function Pins.ChipSide(pinTopY, chipH, gap, radius)
    pinTopY = tonumber(pinTopY) or 0
    chipH   = tonumber(chipH) or 0
    gap     = tonumber(gap) or 0
    radius  = tonumber(radius) or 0
    if pinTopY + gap + chipH > radius then return "below" end
    return "above"
end

-- Chip CONTENT for a surface. The `surface` argument deliberately does NOT change
-- the answer: a minimap chip and a world chip for the same node state must read
-- the same and ink the same — only their GEOMETRY differs. It exists so the
-- self-test can state the dock-agreement gate once PER SURFACE, and so any future
-- attempt to give one surface its own colour rule has to be a visible edit here
-- rather than a quiet divergence in a refresh loop.
function Pins.ChipContent(surface, st)
    return Pins.TimerText(st), Pins.TimerToken(st)
end

----------------------------------------------------------------------
-- Pure minimap projection (registered ABOVE the DaseekiUI guard so the
-- fixture self-test runs headless).
--
-- WoW world/continent coordinates (as returned by GetWorldPosFromMapPos):
--   worldX increases toward NORTH, worldY increases toward WEST.
-- The north-up minimap has +x = EAST (right), +y = NORTH (up). So for a node
-- relative to the player:
--   eastPixels  = (playerWorldY - nodeWorldY) * pixelsPerYard   (west is -x)
--   northPixels = (nodeWorldX  - playerWorldX) * pixelsPerYard   (north is +y)
-- A rotating minimap puts the player's facing at the top: rotate the (E,N)
-- vector by GetPlayerFacing (radians, CCW from north).
----------------------------------------------------------------------

local MINIMAP_YARDS_OUTDOOR = {
    [0] = 466 + 2/3, [1] = 400, [2] = 333 + 1/3, [3] = 266 + 2/3, [4] = 200, [5] = 133 + 1/3,
}
local MINIMAP_YARDS_INDOOR = {
    [0] = 300, [1] = 240, [2] = 180, [3] = 120, [4] = 80, [5] = 50,
}

-- world coords -> minimap pixel offset (dx east+, dy north+). Pure; the caller
-- supplies pixelsPerYard (from the live minimap zoom) and an optional facing.
function Pins._ProjectMinimap(pWX, pWY, nWX, nWY, pixelsPerYard, facing)
    local E = (pWY - nWY) * pixelsPerYard   -- east pixels (+right)
    local N = (nWX - pWX) * pixelsPerYard   -- north pixels (+up)
    facing = facing or 0
    if facing ~= 0 then
        local cs, sn = math.cos(facing), math.sin(facing)
        E, N = E * cs + N * sn, -E * sn + N * cs
    end
    return E, N
end

-- Self-test: pure geometry helpers + minimap projection fixture (headless).
ns:RegisterSelfTest("pins", function(verbose)
    local pass = true
    local function check(c, m) if not c then pass = false; if verbose then ns:Print("  FAIL: " .. m) end end end
    check(fmtCountdown(90) == "1:30", "fmtCountdown 90 -> 1:30")
    check(fmtCountdown(5) == "5s", "fmtCountdown 5 -> 5s")
    check(KIND_ICON.flower ~= nil and KIND_ICON.tuber ~= nil and KIND_ICON.dragon ~= nil,
        "kind icons present (flower/tuber/dragon)")

    -- Projection: fixture world coords -> expected minimap offsets (north-up).
    -- player @ (0,0); node 100yd north (worldX+100) and 100yd east (worldY-100),
    -- at 0.5 px/yd -> (+50 right, +50 up).
    local dx, dy = Pins._ProjectMinimap(0, 0, 100, -100, 0.5, 0)
    check(math.abs(dx - 50) < 1e-6 and math.abs(dy - 50) < 1e-6, "projection north-up fixture")
    -- Axis sanity: node due east -> +x only; node due north -> +y only.
    local ex, ey = Pins._ProjectMinimap(0, 0, 0, -100, 1, 0)
    check(ex > 0 and math.abs(ey) < 1e-6, "east node -> +x")
    local nx, ny = Pins._ProjectMinimap(0, 0, 100, 0, 1, 0)
    check(ny > 0 and math.abs(nx) < 1e-6, "north node -> +y")
    -- Rotation: facing 90deg (pi/2) rotates the (E,N)=(50,50) vector to (50,-50).
    local rx, ry = Pins._ProjectMinimap(0, 0, 100, -100, 0.5, math.pi / 2)
    check(math.abs(rx - 50) < 1e-4 and math.abs(ry + 50) < 1e-4, "projection rotated 90deg")

    ------------------------------------------------------------------
    -- ROUND-28: the map chip's INK IS THE DOCK'S INK.
    -- This is the whole point of the indirection — if anyone ever re-states the
    -- ROUND-27 ramp inside pins.lua, or moves the dock's boundaries without the
    -- pin following, these comparisons break. They assert AGREEMENT, deriving the
    -- expected value from the dock's own function rather than hardcoding it.
    ------------------------------------------------------------------
    local D = ns.Dashboard
    check(D and type(D.SongflowerCountdownToken) == "function",
        "dock colour rule reachable (ui_timersdock loads before pins.lua)")
    if D and type(D.SongflowerCountdownToken) == "function" then
        local sweep = { 0, 1, 59, 60, 299, 300, 301, 599, 899, 900, 901, 1499, 1500, 3600 }
        for _, rem in ipairs(sweep) do
            check(Pins.TimerToken({ state = "down", remaining = rem })
                    == D.SongflowerCountdownToken(rem),
                "pin ink == dock ink @ " .. rem .. "s remaining")
        end
        -- And the ramp the owner actually stated, read THROUGH the pin surface, so
        -- the agreement above cannot be trivially satisfied by two matching bugs.
        check(Pins.TimerToken({ state = "down", remaining = 299 }) == "ok",   "<5min  -> green")
        check(Pins.TimerToken({ state = "down", remaining = 300 }) == "warn", "5min   -> yellow (inclusive-below)")
        check(Pins.TimerToken({ state = "down", remaining = 899 }) == "warn", "<15min -> yellow")
        check(Pins.TimerToken({ state = "down", remaining = 900 }) == "danger","15min  -> red (inclusive-below)")

        --------------------------------------------------------------
        -- ROUND-29: THE AGREEMENT GATE COVERS THE MINIMAP CHIP TOO.
        -- The minimap chip is a second RENDER of the same content, so the
        -- dock-ink agreement above has to hold for it as well. These go through
        -- Pins.ChipContent(surface, ...) — the exact call BOTH refresh loops make
        -- — so a surface that ever grew its own colour rule breaks here.
        --------------------------------------------------------------
        for _, surface in ipairs({ "world", "minimap" }) do
            for _, rem in ipairs(sweep) do
                local text, token = Pins.ChipContent(surface, { state = "down", remaining = rem })
                check(token == D.SongflowerCountdownToken(rem),
                    surface .. " chip ink == dock ink @ " .. rem .. "s remaining")
                check(text == Pins.TimerText({ state = "down", remaining = rem }),
                    surface .. " chip text == the shared countdown text @ " .. rem .. "s")
            end
        end
        -- ...and the two surfaces cannot disagree with EACH OTHER either: same
        -- node state, same numerals, same ink, on the map and on the minimap.
        for _, rem in ipairs(sweep) do
            local wText, wTok = Pins.ChipContent("world",   { state = "down", remaining = rem })
            local mText, mTok = Pins.ChipContent("minimap", { state = "down", remaining = rem })
            check(wText == mText and wTok == mTok,
                "world and minimap chips agree @ " .. rem .. "s remaining")
        end
        local eW, ekW = Pins.ChipContent("world",   { state = "expired", remaining = -125 })
        local eM, ekM = Pins.ChipContent("minimap", { state = "expired", remaining = -125 })
        check(eW == eM and ekW == ekM and ekM == "ok", "expired chip agrees across surfaces (green)")
    end

    -- Chip text + the no-chip contract (unchanged from the pre-chip label rules:
    -- only down and expired ever carried a countdown).
    check(Pins.TimerText({ state = "down", remaining = 90 }) == "1:30", "down chip reads M:SS")
    check(Pins.TimerText({ state = "down", remaining = 5 }) == "5s", "sub-minute chip reads Ns")
    check(Pins.TimerText({ state = "expired", remaining = -125 }) == "-2:05", "expired chip reads -M:SS")
    check(Pins.TimerText({ state = "expired", remaining = 125 }) == "-2:05", "expired chip accepts either sign")
    check(Pins.TimerToken({ state = "expired", remaining = -125 }) == "ok", "expired chip stays green")
    for _, s in ipairs({ "up", "stale", "unknown", "brand-new-state" }) do
        check(Pins.TimerText({ state = s }) == nil, s .. " -> no chip (text)")
        check(Pins.TimerToken({ state = s }) == nil, s .. " -> no chip (ink)")
        -- ROUND-29: the no-chip contract is per SURFACE — a state that draws no
        -- world chip must draw no minimap chip either (nil text => setChipText
        -- hides the frame outright on both).
        for _, surface in ipairs({ "world", "minimap" }) do
            local text, token = Pins.ChipContent(surface, { state = s })
            check(text == nil and token == nil, s .. " -> no " .. surface .. " chip")
        end
    end
    check(Pins.TimerText(nil) == nil and Pins.TimerToken(nil) == nil, "nil state -> no chip")
    do
        local nText, nTok = Pins.ChipContent("minimap", nil)
        check(nText == nil and nTok == nil, "nil state -> no minimap chip")
    end

    ------------------------------------------------------------------
    -- ROUND-29: minimap chip GEOMETRY — derived from the world chip, not invented.
    -- Every assertion is RELATIVE (smaller than the world chip, still usable),
    -- so retuning the world chip or the ratio keeps the suite honest instead of
    -- pinning a number that would have to be edited in two places.
    ------------------------------------------------------------------
    local CW, CM = Pins.ChipMetrics("world"), Pins.ChipMetrics("minimap")
    check(type(CW) == "table" and type(CM) == "table", "chip metrics exist for both surfaces")
    check(Pins.ChipMetrics("nonsense") == CW, "unknown surface falls back to the world chip")
    check(Pins.ChipMetrics(nil) == CW, "nil surface falls back to the world chip")
    for _, k in ipairs({ "padX", "padY", "gap", "minW", "minH" }) do
        check(type(CM[k]) == "number" and CM[k] >= 1, "minimap chip " .. k .. " is a usable number")
        check(type(CW[k]) == "number" and CW[k] >= 1, "world chip " .. k .. " is a usable number")
        check(CM[k] <= CW[k], "minimap chip " .. k .. " never exceeds the world chip's " .. k)
    end
    check(CM.padX < CW.padX and CM.minW < CW.minW and CM.minH < CW.minH,
        "the minimap chip is genuinely smaller (padding + floor box)")

    -- Chip FONT: world verbatim, minimap scaled, never below the options slider's
    -- own 6pt floor, and still tracking the slider across its range.
    check(Pins.ChipFontSize("world", 14) == 14, "world chip uses the configured font size verbatim")
    check(Pins.ChipFontSize("minimap", 14) < 14, "minimap chip font is smaller than the world's")
    check(Pins.ChipFontSize("minimap", 6) == 6, "minimap chip font never drops below the 6pt slider floor")
    check(Pins.ChipFontSize("minimap", 20) > Pins.ChipFontSize("minimap", 10),
        "minimap chip font still tracks the slider")
    check(Pins.ChipFontSize("minimap", nil) == Pins.ChipFontSize("minimap", 10),
        "minimap chip font defaults from the world default (10pt)")
    check(Pins.ChipFontSize("minimap", "bogus") == Pins.ChipFontSize("minimap", 10),
        "minimap chip font survives a junk setting")

    -- Chip SIDE (the overflow decision: never clipped, flipped instead). A pin at
    -- the top of the minimap would throw an above-chip clear off the minimap, so
    -- the chip goes below it there; everywhere else it sits above, as on the map.
    do
        local R, H, G = 70, CM.minH, CM.gap
        check(Pins.ChipSide(0, H, G, R) == "above", "pin at the centre -> chip above")
        check(Pins.ChipSide(-R + 4, H, G, R) == "above", "pin near the bottom rim -> chip above")
        check(Pins.ChipSide(R - 1, H, G, R) == "below", "pin at the top rim -> chip flips below")
        check(Pins.ChipSide(R - G - H, H, G, R) == "above", "a chip that exactly fits stays above")
        check(Pins.ChipSide(R - G - H + 1, H, G, R) == "below", "one pixel past the fit flips it below")
        check(Pins.ChipSide(nil, nil, nil, R) == "above", "junk geometry degrades to the map's own side")
    end

    ------------------------------------------------------------------
    -- ROUND-28: pin ART. This asserts the CONTRACT, not a fixed value — in a live
    -- client the resolvers hand back the real fileID and the fallback is never
    -- reached, so pinning the fallback path would turn /nexus selftest red in
    -- exactly the situation where the feature is working. What must hold
    -- everywhere: every kind yields SOMETHING drawable, and never the question
    -- mark. The equal-to-fallback case is asserted only when the client offers no
    -- lookup API at all, which is precisely the headless harness.
    ------------------------------------------------------------------
    check(type(Pins._KindIcon) == "function", "kind-icon resolver exposed")
    if type(Pins._KindIcon) == "function" then
        local canResolve = (C_Spell and C_Spell.GetSpellTexture) or GetSpellTexture
                        or (C_Item and C_Item.GetItemIconByID) or GetItemIcon
        for _, k in ipairs({ "flower", "tuber", "dragon" }) do
            local tex = Pins._KindIcon(k)
            check(tex ~= nil and tex ~= "", k .. " art resolves to a drawable texture")
            check(tex ~= QUESTION_ICON, k .. " never renders the question mark on the map")
            if not canResolve then
                check(tex == KIND_ICON[k],
                    k .. " falls back to its static path with no client lookup API")
            end
        end
    end

    if verbose then ns:Print("  pins selftest " .. (pass and "PASS" or "FAIL")) end
    return pass
end)

----------------------------------------------------------------------
-- Everything below needs DaseekiUI (tokens/widgets). Degrade to the pure
-- surface above if Core is absent (HUD.lua already surfaces the notice).
----------------------------------------------------------------------
if type(UI) ~= "table" or type(UI.Color) ~= "function" then
    return
end

----------------------------------------------------------------------
-- Settings access
----------------------------------------------------------------------

local function felwoodCfg()
    local s = ns.Store and ns.Store.GetSettings and ns.Store.GetSettings()
    local ts = s and s.timerSettings
    return (ts and ts.felwood) or {}
end

local function kindEnabled(kind)
    local c = felwoodCfg()
    if kind == "flower" then return c.showFlowerPins ~= false end
    -- Dragons are new in ROUND-17 and have no options toggle yet, so they follow
    -- the tuber switch: both are loot-detected Felwood herb nodes and a user who
    -- wants one almost certainly wants the other. A dedicated `showDragonPins`
    -- is honoured the moment options.lua grows one (not this branch's file).
    if kind == "dragon" then
        if c.showDragonPins ~= nil then return c.showDragonPins ~= false end
        return c.showTuberPins ~= false
    end
    return c.showTuberPins ~= false
end

-- Pin sizes. options.lua's two merged sliders WRITE the legacy base key AND both
-- split keys (flower + tuber), and READ base -> split -> default. These mirror
-- that same chain, so a profile carrying only a split key (an NWB import, or a
-- value written by an older build) sizes its pins the way the slider displays them
-- instead of silently falling back to the default.
local function worldPinSize()
    local c = felwoodCfg()
    return c.worldPinSize or c.worldFlowerSize or c.worldTuberSize or 14
end
local function minimapPinSize()
    local c = felwoodCfg()
    return c.minimapPinSize or c.minimapFlowerSize or c.minimapTuberSize or 12
end
-- World-map pin countdown font size, pt (round-12 restore 3a: the options slider
-- writes felwood.worldTimerFont but nothing read it — the pin timer used a fixed
-- font object). Clamped to the slider's 6-20 range; default 10.
local function worldTimerFont()
    local v = felwoodCfg().worldTimerFont
    if type(v) == "number" and v >= 6 and v <= 20 then return v end
    return 10
end

----------------------------------------------------------------------
-- Node state colouring (via Timers)
--   up      -> available now (green / ok)
--   down    -> respawning (amber / warn), world pin shows countdown
--   unknown -> no data (faint)
----------------------------------------------------------------------

local function nodeState(kind, index)
    if ns.Timers and ns.Timers.GetNodeState then
        return ns.Timers.GetNodeState(kind .. index)
    end
    return { state = "unknown", remaining = 0 }
end

-- Respawning ("down") pins tint amber via Core's `warn` token; fall back to the
-- historical literal on an older Core that predates the token (UI.Color yields
-- white for an unknown token, so detect presence via UI.Token).
local WARN_RGB = { 0.96, 0.76, 0.18 }
local function warnColor()
    if UI.Token and type(UI.Token("warn")) == "table" then return UI.Color("warn") end
    return WARN_RGB[1], WARN_RGB[2], WARN_RGB[3], 1
end

-- ROUND-28: state tint moved from a rotated diamond BACKING to a square RING
-- around the icon. BRAND_SPEC §5 is the reason, not a casualty of it: the diamond
-- budget says every state indicator outside the Coverage Board is a "plain SQUARE
-- color pip", bans ornament diamonds, and allows masked-icon diamonds only at
-- >=24px hero spots "never repeated" — twenty 14px diamonds strewn across Felwood
-- were all three violations at once, and read to the owner as generic markers
-- rather than as the game's own node art. `_back` keeps its name (and so this
-- tinting path is untouched); it is now the ring, not the diamond.
-- ROUND-17 (songflower accuracy audit, fix 6): the node state machine gained
-- "expired" and "stale" in place of an indefinite "up".
--   down    -> respawning (amber)
--   expired -> respawned within the last few minutes; plausibly standing there
--              right now, so this is the state worth walking to (green)
--   stale   -> respawned long ago, nobody has reported it since; we know
--              nothing (faint, same as never-seen)
-- "up" is still accepted so an older engine paired with this file keeps working.
local function tintPin(pin, state)
    local back = pin._back
    if not back then return end
    if state == "up" or state == "expired" then
        back:SetVertexColor(UI.Color("ok"))
    elseif state == "down" then
        back:SetVertexColor(warnColor())
    else
        back:SetVertexColor(UI.Color("faint"))
    end
end

-- Shared pin styling — three concentric squares, cheapest possible construction
-- (three textures, no frames, created once and only RESIZED afterwards):
--   _rim   near-black 1px outer edge — separates the pin from bright map art
--   _back  the STATE ring (tintPin's target), PIN_RING px on every side
--   _tex   the node's real game icon, drawn at exactly the configured size
-- `sz` is the ICON size the user's slider asks for; PinBox(sz) is the frame the
-- rings need around it. The icon is never masked and is no longer scaled down to
-- 0.58 of the box to make room for a diamond — at the same slider value the art
-- now reads roughly twice as large, which is the "real game icons" ask.
local PIN_RING, PIN_RIM = 2, 1
local function pinBox(sz) return sz + 2 * (PIN_RING + PIN_RIM) end

local function stylePin(pin, kind, sz)
    local rim = pin._rim
    if not rim then
        rim = pin:CreateTexture(nil, "BACKGROUND", nil, -2)
        rim:SetTexture(WHITE)
        rim:SetPoint("CENTER", pin, "CENTER", 0, 0)
        rim:SetVertexColor(0, 0, 0, 0.8)
        pin._rim = rim
    end
    rim:SetSize(pinBox(sz), pinBox(sz))

    local back = pin._back
    if not back then
        back = pin:CreateTexture(nil, "BACKGROUND", nil, -1)
        back:SetTexture(WHITE)
        back:SetPoint("CENTER", pin, "CENTER", 0, 0)
        pin._back = back
    end
    back:SetSize(sz + 2 * PIN_RING, sz + 2 * PIN_RING)

    local tex = pin._tex
    if not tex then
        tex = pin:CreateTexture(nil, "ARTWORK")
        tex:SetPoint("CENTER", pin, "CENTER", 0, 0)
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        pin._tex = tex
    end
    -- Re-resolve every style pass but only push a CHANGED path to the texture: the
    -- resolvers cache, and a failed early lookup upgrades itself once the client
    -- has the spell/item (SetTexture on an unchanged path is the cost being avoided).
    local icon = kindIcon(kind)
    if pin._icon ~= icon then
        tex:SetTexture(icon)
        pin._icon = icon
    end
    tex:SetSize(sz, sz)
end

----------------------------------------------------------------------
-- Timer CHIP (ROUND-28, owner screenshot: the Felwood countdowns rendered as bare
-- text below the icon and were unreadable against the map).
--
-- The chip is a small dark badge ABOVE the icon, dressed exactly like the suite's
-- existing badge pattern — the timers dock's icon tile (ui_timersdock makeIconTile):
-- UI.FLAT_BACKDROP, `inset` fill, `borderLite` 1px edge. The only two departures
-- are for floating over MAP ART rather than sitting on a panel ground:
--   * the fill runs at high opacity (CHIP_FILL_ALPHA) so Felwood's bright greens
--     never bleed through the numerals;
--   * a near-black 1px halo sits behind the whole chip, so the light `borderLite`
--     edge has something to separate it from whatever is underneath.
--
-- LAYERING: the chip is its OWN frame at a frame level well above the pins, not a
-- FontString on the pin. Pins are siblings at one level on the canvas, so draw
-- order between them is creation order — a plain OVERLAY label on one pin can be
-- covered by a neighbouring pin's icon where nodes cluster. A higher frame level
-- wins against every sibling regardless, at every map zoom (the canvas scales the
-- whole frame, so the chip scales and stays put with its pin).
--
-- COST: created ONCE per pin, then only SetText/SetSize/colour per refresh. No
-- per-tick frame or texture creation.
--
-- ROUND-29: the same chip is now built for MINIMAP pins too, at the scaled
-- metrics from Pins.ChipMetrics("minimap"). The chip is a CHILD of its pin and
-- anchored to it, so a minimap pin being re-anchored every second as the player
-- moves carries its chip along for free — no second position to keep in sync.
----------------------------------------------------------------------

-- Build the chip for `pin` at `surface`'s metrics. The surface is fixed for the
-- life of the pin (world pins and minimap pins are different frames).
local function ensureChip(pin, surface)
    if pin._chip then return pin._chip end
    local m = Pins.ChipMetrics(surface)
    local chip = CreateFrame("Frame", nil, pin, "BackdropTemplate")
    chip:SetFrameStrata("HIGH")
    chip:SetFrameLevel((tonumber(pin.GetFrameLevel and pin:GetFrameLevel()) or 1) + CHIP_LEVEL_LIFT)
    chip:SetPoint("BOTTOM", pin, "TOP", 0, m.gap)
    chip:Hide()

    -- Near-black halo, one pixel proud of the chip on every side.
    local halo = chip:CreateTexture(nil, "BACKGROUND", nil, -8)
    halo:SetTexture(WHITE)
    halo:SetPoint("TOPLEFT", chip, "TOPLEFT", -1, 1)
    halo:SetPoint("BOTTOMRIGHT", chip, "BOTTOMRIGHT", 1, -1)
    halo:SetVertexColor(0, 0, 0, 0.7)

    -- Suite badge dress; re-skinned on theme change like every other UI.Skin consumer.
    UI.Skin(chip, function(self)
        self:SetBackdrop(UI.FLAT_BACKDROP)
        self:SetBackdropColor(UI.Color("inset", CHIP_FILL_ALPHA))
        self:SetBackdropBorderColor(UI.Color("borderLite", CHIP_EDGE_ALPHA))
    end)

    local timer = chip:CreateFontString(nil, "OVERLAY")
    timer:SetFontObject(UI.fonts.small)
    timer:SetPoint("CENTER", chip, "CENTER", 0, 0)
    chip._timer = timer

    pin._chip     = chip
    pin._timer    = timer
    pin._chipM    = m
    pin._chipSide = "above"
    return chip
end

-- Apply text + ink and size the chip to fit; nil text hides it outright (the
-- "no chip when there is no timer" contract, identical on both surfaces).
local function setChipText(pin, text, token)
    local chip = pin._chip
    if not chip then return end
    if not text then chip:Hide(); return end
    local m = pin._chipM or Pins.ChipMetrics("world")
    local timer = pin._timer
    timer:SetText(text)
    timer:SetTextColor(UI.Color(token or "text"))
    local w = tonumber(timer.GetStringWidth and timer:GetStringWidth()) or 0
    local h = tonumber(timer.GetStringHeight and timer:GetStringHeight()) or 0
    chip:SetSize(math.max(m.minW, math.floor(w + 0.5) + m.padX * 2),
                 math.max(m.minH, math.floor(h + 0.5) + m.padY * 2))
    chip:Show()
end

-- (Re)anchor the chip above or below its pin. Idempotent and cheap: the current
-- side is remembered, so the 1s minimap refresh only re-runs SetPoint on a change.
local function setChipSide(pin, side)
    local chip = pin._chip
    if not chip or pin._chipSide == side then return end
    local m = pin._chipM or Pins.ChipMetrics("world")
    chip:ClearAllPoints()
    if side == "below" then
        chip:SetPoint("TOP", pin, "BOTTOM", 0, -m.gap)
    else
        chip:SetPoint("BOTTOM", pin, "TOP", 0, m.gap)
    end
    pin._chipSide = side
end

-- Push the surface's chip font onto the pin's timer string. Core's PICKED face is
-- read from UI.fonts.small so a live font-picker change reaches the chip, and the
-- result is cached by face+size (round-12 restore 3a / round-14; ROUND-29 makes it
-- surface-aware so the minimap gets the scaled size off the same slider).
local function applyChipFont(pin, surface)
    if not pin._timer then return end
    local base = UI and UI.fonts and UI.fonts.small
    local face, _, fl = base and base:GetFont()
    if not face then return end
    local fsz = Pins.ChipFontSize(surface, worldTimerFont())
    if pin._timerSz ~= fsz or pin._timerFace ~= face then
        pin._timer:SetFont(face, fsz, fl)
        pin._timerSz, pin._timerFace = fsz, face
    end
end

----------------------------------------------------------------------
-- World-map pins
--
-- Parented to the WorldMapFrame canvas; shown only while the displayed map is
-- Felwood. Positioned by exact normalized node coords × canvas size (already
-- correct — normalized placement is kept verbatim).
----------------------------------------------------------------------

local worldPins = {}   -- "kind"..index -> pin frame

local function worldCanvas()
    local wmf = WorldMapFrame
    if not wmf then return nil end
    local sc = wmf.ScrollContainer
    if sc and sc.Child then return sc.Child end
    return wmf   -- fallback: anchor to the frame itself
end

local function ensureWorldPin(kind, index, node)
    local key = kind .. index
    local pin = worldPins[key]
    if pin then return pin end
    local canvas = worldCanvas()
    if not canvas then return nil end

    pin = CreateFrame("Frame", nil, canvas)
    local sz = worldPinSize()
    pin:SetSize(pinBox(sz), pinBox(sz))
    pin:SetFrameStrata("HIGH")
    stylePin(pin, kind, sz)
    ensureChip(pin, "world")

    pin:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(node.label or (kind .. " " .. index), UI.Color("text"))
        local st = nodeState(kind, index)
        if st.state == "down" then
            GameTooltip:AddLine("Respawns in " .. fmtCountdown(st.remaining), UI.Color("muted"))
        elseif st.state == "expired" or st.state == "up" then
            -- `remaining` is NEGATIVE in the expired band: how long ago it came
            -- back. Shown as "-M:SS" so the age of the claim is visible rather
            -- than an open-ended "Available" that was previously never revoked.
            local ago = st.remaining and -st.remaining or 0
            if ago > 0 then
                GameTooltip:AddLine("Respawned -" .. fmtCountdown(ago) .. " ago", UI.Color("ok"))
            else
                GameTooltip:AddLine("Available", UI.Color("ok"))
            end
        else
            GameTooltip:AddLine("No data", UI.Color("faint"))
        end
        GameTooltip:Show()
    end)
    pin:SetScript("OnLeave", function() GameTooltip:Hide() end)

    worldPins[key] = pin
    return pin
end

local function refreshWorldPins()
    local wmf = WorldMapFrame
    if not wmf or not wmf:IsShown() then
        for _, p in pairs(worldPins) do p:Hide() end
        return
    end
    local shown = wmf.GetMapID and wmf:GetMapID()
    if shown ~= FELWOOD_MAP then
        for _, p in pairs(worldPins) do p:Hide() end
        return
    end
    local canvas = worldCanvas()
    if not canvas then return end
    local cw, ch = canvas:GetWidth(), canvas:GetHeight()
    if not cw or cw == 0 then return end

    local nodes = ns.Timers and ns.Timers.NODES
    if not nodes then return end

    for kind, list in pairs(nodes) do
        for index = 1, #list do
            local node = list[index]
            if kindEnabled(kind) then
                local pin = ensureWorldPin(kind, index, node)
                if pin then
                    local sz = worldPinSize()
                    pin:SetSize(pinBox(sz), pinBox(sz))
                    stylePin(pin, kind, sz)
                    applyChipFont(pin, "world")
                    pin:ClearAllPoints()
                    pin:SetPoint("CENTER", canvas, "TOPLEFT", node.x * cw, -node.y * ch)
                    local st = nodeState(kind, index)
                    tintPin(pin, st.state)
                    -- ROUND-28: chip above the icon, inked by the DOCK's songflower
                    -- rule (through Pins.ChipContent -> Pins.TimerToken). nil text =>
                    -- no chip, which is exactly what the old empty label rendered as.
                    setChipText(pin, Pins.ChipContent("world", st))
                    pin:Show()
                end
            else
                local p = worldPins[kind .. index]
                if p then p:Hide() end
            end
        end
    end
end

----------------------------------------------------------------------
-- Minimap pins — proper world projection (R2-c). Pixels-per-yard from the live
-- minimap zoom (outdoor table: Felwood pins only ever render in the outdoor
-- world zone; the indoor table is kept for defensive completeness).
----------------------------------------------------------------------

local minimapPins = {}
local nodeWorld   = {}   -- "kind"..index -> {wx, wy}, computed once (nodes are fixed)

-- Live pixels-per-yard from the current minimap zoom. nil if unresolvable.
local function minimapPixelsPerYard()
    local w = (Minimap and Minimap.GetWidth and Minimap:GetWidth()) or 140
    local zoom = (Minimap and Minimap.GetZoom and Minimap:GetZoom()) or 0
    local indoors = IsInInstance and IsInInstance()
    local tbl = indoors and MINIMAP_YARDS_INDOOR or MINIMAP_YARDS_OUTDOOR
    local diameter = tbl[zoom] or tbl[0]
    if not diameter or diameter <= 0 or not w or w <= 0 then return nil end
    return w / diameter
end

-- Resolve the projection facing. Returns (facing, ok):
--   north-up             -> (0, true)
--   rotating + facing     -> (facing, true)
--   rotating, no facing   -> (nil, false)  [cannot project; caller hides pins]
local function minimapProjectionFacing()
    local rotating = GetCVar and GetCVar("rotateMinimap") == "1"
    if rotating then
        if GetPlayerFacing then return GetPlayerFacing() or 0, true end
        return nil, false
    end
    return 0, true
end

-- Continent/world position of a fixed node — computed once and cached.
local function nodeWorldPos(kind, index, node)
    local key = kind .. index
    local cached = nodeWorld[key]
    if cached then return cached[1], cached[2] end
    if not (C_Map and C_Map.GetWorldPosFromMapPos and CreateVector2D) then return nil end
    local _, wpos = C_Map.GetWorldPosFromMapPos(FELWOOD_MAP, CreateVector2D(node.x, node.y))
    if not wpos then return nil end
    local wx, wy = wpos:GetXY()
    if not wx then return nil end
    nodeWorld[key] = { wx, wy }
    return wx, wy
end

-- Continent/world position of the player, recomputed each refresh.
local function playerWorldPos()
    if not (C_Map and C_Map.GetWorldPosFromMapPos and C_Map.GetPlayerMapPosition) then return nil end
    local mpos = C_Map.GetPlayerMapPosition(FELWOOD_MAP, "player")
    if not mpos then return nil end
    local _, wpos = C_Map.GetWorldPosFromMapPos(FELWOOD_MAP, mpos)
    if not wpos then return nil end
    return wpos:GetXY()
end

local function ensureMinimapPin(kind, index, node)
    local key = kind .. index
    local pin = minimapPins[key]
    if pin then return pin end
    pin = CreateFrame("Frame", nil, Minimap)
    local sz = minimapPinSize()
    pin:SetSize(pinBox(sz), pinBox(sz))
    pin:SetFrameStrata("HIGH")
    stylePin(pin, kind, sz)
    -- ROUND-29: minimap pins carry the countdown chip too, at scaled metrics.
    -- Parented to the PIN, so it tracks every re-anchor as the player moves.
    ensureChip(pin, "minimap")
    minimapPins[key] = pin
    return pin
end

local function hideAllMinimapPins()
    for _, p in pairs(minimapPins) do p:Hide() end
end

local function refreshMinimapPins()
    if not Minimap then return end
    -- Only in Felwood.
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if mapID ~= FELWOOD_MAP then
        hideAllMinimapPins()
        return
    end
    -- Projection facing (handles rotating minimap; hides if unresolvable).
    local facing, projOK = minimapProjectionFacing()
    if not projOK then
        hideAllMinimapPins()
        return
    end
    local ppy = minimapPixelsPerYard()
    if not ppy then
        hideAllMinimapPins()
        return
    end
    local pWX, pWY = playerWorldPos()
    if not pWX then
        hideAllMinimapPins()
        return
    end

    local radius = ((Minimap.GetWidth and Minimap:GetWidth()) or 140) / 2
    local nodes = ns.Timers and ns.Timers.NODES
    if not nodes then return end

    for kind, list in pairs(nodes) do
        for index = 1, #list do
            local node = list[index]
            if kindEnabled(kind) then
                local pin = ensureMinimapPin(kind, index, node)
                local sz = minimapPinSize()
                pin:SetSize(pinBox(sz), pinBox(sz))
                stylePin(pin, kind, sz)
                local nWX, nWY = nodeWorldPos(kind, index, node)
                if nWX then
                    local dx, dy = Pins._ProjectMinimap(pWX, pWY, nWX, nWY, ppy, facing)
                    local dist = math.sqrt(dx * dx + dy * dy)
                    if dist <= radius then
                        pin:ClearAllPoints()
                        pin:SetPoint("CENTER", Minimap, "CENTER", dx, dy)
                        local st = nodeState(kind, index)
                        tintPin(pin, st.state)
                        -- ROUND-29: the countdown chip, same content and same ink
                        -- as the world map's (Pins.ChipContent), scaled geometry.
                        applyChipFont(pin, "minimap")
                        local text, token = Pins.ChipContent("minimap", st)
                        setChipText(pin, text, token)
                        if text then
                            local m = pin._chipM or Pins.ChipMetrics("minimap")
                            local chipH = tonumber(pin._chip and pin._chip.GetHeight
                                                   and pin._chip:GetHeight()) or m.minH
                            setChipSide(pin, Pins.ChipSide(dy + pinBox(sz) / 2, chipH, m.gap, radius))
                        end
                        pin:Show()
                    else
                        pin:Hide()   -- outside the minimap view
                    end
                else
                    pin:Hide()       -- projection API unavailable / node not resolvable
                end
            else
                local p = minimapPins[kind .. index]
                if p then p:Hide() end
            end
        end
    end
end

----------------------------------------------------------------------
-- Refresh driver
----------------------------------------------------------------------

local function refreshAll()
    ns:SafeCall(refreshWorldPins)
    ns:SafeCall(refreshMinimapPins)
end
Pins.Refresh = refreshAll

local driver
local function ensureDriver()
    if driver then return end
    driver = CreateFrame("Frame")
    driver._accum = 0
    driver:SetScript("OnUpdate", function(self, elapsed)
        self._accum = self._accum + elapsed
        if self._accum >= 1 then       -- 1s refresh (countdowns + player movement)
            self._accum = 0
            refreshAll()
        end
    end)
end

----------------------------------------------------------------------
-- Wiring
----------------------------------------------------------------------

ns:On("NODE_UPDATED", function() ns:SafeCall(refreshAll) end)

ns:On("LOGIN", function()
    ns:SafeCall(ensureDriver)
    -- Refresh world pins whenever the map opens.
    if WorldMapFrame and WorldMapFrame.HookScript and not Pins._hooked then
        Pins._hooked = true
        WorldMapFrame:HookScript("OnShow", function() ns:SafeCall(refreshWorldPins) end)
    end
    ns:SafeCall(refreshAll)
end)
