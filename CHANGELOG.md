# Changelog

## Unreleased

- **Fixed:** your own characters could be overwritten on screen by another account's
  second-hand copy of them. If you played Poonyx on account 1 while account 2 was also
  online, account 2's older idea of Poonyx could take over the Poonyx card — showing
  stale or missing world buffs for a character you were *sitting on* — and another
  account's alt could likewise show buffs it did not really have. **Each account is now
  the source of truth for its own characters:** Nexus refuses mesh data about a character
  that belongs to this account, no matter how recent that data claims to be, so what you
  captured yourself always wins. Data about *other* accounts' characters syncs exactly as
  before, newest-first.
- **Note:** nothing was lost. The overwrite only ever affected the live display and the
  synced copy of a character; your **notes are stored separately and were never touched**,
  and any character that looked wrong corrects itself the next time you log into it.
- **Added:** `/nexus debug sanity` now reports how many inbound records about your own
  characters were refused. A number above zero is normal and healthy on a multi-account
  setup — it is this account correctly declining to be told about itself.

## 1.1.0 — 2026-08-04

<!-- RELEASE NOTE: the cross-account tooltips below are a new user-facing FEATURE, not a
     fix — this Unreleased section is 1.1.0-worthy rather than 1.0.2. The version bump
     itself is the release coordinator's call; nothing here forces it. -->

- **Added:** cross-account tooltips for players who use the **default Blizzard bags**.
  Hover an item and Nexus now lists every character across every account in your mesh
  that holds it, with a grand total on top and a dimmed "Other Accounts" section for
  characters on your other accounts. Hover the gold amount on your backpack (or at a
  vendor, mailbox or bank) and you get the same breakdown for money, capped at five
  characters per group with the rest rolled into "Others" and a grand total at the
  bottom. This is exactly the block Daseeki Bags has always shown — same layout, same
  portraits, same colours — so you no longer need Bags installed just to see it.
  One difference by design: Bags can tell you *where* each stack sits (equipped, bags,
  bank) because it stores every slot. Nexus stores per-character totals only, so it
  shows the count with no location icons rather than guessing at one.
- **Added:** a **"Cross-account tooltips"** checkbox under Cross-account inventory & gold
  in Settings → General, on by default. The line beneath it tells you whether the
  tooltips are live and, if not, why.
- **Note:** if you have **Daseeki Bags installed, nothing changes.** Bags draws these
  tooltips itself, so Nexus stays completely out of the way — you will never see the
  block twice — and the new checkbox reads as inactive with the reason spelled out.
- **Fixed:** Nexus threw a stream of "AddOn 'Daseeki-Nexus' tried to call the protected
  function 'SetEveryoneIsAssistant()'" errors while you were raiding in *someone else's*
  raid. Two things were wrong and both are fixed. First, "Auto-promote assistant" tried to
  flip the raid's All Assist switch — that switch is protected, meaning Blizzard reserves
  it for you personally and no addon has ever been allowed to touch it, so the attempt
  could only ever fail. Second, Nexus was running its group-assembly routine on *every*
  roster change in *any* group, including raids it had nothing to do with.
- **Changed:** the "Auto-promote assistant" option is now **"Remind me to set All Assist"**.
  Your existing setting carries over. When Nexus finishes assembling your own mesh raid and
  All Assist is still off, it prints one line reminding you to tick it in the raid menu —
  the one thing an addon is actually permitted to do here.
- **Changed:** invite-and-convert now only acts on a group *you* asked Nexus to build. The
  automatic raid convert runs only when all of the following hold: you started the invite
  from the minimap button, the dashboard, or `/nexus invite` within the last minute; you are
  the group leader; and the people in the group are your own mesh characters. Joining or
  leading anyone else's group is completely inert — Nexus does not even look at the roster.

- **Fixed:** killing a world-buff announcer looked like it had not been noticed at all.
  If the buff's own cooldown had longer to run than the announcer's 6-minute respawn,
  the timer row simply kept counting the cooldown down and never mentioned the kill —
  so a raid that had just killed Overlord Runthak saw no sign Nexus had seen it. The
  kill was in fact detected and recorded the whole time; it had nowhere to appear.
  While the announcer is down, the row now says so ("Killed · 5:58") and the cooldown
  it displaced moves to the hover tooltip, so nothing is lost either way.
- **Fixed:** an announcer kill could wipe out a live cooldown on your next login. The
  timers were rebuilt from only the newest entry in each log, so a fresh kill hid the
  buff drop sitting behind it — a real six-hour Onyxia cooldown would come back as
  "Open". Drops and kills are now restored independently.
- **Fixed:** announcer deaths broadcast by NovaWorldBuffs users were being received and
  then discarded. Nexus now reads them, with the same freshness and duplicate rules the
  reference uses, so a kill someone else witnessed reaches your timers.
- **Fixed:** an announcer was believed in the wrong city — a Stormwind announcer's death
  reported from Orgrimmar counted. Each announcer is now only trusted in its own capital,
  and the surrounding zone (Durotar, Elwynn Forest) now counts as well, so a kill at the
  city gates is no longer missed.
- **Fixed:** a buff drop now clears an older announcer kill, so the timers cannot go on
  reporting an announcer as dead after he has demonstrably come back and yelled.
- **Note:** announcer-kill detection works whoever lands the killing blow — either
  faction, and including a mind-controlled announcer killed by his own side.

## 1.0.1 — 2026-08-04

- **Fixed:** cross-account item counts stopped updating after the Daseeki Bags 2.0
  upgrade — an alt's bags would show whatever they held at the moment you upgraded, and
  never change again. Nexus decides whether Bags is already publishing your inventory
  before it starts publishing itself, and that check was reading the *addon folder name*.
  Bags 2.0 keeps the same folder name as 1.x, so every account read as "Bags is already
  publishing" and nobody published anything. Nexus now looks for the Bags 1.x publisher
  itself, which 2.0 does not ship.
- **Fixed:** accounts already stuck by the above repair themselves. The first time each
  account logs in after this update, Nexus notices it was wrongly held back, resumes
  publishing, and says so once in chat. Counts for each character refresh the next time
  you play it — one login per account is enough.
- **Changed:** `/nexus inventory` now also reports which publisher (if any) was detected
  and whether this account has been repaired, for diagnosing sync problems.

## 1.0.0 — 2026-08-03

First public release. Daseeki Nexus is a cross-account character dashboard for WoW
Classic Era: every character on every account you play appears as a card, and the cards
stay current live over a lightweight sync mesh between your own accounts.

### What you get
- **Character cards** for the whole roster — world buffs held with time remaining
  (including what is stored in a chronoboon), raid lockouts and attunements coloured by
  available / locked / unattuned, hearth, chronoboon and Darkmoon cooldowns, rest and XP,
  gold, and a free-form notes box on every character.
- **World buff timers** for Onyxia, Nefarian, Rend, Zandalar, Songflower and friends, fed
  by the same community timer mesh NovaWorldBuffs uses — so your timers agree with
  everyone else's on the server — plus a timers dock on the dashboard.
- **Felwood map pins** for songflowers, tubers and dragons, with readable countdown chips
  on the world map and minimap.
- **Instance log** with per-character visit history and live 5-per-hour / 30-per-day cap
  tracking, so you know before you zone in whether the next run will lock you out.
- **Buff rules per class** — mark which world buffs a class actually wants (a mage does
  not need Fengus' Ferocity); the held counts and the "missing" flags respect your rules.
- **Online and Summoners tabs** — who is logged in across your accounts, and who is
  positioned to summon.
- **Minimap button** — left-click invites all your online characters to a group,
  right-click opens the dashboard.
- **Importers** for ShadowNetwork and Nova Instance Tracker data, so you start with your
  existing history instead of from zero.
- **Cross-account inventory and gold**, the system of record behind Daseeki Bags'
  cross-character tooltips and totals.

### Requires
- **Daseeki Core** — the suite's shared options hub and UI foundation.
- Multi-account sync needs the one-time pairing on the Setup page (generate credentials
  on your first account, paste the bundle on the others). Single-account use works fine
  without it.

---

<!-- Everything below this line is the pre-1.0 internal development log, kept for
     reference. It is not a record of public releases. -->

## Pre-1.0 development log

- Added: **a LICENSE file — Daseeki Nexus ships All Rights Reserved**, matching the rest of the suite; the embedded LibStub, LibSerialize and LibDeflate keep their own upstream licenses.

- Fixed: **the first world-buff pull timer could throw a Lua error if you updated Nexus
  but not Daseeki Core.** The pull bar is drawn with a bar widget that arrived in Core
  2.2.0, and it was being used without checking that the installed Core actually has it —
  so on an older Core the very first Rend or Onyxia pull errored, and there is no setting
  that turns pull bars off to avoid it. Nexus now checks first: with Core 2.2.0 or newer
  nothing changes, and on an older Core the bar is drawn plainly instead — same colours,
  same countdown, same icon and label, just without the smooth drain and the spark that
  rides its edge — with one chat line telling you to update Daseeki Core.

- Changed: **the Instance Log's columns now split the table 30 / 30 / 20 / 20** — this
  supersedes the 40 / 20 / 20 / 20 split in the two entries below, in both the Rest and the
  Logs view. 40% was more room than any character name needs and it squeezed the second
  column, which is the one carrying the longest text: "Blackrock Depths" was being cut
  short with an ellipsis on every row. Character and Instance (and, in the Rest view,
  Character and Level) now share the width evenly at 30% each, Dur and Ago keep 20%, and a
  full dungeon name fits. Alignment is unchanged, and both views still share one splitter.

- Changed: **the three mesh preferences on Setup now share one row.** "Suppress
  mesh-disabled alert", "Auto-leave standard chat channels" and "Hard-throttle mesh sends"
  were split across two lines — one, then two; they now sit side by side on the same three
  columns as the Account ID / Channel / Token fields above, and drop to even spacing rather
  than colliding if a larger text size or a wider font makes a label outgrow its column.

- Changed: **the Instance Log's Logs view is spaced like its Rest view.** Character,
  Instance, Dur and Ago now take 40% / 20% / 20% / 20% of the list's width instead of the
  hand-tuned pixel widths they had, so the columns are evenly spread rather than bunched
  against the right edge, and the headers sit over them. Both views share one splitter,
  so they cannot drift apart again. An instance name too long for its column is shortened
  with an ellipsis; hovering the row still shows it in full.

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
