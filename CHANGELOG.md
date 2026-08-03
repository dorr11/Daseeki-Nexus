# Changelog

## Unreleased

- Fixed: **stored buffs whose time was printed in the tooltip's right-hand column, or
  off to one side, were being missed.** Hovering a chronoboon only ever read the left
  column of the tooltip's numbered lines. When a buff's name sat on the left and its
  remaining time on the right — a perfectly ordinary layout — the buff was recorded as
  "in the boon, time unknown" and the minutes were thrown away; when the whole
  suspended-effects list was drawn as one loose block rather than as numbered lines, the
  buffs in it were not seen at all. The hover now reads every line, both columns, and
  every stray piece of text the tooltip is drawing. Text that appears twice is only
  counted once, and where the same buff shows up in two places the reading that actually
  carries a time is the one that is kept.

- Fixed: **"Battle Shout (Boon)" was a state the game cannot produce.** A chronoboon
  cannot hold a Battle Shout or Fire Festival Fury — the Displacer will not take them —
  but the code that reads a chronoboon's tooltip checked all ten tracked buffs instead of
  the eight that can actually go in. So any hover over a boon icon whose tooltip merely
  contained the words wrote Battle Shout down as stored, and it then showed up on the
  character's card and detail row as a suspended buff, frozen, for as long as the boon
  lasted. It is now ignored, along with Fire Festival Fury, and the "how many buffs are in
  the boon" number no longer counts either of them.

  Records that already picked up one of these are cleaned up once, on your next login,
  across every account in your store and including the saved boon snapshots — and the
  same rows arriving from a mesh peer who has not updated yet are stripped on the way in,
  every time, not just once. A Battle Shout you actually *have* is untouched throughout:
  only the impossible "in the boon" version is removed.

- Fixed: **a stored buff with no readable time could steal the next one's.** In the same
  tooltip read, a buff listed without its own remaining time picked up the minutes
  belonging to whichever buff came after it — the surviving half of the old "Fengus'
  1h 59m appeared on Rallying Cry" bug. Each buff's time is now read only from its own
  line, and a buff whose time genuinely cannot be read keeps the number already on record
  instead of being corrected to a wrong one.

- Changed: **Settings is smaller.** Four things you were being asked to configure have
  been decided for you, because there was only ever one sensible answer and keeping the
  controls meant keeping the ways they could be set wrong.

  - **Custom locations are gone.** The Locations table on the General page — the
    numbered coordinate boxes with Add Location / Here / Del — is removed, and the
    records themselves are retired, not just hidden. Each one leaves a marker behind, so
    a copy arriving later from another account, a ShadowNetwork re-import, or a restored
    settings file is removed again instead of quietly coming back. Your location data
    now comes from where your characters actually are. If you had ever typed a location
    override onto a character by hand, that text was already copied into that
    character's Note and stays there.
  - **Class colours are fixed.** The nine hex fields are gone; names are painted from
    the standard palette everywhere. Anything you had customised is kept in your
    settings file rather than deleted, in case this ever needs reversing.
  - **Buff duration thresholds are gone.** Eighteen numbers replaced by three facts: a
    2-hour buff turns yellow with less than 90 minutes left, a 1-hour buff with less
    than 55, and the 15-minute NPC Battle Shout with less than 12. Above that they are
    green. A buff you *have* is never red any more — red now means one thing, "missing",
    instead of two.
  - **The Tombstones list is gone from Settings.** Only the list: deleting an account
    still blocks it from re-appearing for 14 days, exactly as before. There was nothing
    on that screen to do except watch a countdown.

- Changed: **buff class rules are one set now, not one per faction.** Whether your
  rogues want Battle Shout is a fact about rogues, so the Horde/Alliance switch on that
  page is gone and there is a single list. Your existing Horde configuration becomes the
  shared one; paladin rules are taken from your Alliance side, since a Horde table has
  never had a real paladin setting in it. Both old lists are kept untouched in your
  settings file. This is also the end of an old trap — a tick could previously land in
  the faction you do not play and appear to do nothing.

- Changed: **"Mesh & Accounts" is now "Setup", and its three identity fields sit on one
  row.** Account ID, Channel and Token each have their label above their box instead of
  three stacked rows with a hint under each — they are one job, so they read as one
  block. Show/Hide, validation and the setup bundle all work as before, and the fields
  still refuse to be overwritten while you are typing in them.

- Changed: **the buff rules page is called "Buffs"**, and its class grids run in the
  order you use them: Battle Shout, Rend, Slip'kik's Savvy, Fengus' Ferocity.

- Changed: **the character list opens on 60s.** The roster exists for the level-60
  world-buff view, so it now starts there instead of showing every alt. Clicking the
  active 60S chip still clears back to everything.

- Fixed: **the on-screen alert banner ignored your chosen font.** The big centred
  warning (pull timers, quest hand-ins, cooldown alerts) was hardcoded to the game's
  default face while every other piece of Nexus type follows the font you pick in
  Daseeki Core — so the one line you actually read mid-pull was the one line in the
  wrong font. It now uses your picked face, keeps its heavy outline, and changes with
  the picker and your font-size setting without a reload. Same size, position and
  colour as before at the default setting.

- Fixed: **the group list on an instance-log hover was not really in columns.** A
  tooltip line is a single piece of text, so the four "columns" of names were just four
  names glued together — each one started wherever the previous name happened to end, and
  on a 40-man raid the result was four ragged edges. The roster is now laid out as a real
  grid: every column starts at one fixed point down the whole block, and the level sits in
  its own right-aligned slot so single- and double-digit levels leave the names lined up
  too. Column width is measured from the actual names in the group, so a five-man stays
  compact and a full raid of long names is capped rather than running off the screen.

- Fixed: **group members on the instance-log hover showed up plain white.** They were
  meant to be class-coloured, but runs recorded before class capture existed — and imports
  whose source had no class field — carry no class per member, and there was nothing to
  fall back on. Nexus now looks the name up in the characters it already knows (your own,
  your alts, and any peer on the mesh) and colours from that; the "(you)" entry always
  colours, since your own class is never in doubt. A name it genuinely does not know stays
  neutral rather than being coloured with a guess, and if two realms disagree about a name
  it stays neutral too. Newly recorded runs already carried class and are unaffected.

- Changed: **the Rest view's columns now split the table 40 / 20 / 20 / 20.** CHARACTER,
  LEVEL, XP and REST used to be sized to their own contents, which left the three numbers
  bunched against the right edge with a gulf after the character name. They now take fixed
  shares of the list width, so the header row sits over its columns and the space is spread
  evenly. Numbers stay right-aligned.

- Fixed: **pressing Escape in a character's NOTE box threw away what you had typed.**
  Escape restored the previously saved note and *then* released the box, so the save that
  fires on release wrote the restored text back over yours. Escape now saves and then
  releases. Clicking away still saves as before, and switching to another character while
  the box is still active saves the note to the character you actually wrote it for.

- Fixed: **Fengus' Ferocity no longer reads as Missing on casters.** Fengus is the
  Dire Maul tribute *attack power* buff, so a mage, priest or warlock has no use for
  it — but the card counted it like any other world buff and showed a level 60 mage
  "WORLD BUFFS · 7/8 HELD" with a red Missing tile. Fengus is now a per-class rule
  like Slip'kik's Savvy and Rend: it ships **required** for Warrior, Paladin, Hunter,
  Rogue, Shaman and Druid, and **ignored** (hidden, never counted) for Mage, Priest
  and Warlock. Casters now read 7/7. A new "Fengus' Ferocity (DMT AP) — Required
  Classes" grid on Settings → Auras lets you set any class to
  required / optional / ignored per faction, exactly like the other rules.
  Existing installs get the new defaults automatically on the next login — nothing to
  re-tick — and if you had already set Fengus' classes by hand, your choices are kept.
>>>>>>> e8f919c (fix(nexus/auras): Fengus' Ferocity is a per-class rule (casters stop reading Missing))

- Fixed: **an old Daseeki Core could take the dashboard down with it.** Three places
  drew their divider rules with a Core 2.2.0 drawing call, unguarded — on an older
  Core that is a Lua error mid-build, and you lose the whole panel rather than one
  line. Those calls now go through a version guard: an out-of-date Core costs you the
  rule and gets you one chat line telling you to update Daseeki Core, and everything
  else draws as normal. Requires Daseeki Core v2.2.0 for the full dress.

- Fixed: **a Daseeki Bags install that arrived after Nexus never got imported.** The
  one-time cross-account Bags import marked itself "done" even when Bags was not
  installed, so installing Bags later found the door already shut and your old
  cross-account bag data never came across. The marker is now set only after an
  import that actually read something, so a later Bags install still migrates. The
  newer Inventory module already worked this way; this brings the older path in line.
  Anyone whose marker is already stuck stays stuck — the reset is a separate change.

- Mesh: **peers on an older data format are no longer ignored.** Character records
  carry a format version, and Nexus used to accept only its own exact version, so any
  future format bump would blank out every peer who had not updated yet. It now reads
  older versions too (fields the old sender did not have simply read as absent) and
  refuses only versions NEWER than it understands. This ships one release ahead of the
  next format bump on purpose: the tolerance has to be out in the wild before anything
  starts sending the new shape.

- **⚠ ALL ACCOUNTS SHOULD RELOAD TOGETHER AFTER THIS UPDATE.** This release changes
  how the heartbeat's segment hashes are computed (they now include a coarse
  fingerprint of each character's data, not just the list of names). An updated
  client and an out-of-date one will therefore always disagree about those hashes
  and will keep asking each other to re-sync until both are on this build. Nothing
  breaks and no data is lost — the wire format itself is unchanged, and the existing
  per-target rate limits cap the churn at one manifest per 5s and one segment per
  60s per account — but until every account has reloaded there is avoidable mesh
  chatter. Reload (or relog) all of your accounts once, together, and it stops.

- Fixed: **the Songflower grid said "No data" forever on a layered realm.** Whitemane
  is layered, and on a layered realm the songflower timers do not arrive as plain
  fields — they arrive nested one level down, in a per-layer map. Nexus was reading
  only the flat, top-level fields and skipping that map entirely, so on your realm it
  was skipping *every* songflower timer the network carries. All ten cells sat empty
  no matter how long you listened.

  Nexus now reads them. A node it has never seen is filled in; a node holding your
  own pick is left completely alone for the full 25-minute respawn (walking up to a
  flower and watching it get picked still beats anything second-hand); and once a
  node is filled, later reports follow the usual newest-wins rule with the 10-second
  duplicate guard. Where several layers report the same node, the newest of them is
  used, and only once — not one write per layer.

  **The honest caveat:** Nexus does not know which layer you are on, and the data
  does not say. A filled cell reflects a pick that happened on *some* layer, so it
  can be off — the flower may already be up, or still be down when the timer says
  it is up. That is a deliberate trade: some data beats none, and the moment you
  pick a flower yourself, your own observation takes that node over outright. Node
  sources are visible in `/nexus debug timers`, and `/nexus debug nwb` now prints a
  running songflower tally (heard, applied, filled, and why anything was refused).

- Fixed: **a duplicate character card that no amount of reloading would clear.** Nexus
  keeps one bucket of characters per account, and exactly one of them is flagged as
  *this* account — the flag that makes your own roster untouchable, so nothing
  arriving over the mesh can ever delete your characters. If you ran Nexus before
  setting an account ID, the unattributed bucket got that flag (correctly, at the
  time); setting an account ID afterwards flagged the real bucket too, and nothing
  ever took the flag back off the old one. The result was two buckets both claiming
  to be you, and because the stale-twin cleanup deliberately never removes anything
  from a bucket flagged as yours, the leftover copy of a character was permanently
  immune to it — the same character drawn twice, both lit green, forever.

  Nexus now checks this at login: only the bucket matching your current account ID
  may claim to be you, and any other bucket still wearing the flag has it removed
  (noted in `/dsn debug mesh`). Nothing is deleted by that check — it only lets the
  ordinary cleanup, with all of its existing safeguards, finally do its job. The
  duplicate clears on your next login and stays gone. If you have never set an
  account ID the check does nothing at all, so pre-setup rosters keep their
  protection.

- Fixed: **the Auras and Automation pages now open on YOUR faction instead of always
  Alliance.** Everything on those two pages is saved per faction, and the Faction
  toggle at the top used to reset to Alliance every single reload. So if you play
  Horde and set a class rule — say marking Slip'kik's Savvy *required* for Shamans —
  the click quietly landed in your **Alliance** settings, and your Horde characters
  went on reading their own untouched rules. The buff stayed yellow (optional) on
  the cards and in the detail pane, with nothing on screen to say why. The page now
  opens on the faction you are actually playing, so the setting you make is the
  setting you get. This fixes the whole family of "it didn't take" cases on those
  pages — thresholds, class rules, gossip buff types and auto-summon triggers alike.

  **One thing to do once:** any rule you set before this update was written to the
  Alliance side, and your data has deliberately been left exactly as you saved it
  rather than guessed at and moved. Open Nexus → Auras (it will now say Horde), and
  re-tick the rules you want — for example Slip'kik's Savvy → Shaman → *required*.
  It is a single click per rule, and it sticks this time.

- Fixed: **the minimap button now plays nicely with minimap button managers when
  LibDBIcon is available.** Addons that collect and tidy minimap buttons (Leatrix
  Plus and friends) recognise buttons registered through the standard LibDBIcon
  library and wrap anything else — which is why hovering our button showed *their*
  message ("This is a custom button. Please ask the addon author to use the standard
  LibDBIcon library instead") instead of our world-buff timers, and why clicks went
  astray. If any addon you run provides LibDBIcon, Nexus now registers its button
  through it as "DaseekiNexus": collectors list and manage it properly, and our own
  tooltip and full click matrix come back. Your button keeps the spot you dragged it
  to, and the Show/Lock settings still work exactly as before. If nothing on your
  system provides LibDBIcon, the button behaves as it always has — and in that case
  there is no button manager to interfere with it either. Nexus does not bundle the
  library; it simply uses one when it is already there.

- Fixed: **other accounts' characters stopped updating on screen.** Every inbound
  path wrote peer data into the store and then told nothing — the dashboard, cards
  and detail pane all repaint off a callback the receive handlers never fired. So a
  remote character's buffs updated in the saved data and sat there: durations froze
  on screen, and only a change to *your own* character (or reopening the window)
  ever pulled the new data into view. Inbound state pushes, segment adoptions and
  manifest ghost cleanups now announce themselves, once per received message.

- Fixed: **a change you made while no peers were online was never sent.** The tracker
  recorded state as "delivered" before it had been handed to the transport, so a
  change captured while the mesh knew zero peers (alone at login, mid-join, a peer
  relogging) was marked done and then suppressed by the duplicate filter forever. It
  only escaped when something *else* about the character changed. The transport now
  reports how many peers it actually reached, and a change that reached nobody is
  retried instead of being forgotten.

- Fixed: **a parked character never refreshed.** Capture only ran on events — auras,
  bags, resting, zoning, XP — so an alt standing in a city fired none of them and
  never re-evaluated its own state. That also made the existing 5-minute "max quiet"
  forced refresh unreachable on exactly the characters that needed it. A 30-second
  safety rescan now runs while you are logged in (and stops during logout). It is
  nearly free: an unchanged character still sends nothing, because the duplicate
  filter suppresses it.

- Fixed: **remote characters could read permanently offline, with frozen durations.**
  Peers were recorded under whatever name the addon channel reported, which is
  sometimes the bare character name with no realm. The roster matches peers against
  full `Name-Realm` keys, so those peers matched nothing, won nothing, and every
  character on that account showed as offline. Peer names are now stored canonically
  — preferring the `Name-Realm` the peer's own discovery/heartbeat message carries,
  and adding your realm to a bare name otherwise. `/dsn debug mesh` now shows
  `Name-Realm` for every peer.

- Fixed: **a push that got lost stayed lost.** The heartbeat only compared *which*
  characters each account held, never what was in them, so two accounts agreed while
  one held an hours-old copy. Segment hashes now fold in a coarse per-character
  fingerprint (buff durations to the minute, raid lockouts to 5 minutes, the key
  flags), so a stale copy is detected and healed by the re-sync that already exists.
  See the reload note at the top.

- Fixed: **inbound data destroyed fields the mesh does not carry.** An incoming state
  push replaced a peer's record wholesale, wiping raid-attunement flags and the
  Darkmoon fortune's remaining-time accounting — data that only arrives on the bulk
  sync path — so a detail pane would drop from a real countdown back to a bare "on
  cooldown" seconds after showing it. Those fields are now carried across explicitly.
  Data the wire *does* carry is still fully authoritative, including when it clears
  something. (Your notes were never affected; they are stored separately.)

- Fixed: an out-of-range cooldown or buff duration wrapped around on the wire instead
  of being capped — 18h12m read as "no cooldown". Values now saturate at the maximum
  the field can hold, so an error reads as "at least this long" rather than as a
  plausible wrong number. No wire-format change; every in-range value encodes exactly
  as before.
