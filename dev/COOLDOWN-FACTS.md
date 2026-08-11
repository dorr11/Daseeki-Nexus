# Classic Era craft cooldowns — the fact pass (2026-08-11)

Why this file exists. `PROFESSIONS_DATASET_ADDENDUM.md`, our Room-1 source for the
whole recipe universe, **records no cooldown facts at all**. Every cooldown the
addon knows is therefore either derived from the addendum's own data or asserted
here, by a named pass, against public game facts — and an assertion with no
provenance is the thing this file refuses to allow.

The shipped encoding is a **group ordinal and nothing else**. `[recipe]` field 7
(`cd`) is `0` for a recipe with no cooldown, or `n` for cooldown group `n`; the
key rule everywhere downstream is `cd > 0 => "g<cd>"`. Durations are **not**
shipped: the remaining time comes live from `GetTradeSkillCooldown` /
`GetCraftCooldown` against the player's own window, so a shipped duration could
only ever be a second source of truth to disagree with the client. Durations
appear below as documentation of *why a group exists*, never as data.

Scope of the model: a cooldown is in scope **only if a trade-skill or craft
WINDOW row reports it**. That is the entire capture surface — `FoldCooldowns`
reads a cooldown per enumerated row. A cooldown that lives on an item, on the
player, or anywhere else is invisible to that surface and cannot be carried
honestly, however real it is in the game.

## The groups

### g1 — Alchemy's transmutes (SHARED: 12 recipes, one timer)

Derived, not asserted: every member's name in the addendum begins `Transmute:`,
so the group's membership is the data's own answer and the extractor computes it.
Predates this pass; unchanged by it. Members: 11479, 11480, 17187, 17559, 17560,
17561, 17562, 17563, 17564, 17565, 17566, 25146.

### g2 — Mooncloth (SOLO: one recipe, its own timer) — NEW, FIX-5

- Teaching spell **18560**, Tailoring **250**, taught by `Pattern: Mooncloth`
  (item 14526).
- **Is a trade-skill window recipe.** Wowhead's Classic entry for spell 18560
  carries the `Tradeskill recipe` flag.
- **Carries its own cooldown, 4 days.** Wowhead Classic prints `4 days`;
  classicdb.ch's entry for the same spell gives 345600 s (5760 min) — the same
  number from an independent database.
- **Not shared with anything on Era.** The only recipes Mooncloth ever shared a
  cooldown question with are Spellcloth and Shadowcloth, and both are TBC; the
  wiki notes explicitly that the Mooncloth cooldown was not shared with them.
  It is not shared with alchemy's transmutes either, so it gets its own group
  rather than joining g1.
- A minority secondary source describes the practical interval as 92 hours
  (3d 20h) rather than 96. Both primary spell databases agree on 345600 s, and
  the number is documentation here in any case — the client answers the
  countdown, not us.

Sources:
- https://www.wowhead.com/classic/spell=18560/mooncloth
- https://classicdb.ch/?spell=18560
- https://wowpedia.fandom.com/wiki/Mooncloth_Tailoring

A solo cooldown is encoded as a **group of exactly one**, deliberately: the key
rule stays the only rule, the pane's dataset-driven kind enumeration picks it up
with no new mechanism, and the label router chooses "the member's own name" vs
"<profession> · shared cooldown" on the MEMBER COUNT — so the next fact pass adds
a row to the extractor's `SOLO_COOLDOWNS` table and touches no consuming code.

## Rejected — with reasons, so they are not re-litigated

### Refined Deeprock Salt / Salt Shaker — OUT (item-use, not a window recipe)

The Salt Shaker (item 15846) is crafted by an **Engineer** at 250; that craft is
in our dataset as teaching spell **19567**, and it has **no cooldown**. Refined
Deeprock Salt is produced by **using the item**, which requires Leatherworking
250+ on the user, and the 3-day cooldown sits on the **player**, not on the
device and not on any recipe row. Warcraft Wiki states it outright: it "was NOT a
Leatherworking pattern".

Consequence for us: no trade-skill window ever enumerates a row for it, so
`GetTradeSkillCooldown` can never report it and the window-scan model has nothing
to read. Marking it would produce a pane row whose readiness we could never
answer — a permanent "ready" for a cooldown that may well be running. It is
therefore deliberately unmarked, and spell 19567's `cd == 0` is pinned in the
dataset-integrity suite so a future pass cannot quietly change that without
seeing this note.

Tracking it properly would need a different capture surface entirely (the item's
own `GetItemCooldown` on a bag/bank scan). That is a feature, not a marking, and
it is not in this pass.

Sources:
- https://warcraft.wiki.gg/wiki/Refined_Deeprock_Salt
- https://warcraft.wiki.gg/wiki/Salt_Shaker

### Everything else — OUT (no such recipe)

No Era trade-skill or craft window recipe outside the two groups above carries a
cooldown. Alchemy's non-transmute line (elixirs, potions, flasks — flasks are
gated by an alchemy lab, which is a place, not a timer), blacksmithing,
enchanting, engineering, leatherworking, cooking, first aid, poisons and the
gathering professions have none. The community sources that enumerate "Classic
profession cooldowns" list three things, and the third is the Salt Shaker
rejected above.

## What this pass did NOT change

The recipe **set** — which teaching spells exist and in what per-profession
order — is untouched. That set, and only that set, defines the known-recipe
bitmaps' coordinate system, and it is hashed separately as
`ns.ProfessionsDataMeta.setHash`. This pass moved the version stamp
(`p1-4b17878e` -> `p1-c1aa1cd2`) and left the set hash at **`s1-3dbe2152`**, so
every stored record — local and peer — remains valid and **zero** re-scans are
required. The generator emitted **0 migration rows**, which is the proof. The
value is pinned as a literal in the dataset-migration suite.
