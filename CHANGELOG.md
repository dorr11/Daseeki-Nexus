# Changelog

## Unreleased

- **Added:** **the Professions tab — the half you can actually look at.** Nexus has a second
  page now, next to Characters in the title bar, and it opens on a grid: one row per
  character in the same order your cards are in, with each profession's icon, skill, its
  specialisation mark, and its cooldown right there in the cell. Beside it, every profession
  cooldown you own, across every character on every account, ready ones first and then
  whichever comes back soonest — so "what can I make today" is answered before you have
  clicked anything. The tab label carries the ready count as a small number, and once per
  login Nexus says the same thing in one quiet line of chat. No popup, no sound, and a
  checkbox in settings if you would rather it said nothing at all.

  **Click any profession cell** and the tab becomes that character's workbench: their
  professions down the left, that profession's whole recipe list on the right. Recipes you
  already know are ticked; the ones you are missing say where to get them — which trainer,
  which vendor and in which zone, which drop, which quest, which reputation. You can search
  the list, filter it to one kind of source, show only what is missing, and the handful of
  recipes that are not obtainable right now (the holiday ones) are hidden until you ask for
  them, and then greyed with the reason. **Pick a recipe you know** and Nexus adds up the
  materials against your bags: *8 / 10 Runecloth*, and beside it the alt who is sitting on
  200 of it. That last part is the whole reason both halves of this exist.

  **And there is a search box at the top of the tab: type an item and Nexus tells you who
  can make it** — who already knows the recipe, and who could learn it today because they
  have the profession and the skill for it.

- **Added:** three things this view will never do, because they were the point of building
  it carefully. It will not tell you a character is *missing* recipes on a profession whose
  window you have never opened — that profession reads **"not checked"**, with a dashed
  count and a dimmed icon, and it is left out of the missing-only list and counted separately
  in the who-can-craft search rather than quietly filed under "cannot". It will not report a
  material count of zero for a character whose bags it has never seen; that reads "?". And it
  will not invent a recipe name while your client is still loading — it says how many names
  it is waiting on, fills them in as they arrive, and then stops talking about loading.

- **Added:** an **"Announce ready profession cooldowns at login"** switch in Nexus settings,
  under the professions module and ticked by default. Untick it and the login line stops; the
  count on the tab stays. Turning the professions module itself off removes the tab entirely
  rather than leaving one that opens an empty page.

- **Added:** `/nexus debug professionsui` — what the view is showing, the cooldown rollup as
  text, and how many never-scanned professions are in the grid.

- **Added:** **Nexus has started keeping track of your professions.** This is the first half
  of the profession tracker — the half that quietly gathers the facts. There is no new tab to
  look at yet; that arrives next. What happens now is that every time you open a profession
  window on any character, Nexus writes down what that character can make, how far along the
  skill is, which specialisation they picked, and when their profession cooldowns come back
  up — Mooncloth, Cured Rugged Hide, the Salt Shaker, the transmutes — and shares it with your
  other accounts the same way it already shares gold and bags. It also notes what each recipe
  costs in materials while the window is open, because that is the only place the game will
  tell anyone. **To seed a character, open each of its profession windows once.** Gathering
  professions and skill levels are picked up on their own with nothing to open.

  Two things it deliberately will not do. It will never tell you an alt "knows nothing" just
  because you have not opened that alt's window yet — an unvisited profession reads as *not
  yet checked*, which is a different thing, and the coming views will say so in those words.
  And what goes over the mesh is tiny: your whole recipe list travels as about a hundred
  characters, at the lowest priority Nexus has, so it can never be the reason a pull timer or
  a buff warning waited. A cooldown you just used is the one exception — that goes out
  straight away, because "can I transmute today" is the question the feature exists to answer.

- **Added:** a **Cross-account professions** switch in Nexus settings, ticked by default.
  Unticking it is a real off: no window watching, no data gathered, no recipe database held in
  memory, and nothing new written to your saved data. Anything already collected is kept, so
  ticking it back on picks up where it left off.

- **Added:** `/nexus debug professions` — what the module has captured this session, which
  characters it holds records for, and the dataset it is working from.

- **Added:** **recipe items now tell you which of your characters wants them.** Hover a plan,
  pattern, formula, schematic or recipe — in your bags, at a vendor, on an auction house
  listing, on a link somebody posted in chat — and Nexus adds two quiet lines underneath:

      Known: Poonyx, Zug
      Learnable: Puucons (285/275)

  *Known* is the characters who already have it. *Learnable* is the characters who do not,
  have the profession, are high enough skill, and hold the right specialisation if the recipe
  needs one — with their current skill and the recipe's requirement, so you can see how close
  the rest are. Your own character is left out on purpose: the game's own tooltip already
  tells you whether *you* know it.

  There is a third line you will sometimes see — `(2 alts unscanned)` — and it is the most
  important one. It means exactly two of your characters have that profession and Nexus has
  never been allowed to look at their recipe list, so it has no idea and refuses to guess.
  It will never quietly file an unvisited character under "already knows it", which is the one
  mistake that would hide the very alt you opened the tooltip to find. Open that character's
  profession window once and the line goes away for good.

- **Added:** **search and filter controls on the game's own profession windows.** Open any
  profession and a slim Nexus bar sits above the window with a search box, a **Have
  Materials** tick, a category picker and an equipment-slot picker. Type "arcanite" and the
  list is just the arcanite recipes; tick Have Materials and it is just what you can make
  right now; the pickers narrow it by category or by which slot the result goes in. **Clear**
  puts everything back. The enchanting window gets the tick and the slot picker — the game
  gives nobody a way to search enchants by name, and we would rather leave a control out than
  fake one. Filters clear themselves whenever the window closes, and whenever the window
  switches to a different profession.

  Nexus does not redraw the recipe list to do any of this — it asks the game to filter its own
  list, which is why the scrollbar, the row colours, your collapsed categories and your
  selected recipe all keep behaving exactly as they always have.

- **Fixed:** **a filtered recipe list can no longer shrink what Nexus has recorded about a
  character.** When the game filters a profession window, it genuinely hands out a shorter
  list — and Nexus reads that same list to learn what you can make. Left alone, searching for
  "iron" while the window was open would have recorded that character as knowing four
  recipes. Now a filtered window is simply not read from at all: whatever was last proven
  stands untouched, and the full list is re-read the moment the filters come off, when the
  window opens, and when you close them with **Clear**. That applies to a filter you left
  behind in the game window too, not just to the Nexus bar.

- **Added:** `/nexus debug proffilters` — whether the bar is up, which controls this client
  can offer, and whether the open window is currently narrowing what Nexus is allowed to
  read. `/nexus debug tooltips` grew a matching line for the recipe lines.

- **Note for the transition:** if **MissingTradeSkillsList** or **ClassicProfessionFilter**
  are still installed, Nexus stands its own version down — the recipe lines for the first, the
  filter bar for the second — and says so once, so you never get two of anything on one
  window. Uninstall them and the Nexus versions appear on the next login.

## 1.1.6 — 2026-08-08

- **Added:** **Rin'wosho repairs your gear again.** Nexus has always been able to auto-repair,
  but only on a vendor window *you* opened — walk up to Rin'wosho the Trader in Zul'Gurub,
  hand in your Honor Token, and the repair half simply never happened, because nothing ever
  opened his shop. It does now. On a visit where there is no turn-in waiting — no token in
  your bags, nothing he is offering that Nexus handles, or the Zanza automation switched off —
  and something you are wearing is damaged, Nexus picks his "browse your goods" line itself,
  repairs everything from your own gold, tells you what it cost, and closes the shop again.
  A turn-in always wins the visit: if you are holding a token, the token goes in and the
  repair waits for the next time you talk to him. Holding **Shift** skips the whole thing, as
  it always has. Nexus only ever closes a shop window it opened itself — a vendor pane *you*
  opened is still yours to close, at Rin'wosho or anywhere else. Needs "Auto-repair" ticked
  in Automations — see the next entry, it now starts ticked.

- **Changed:** **auto-repair now ships on — untick it if you'd rather pay attention to your
  own durability.** "Auto-repair at vendors" used to start switched off, because it spends
  your gold and that felt like something to opt into. It now starts on, so opening any
  vendor's window repairs your gear from your own purse and prints what it cost. If you had
  never touched that checkbox, it switches itself on once when you next log in; if you had
  ever ticked or unticked it yourself, your setting is left exactly as you left it and
  nothing changes. Holding **Shift** still skips it, and unticking it in Automations is
  final — Nexus will not turn it back on a second time.

- **Fixed:** **visiting your mailbox no longer wipes the mail out of your inventory.**
  Nexus keeps a note of what is sitting in each character's mailbox, because the mailbox is
  only readable when you are standing at one — that note is how an item in the mail still
  shows up when you search your alts. The trouble was that Nexus also took a reading at the
  moment the mailbox *closed*, when the game has already stopped answering questions about
  it. The answer it got back was "nothing in there", and Nexus wrote that down as fact and
  sent it to your other accounts. So every single mailbox visit ended by deleting the mail
  half of that character's inventory. Nexus now knows the difference between an inbox that
  says "empty" and one that is not talking to it: it only records an emptying while the
  mailbox is genuinely open and has actually answered. Taking everything out of your mail
  is still recorded the instant you do it — that is a real change, and it always lands.
- **Fixed:** **zoning into a dungeon no longer records you as "Level 0" in your own run.**
  Nexus already refused to write down a groupmate whose character had not finished loading,
  because a level of 0 is the game saying "not loaded yet" rather than a real level. It was
  applying that rule to everyone except you. Walk through a portal and Nexus could take the
  group photograph before your own character had finished arriving, and your name went into
  that run's roster at level 0 with no class colour. It usually corrected itself within a
  few seconds, but a short run could close with it still there. You are now held to the same
  standard as everyone else in the group: your row is written when it is real, not before.
- **Fixed:** **other characters on your account are found sooner after login.** Nexus
  discovers your other accounts by looking at who else is on its private channel, and it
  does that sweep at most once a minute so it can never spam anyone. The bug was that a
  sweep which did nothing at all — because the channel had not finished connecting, or
  because the server had not yet sent the member list — still counted as that minute's
  sweep. On a slow login that meant a full minute of silence before Nexus looked again, and
  on a short session or a quick reload that was the whole window. Only a sweep that actually
  read the channel now counts, and the moment the server delivers the member list Nexus
  looks straight away instead of waiting.
- **Fixed:** **logging out no longer turns your character into a classless "Level 0" on
  every roster.** Nexus takes one last photograph of your character as you log out or zone,
  and that photograph is both what gets saved to disk and what gets sent to your other
  accounts. The problem is that the game has already started packing up by then: asked for
  your level it answers 0, asked for your class it answers nothing, and asked for your
  faction it answers nothing — and Nexus wrote all three down as if they were facts. So the
  last thing every session recorded, and broadcast, was a level-0 character with no class
  colour and no faction, and that is what you and everyone else saw on the next login until
  the character logged in again and fixed itself. The same shutdown reading was also
  emptying a warlock's soul shards ("0" in red on every card, even holding a full bag),
  reporting a warlock with a soulstone in their bags as having none, and quietly deleting
  the countdown on a PvP flag. Nexus now refuses to write any of it: a reading taken while
  the game is shutting down or still loading is treated as *no answer*, and no answer never
  overwrites what is already known. A genuine change — a level-up, spending your last shard,
  a flag that really drops — still records instantly, exactly as before. This one had already
  been fixed for XP and rested; it is now fixed for everything beside it.
- **Fixed:** **a raid lockout you earn during a session now shows up without relogging.**
  This was the big one. Nexus asked the server for your saved-raid list exactly once, at
  login, and then waited to be told when it changed — but nothing ever asked again, so the
  server never had a reason to say anything. Kill Lucifron after logging in and your Molten
  Core row stayed on "not saved" for the rest of the session, on your own roster and on every
  other account's, and the thirty-second background refresh could not help because it was
  re-reading the same unchanged list. Nexus now asks again at the moments that can actually
  change a lockout: when a boss dies, when the instance tells you its reset timer, and when
  you cross in or out of an instance — plus a quiet re-check every minute while you are
  standing in a raid, in case a kill goes unannounced. Your lockouts now appear on other
  accounts' rosters within seconds of earning them. If you want to watch it work,
  `/nexus debug lockouts` shows what was asked, what answered, and what is currently held.
- **Fixed:** **an unanswered server can no longer wipe the lockouts Nexus already knows about.**
  The list of saved raids reads as *empty* both when you are genuinely saved to nothing and
  when the server simply has not answered yet — and now that Nexus asks far more often, the
  second case comes up far more often too. An empty list is only treated as an answer once the
  server has actually spoken; before that, whatever Nexus already holds stands. A real reset
  still clears the row exactly as before.
- **Fixed:** **a party member who was still loading no longer gets recorded at level 0.**
  The group for a dungeon or raid run was photographed the instant you finished zoning in,
  which is the one moment the game has not finished loading everybody yet — so a member could
  be written into that run's roster with no level and no class colour, and if nobody joined or
  left for the rest of the run there was never a second photograph to correct it. A reading
  that has not loaded yet is no longer treated as a fact: Nexus waits, re-checks a few times
  over the following seconds, and also re-checks whenever a group member's level arrives.
  Members already recorded are untouched, and old run history is unaffected.
- **Fixed:** **a run no longer reports costing you every copper you owned.** The gold figure
  for a run is the difference between your purse on the way in and on the way out, and the
  reading on the way out is taken during a loading screen, where your purse can briefly read
  as zero. Walk out of Molten Core with 500 gold and the run could be recorded as having cost
  you 500 gold. Nexus now follows your purse as it changes and refuses to record a difference
  built on a reading it cannot trust — the loot total, which was always the honest number,
  carries the run instead.
- **Fixed:** **Battle.net friends now register even if Battle.net connects after you log in.**
  Nexus read your Battle.net friends' characters once at login and then only when one of them
  changed something. If Battle.net had not finished connecting yet — common — the list came
  back empty and nothing ever went back for it, so for that whole session an invite from a
  Battle.net friend's character was treated as coming from a stranger. Nexus now notices the
  connection arriving and re-reads then, and the login retry sequence covers Battle.net as
  well as your guild.
- **Fixed:** **a warlock's soulstone status and your current sub-zone update promptly again.**
  Two small ones with the same cause. When a Create Soulstone cooldown finished, nothing told
  Nexus, so other accounts could show the stone as unavailable for up to half a minute after
  it was ready. And moving between sub-zones without changing zone — walking into the
  Crossroads inn — did not refresh your location for the same reason. Both now update as soon
  as they happen instead of waiting for the background refresh.
- **Fixed:** **the one character that would not sync now goes to the front of the queue.**
  When your accounts were fully caught up except for a single character, Nexus already knew
  how to ask for just that one — but it had no idea which order to send the answers in, so the
  reply it built was shuffled fresh every time. Nexus only sends about one message a second,
  so position in that queue is the whole wait: the character you were actually missing could
  sit near the back, and if the exchange was interrupted — a relog, a dropped message, or
  simply the next round starting before the last one finished — the reshuffle put it somewhere
  else entirely. A character could stay stale for hours that way while everything around it
  updated fine. Answers are now ordered by who needs what most: characters the other account
  holds **nothing** for go first, then the ones it is furthest behind on. In the common case —
  one character out of date — that character is now the very first thing sent.
- **Fixed:** **duplicate world-buff announcements to your guild.** When two of your accounts
  both decided they were the one who should relay a buff timer, each was supposed to notice the
  other's copy and stand down. The check compared the two messages by their compressed contents,
  which — for reasons invisible from the outside — could differ between two machines holding
  *identical* timers. So the check never matched and the stand-down never happened: your guild
  got the same announcement twice. The comparison now looks at what the message actually says
  rather than how it happened to be packed, so the second copy is dropped as intended.
- **Fixed:** **an account that appeared online and offline at the same time.** If Nexus had
  ended up with two entries for one character, going offline correctly marked both — but coming
  back only ever revived one of them, and which one changed from session to session. The result
  was a status light that flickered between online and offline for no visible reason. Returning
  from offline now revives every entry, matching what going offline already did.
- **Changed:** **the order Nexus sends things in is now fixed instead of arbitrary.** Settings
  pushes, blacklist syncs, timer requests, the "Sync now" button and the login publish all used
  to visit your accounts in whatever order happened to come up, which meant that when something
  had to be skipped — a rate limit, a busy queue — *which* account got skipped was a coin flip
  that landed differently every session. All of them now follow one consistent order. Nothing
  about the messages themselves changed and no update is required: an account still on 1.1.5 or
  older talks to an updated one exactly as before, because this only affects the order a sender
  chooses, never what a receiver reads.
- **Fixed:** **a character that exists under two of your account IDs now shows the same copy
  everywhere.** If an account was ever re-set up under a new ID, Nexus can end up holding two
  stored copies of one character. Three places on the dashboard each picked one of those copies
  independently and each picked arbitrarily — so the roster card could show today's data, the
  detail pane you opened by clicking that very card could show a copy from two weeks ago, and
  the rest/XP meter beside it a third — and which one you got changed between sessions. All
  three now ask the same question and get the same answer: the copy the owning account stamped
  most recently. Nothing is deleted; only which copy is *displayed* was ever at stake.
- **Fixed:** **an imported instance run no longer changes which account it belongs to.** Runs
  imported from NovaInstanceTracker are matched to whichever of your accounts owns that
  character — and when a character existed under two account IDs, the match was decided
  arbitrarily and could land differently on a later import, moving the run (and the hourly
  instance count it contributes to) from one account to the other. The owner is now decided by
  a fixed rule, so a re-import attributes every run exactly where the first one did.
- **Fixed:** **the Herald of Thrall can no longer be mistaken for Thrall himself.** When a
  world-buff announcer's name arrives with anything extra attached to it, Nexus matches it
  against the names it knows — and "Thrall" is contained inside "Herald of Thrall", so both
  matched and the winner was arbitrary. The two are not interchangeable: they raise different
  Barrens timers, and the wrong one goes out to everyone on the mesh. The most specific name
  now wins, always.
- **Fixed:** **a very large guild or friends list no longer rewrites your saved data on every
  update.** Nexus keeps up to 800 names in the trust list used for invites and summons. Past
  that number it kept an arbitrary 800, freshly re-drawn each time — so the check that asks
  "has anything actually changed?" always answered yes, and every friend logging on or off
  rewrote the file for nothing. The same 800 are kept every time now, so an unchanged list is
  correctly recognised as unchanged. (Below 800 nothing was ever wrong.)
- **Fixed:** **a very large auto-friend history no longer judges a different slice of itself
  each session.** The auto-friend ledger stops looking after 800 entries, and *which* 800 was
  arbitrary — which matters because the decision made there is permanent: an entry that has
  used up its attempts is marked as never-to-retry. Above that size the same ledger could
  sentence a different portion of itself on each login, and an entry could go permanently
  unexamined. It now always works through the same 800.
- **Changed:** **`/nexus debug instances` prints in a stable order.** Accounts come out in
  account-ID order and characters alphabetically, so two runs of it — or the same command on
  two accounts — can actually be compared line for line. Output content is unchanged.

## 1.1.5 — 2026-08-07

- **Fixed:** **an account's own data can no longer lose to a stale copy of itself.** If Nexus
  had somehow stored a damaged record for one of your other accounts' characters — a wiped
  boon list, a half-captured login snapshot — and that record happened to carry a *newer*
  timestamp, the real account's own data was thrown away every time it arrived, forever. The
  only way out was to hover the character and force a re-read. Bulk data that comes **from the
  account that owns it** now overrides what we hold, whatever the timestamps say. Everything
  else is unchanged: a character of *your* account is still never overwritten from the network
  no matter who sends it, and data relayed by a third account still has to win on timestamp
  the way it always did — an account can only claim ownership of characters it actually owns,
  and the claim is checked against who really sent the message.
- **Fixed:** **two fully-synced accounts stopped quietly re-asking each other for data they
  already had.** A Nexus that merely *caches* another suite addon's shared data (say, an
  account without Bags installed holding everyone's Bags data) never advertised it, so its peer
  read "we disagree" on every heartbeat and both sides re-negotiated every two minutes, forever,
  for nothing. Each side now advertises everything it actually holds, so a converged mesh goes
  quiet. First-contact syncing is untouched: a peer that has never seen a namespace still pulls
  the whole thing.
- **Added:** **you can now see how long another account's Darkmoon fortune cooldown has left.**
  Nexus knew whether a character of yours on another account was waiting on Sayge — it just
  could not tell you *how long*, so every one of them read a flat "On CD" until it wasn't. The
  remaining time now travels with the rest of the character's data and the cooldown row shows a
  real countdown, in the same place and the same style as the hearthstone and chronoboon rows
  right beside it. It keeps ticking between updates instead of sitting frozen, and it holds
  still while the character is offline or has the fortune stashed in a chronoboon — because in
  both of those cases the game isn't running the cooldown either. A character on an older
  version of Nexus still shows the plain "On CD" it always did.
- **Changed:** **the character-data format moves to version 3** to carry that countdown.
  Everything else on the wire is byte-for-byte where it was, so nothing else about your data
  changes and nothing needs converting. **Update every machine you run Nexus on.** A copy still
  on 1.1.4 or older will not read character updates from a copy on 1.1.5 until you update it —
  it keeps its last-known data and its own updates still reach you, so it goes quiet in one
  direction rather than breaking. If all your accounts share one AddOns folder they all update
  together and you will never see this.
- **Fixed:** **an account's own live updates can no longer lose to a stale copy of themselves.**
  The same repair as the bulk-data fix above, now applied to the moment-to-moment updates too:
  when the account that owns a character sends its own update directly, it is trusted over
  whatever we are holding, whatever the timestamps say. An update *forwarded* by a third
  account still has to win on timestamp — anyone in the middle could have changed it — and a
  character of your own account is still never overwritten from the network.
- **Changed:** `/nexus debug mesh` gains an **owner-relay** line (claims received, stale records
  repaired, claims that failed the sender check).

## 1.1.4 — 2026-08-05

- **Changed:** **the buff automations now ship switched ON.** Dire Maul tribute, the BWL Orb of
  Command, Sayge's Dark Fortune, Winterspring E'ko, Blasted Lands R.O.I.D.S. and the Zanza
  turn-in were all off out of the box, so the feature you installed Nexus for did nothing until
  you found six checkboxes. Every one of them is now scoped to its own NPC and steered by quest
  ID — that work landed in this same release — so they only ever fire where they are supposed
  to. If you had deliberately switched one of them off, it stays off; if you never touched it,
  it is switched on once.
- **Changed:** **Zanza ships asking for Swiftness and Spirit.** Sheen is not ticked by default —
  tick it if you want it, and it will never untick itself. Everything the fortune, tribute and
  turn-in flows do is still skipped by holding Shift as you click.
- **Changed:** **an empty Zanza flask list now means "none", not "all three".** It used to mean
  all three, which is why unticking every box silently gave you everything. Your picks are
  stored properly now, so clearing them all switches the turn-in off, which is what it looks
  like it does. Ticking a flask box also pins your choice, so nothing ever ticks one back on.
- Untouched on purpose: **auto-repair, the Yojamba coin turn-in, "skip fortune cookie", and the
  two "whisper my keyword to guild / friends" gates all still ship OFF.**

- **Fixed:** **releasing a chronoboon could auto-accept the next summon.** When you popped your
  displacer, all seven buffs came back at once — and Nexus read that as seven brand-new world
  buffs and armed the "you just got buffed, take the summon" gate. Any summon that landed in
  the next 19 seconds was accepted for you, from anywhere, whether you wanted it or not. Buffs
  coming back out of a boon are now recognised as *restored*, never as freshly gained, and the
  three seconds either side of the release are covered too.
- **Fixed:** **a re-applied buff never counted as fresh.** Only going from *no buff* to *buff*
  did — so standing under the Songflower you just picked up, or taking a second Rend, did
  nothing for auto-accept. A buff whose timer jumps forward by more than 75 seconds now counts,
  which is what "fresh" was always supposed to mean.
- **Fixed:** **one fresh buff could accept every summon for 19 seconds.** The fresh-buff flag
  was never cleared, so a second (or third) summon inside the same window rode in on the same
  buff. Accepting now uses the flag up: the next summon needs a genuinely new buff.
- **Fixed:** **the Fire Festival Fury trigger could never fire.** It was looking for a buff
  name that does not exist in the game, so ticking that box did nothing — in the summon
  triggers and on the HUD's cancel button alike. Both now use the real name.
- **Changed:** the auto-accept message now names **which buffs** triggered it instead of a
  single word, so you can tell why your character just left town.
- **Changed:** buff triggers are now matched by **spell ID first**, so they work on a
  non-English client instead of silently matching nothing.
- **Changed:** **"Drop on taxi / PvP" now ships OFF,** which is what it was always meant to be.
  Left on, it accepts *any* summon that arrives while you are on a flight path, buffs or no
  buffs — the one automation default that erred toward doing more. If you never touched the
  box it will be switched off once; if you deliberately turned it on, it stays on.
- **Fixed:** **mass invites went out all at once.** Every invite fired in a single frame, which
  is exactly the burst the client throttles, and the raid conversion could race the fifth
  invite. Invites now go out 60 ms apart with the fifth held back to 700 ms, the way the
  timing was designed.
- **Fixed:** **"Invite Online" missed characters and included the wrong ones.** It only ever
  looked at live mesh peers — so an online alt that was not currently a peer never got asked —
  and it did not check faction, did not skip people already standing in your group, and went
  out in whatever order the table happened to be in. The target list is now your database and
  your mesh roster together, filtered to your faction, minus yourself and anyone already
  grouped, in alphabetical order.
- **Added:** **the reverse invite.** If every single invite comes back "already in a group" and
  you are on your own, Nexus now drops your empty party and whispers your invite keyword to
  the first of them, so whoever already built the group invites *you* instead of the run just
  reporting failure.
- **Fixed:** **the leader hand-off never worked.** When someone whispered your keyword but you
  could not invite — in a raid without assist, or in a party you do not lead — Nexus was
  supposed to point them at whoever actually holds the group. It was reading a setting that
  had no default and no box anywhere in the options, so it was never anything but empty. It
  now finds the real group leader, and hands the name over **only if that leader is one of
  your own mesh characters** — a stranger leading your pug is never named to a stranger
  whispering you.
- **Fixed:** **copying automation settings between factions overwrote things it should not
  have.** The destination faction's invite-whitelist master switch could be silently flipped,
  and the one-time "defaults already seeded" markers were reset — which meant a whitelist you
  had deliberately cleared, or buff triggers you had deliberately unticked, could come back on
  your next login. The copy now leaves all of that alone; it copies settings, not history.

- **Fixed:** **"accept invites from guild members" and "from friends" never accepted anyone.**
  Both boxes ship ticked, and both were reading a list of your guildmates and friends that
  nothing in the addon ever filled in — so the answer was always "I don't know them". A
  guildmate or a friend inviting you was silently ignored, with the setting showing as on,
  and the same two categories were dead for whisper-keyword invites. Nexus now captures your
  guild roster and your friends list (including a Battle.net friend's current character) and
  keeps them current, so those four settings finally do what they say.
- **Added:** the capture **refuses to guess.** Both lists live on the server and read as empty
  for the first seconds after you log in — that is "not told yet", not "you have no friends".
  Nexus writes a snapshot only once the server has actually answered; until then it keeps
  using the last one it confirmed, so a slow login can never quietly revoke everybody's
  trust for a session. Leaving a guild, by contrast, drops that roster immediately.
- **Added:** `/dsn debug social` — how many names are in each list, how long ago they were
  captured, and (with a name after it) exactly what the invite gate would decide about that
  person and why.
- **Changed:** Nexus now asks the server for your friends list on login even when
  "auto-friend mesh characters" is switched off. Asking changes nothing on its own; it used
  to be skipped with that setting, which left the friends trust list permanently in the dark.
- **Fixed:** **the Dire Maul and Blackwing Lair gossip options could fire at any NPC in the
  game.** With either box ticked, Nexus looked for words like "spare", "free" and "enter"
  in the menu of *whatever* you were talking to — and those are ordinary words that turn up
  in ordinary Classic gossip. An innkeeper, a quest giver or a vendor could have their first
  matching option clicked for you, which at worst means accepting a quest or starting an
  escort you never asked for. Nexus now checks **who you are talking to** before it does
  anything: the four Dire Maul tribute guards, Captain Komcrush and the Orb of Command, by
  ID. If it cannot tell who the NPC is, it does nothing. The word-matching is gone entirely.
- **Added:** the guards those two features were always supposed to have. Captain Komcrush is
  only auto-answered when his menu has **exactly one** option, so the flow can no longer eat
  the quest he offers, and the **Orb of Command** is only used when it presents a single
  option *and* you are not on any of the three quests that conflict with it.
- **Fixed:** **Sayge's fortune could not be configured.** The per-class dropdown showed
  "Damage" as if that were your setting, but nothing was actually stored, so the automation
  looked your class up, found nothing, and quietly did nothing at all. Damage is now the
  real, stored default for all nine classes — and if the setting is ever missing, the
  automation falls back to Damage rather than going silent.
- **Fixed:** Sayge is now answered by **which option is where on the page**, the way the
  fortune actually works, instead of by searching his answers for the word "armor" or
  "spirit" — his answers are riddles and mostly do not contain the word at all. Damage takes
  the fast path; every other buff is picked by position on each of the two pages.
- **Added:** **Sayge refuses rather than guesses.** If his menu ever comes up in a shape
  Nexus does not recognise, it takes no fortune, says so in chat, and points you at
  `/dsn debug gossip` — which prints the exact options so the mismatch can be fixed. The
  fortune is permanent for the day, so a missed one costs you a click and a wrong one costs
  you the day.
- **Changed:** holding **Shift** as you open a gossip window now demonstrably skips the Dire
  Maul, Orb and Sayge handlers too, not just the quest turn-ins — one modifier, no
  exceptions to remember.
- **Changed:** **"Auto-repair at Rin'wosho" is now "Auto-repair at vendors",** because that
  is what it does. It repairs at any vendor window you open, anywhere — that behaviour is
  staying, but the old label described a scope the feature never had.
- **Added:** auto-repair now **prints what it spent**, and says **"not enough gold"** with
  the price when it cannot afford the bill. It used to do neither, so an unaffordable repair
  was indistinguishable from a broken feature.
- **Fixed:** **a flask you unticked could still be handed to you.** The per-flask
  checkboxes and the automation were storing your choices in two different formats: an
  older build saved them as a list of yes/no answers, the current one saves the ticked
  names, and a save that had been through both ended up holding a mixture. The engine only
  understood one of those formats, read the other as "nothing recorded", and fell back to
  its "no picks means all three" rule — so a Sheen you had deliberately unticked came back.
  Nexus now repairs the stored list **once**, on the next login, in every faction's
  settings, and tells you in chat when it does. Your unticks survive the repair; that is
  the whole point of it. If it turns out every flask was unticked, the **Zanza buffs**
  parent checkbox is switched off rather than silently re-enabling all three, and the chat
  line says so.
- **Fixed:** the automation also reads the old formats directly now, so an unticked flask is
  refused even in the one session where the repair has not run yet, and the generic
  "choose the reward that matches your priorities" path can no longer fall through to
  "just take the first one on the board" when it meets an old-format list.
- **Fixed:** **the Zanza buff turn-in never ran at Rin'wosho.** Rin'wosho hands his quests
  out through the *gossip* window — the same menu his vendor option sits on — but Nexus
  only ever picked quests off the older "quest greeting" list, and its gossip handler knew
  about Dire Maul, Blackwing Lair and Sayge and nothing else. So the flow was not refusing
  to run, or running and failing: it was **never starting**. Nexus now reads the quest
  lists on the gossip window itself and takes the turn-in from there, so walking up to
  Rin'wosho with a Zandalar Honor Token does what the checkbox always promised.
- **Added:** the whole set of guards the turn-in is supposed to carry. It only ever touches
  quest **8243** — the two other quests Rin'wosho offers are never auto-progressed — and it
  needs a Zandalar Honor Token in hand. Rewards go **Swiftness → Spirit → Sheen**, each one
  individually tickable, and that order is now fixed no matter what order you ticked the
  boxes in. **Leaving all three unticked means all three**, so turning the feature on is
  the only setup it needs.
- **Added:** **flasks sitting in your bank count as owned.** Nexus takes a snapshot of your
  bank whenever you open it and keeps it for the rest of the session, so it will not hand
  you a second Swiftness when one is already banked. That snapshot is **never written to
  disk** — a reload or relog forgets it entirely, and it comes back the next time you
  visit a bank.
- **Added:** a full bag guards nothing when you are holding exactly one token (the turn-in
  frees the slot in time), but a full bag with a **spare** token correctly refuses.
- **Added:** if the server refuses a reward, that flask is set aside for 30 seconds and an
  immediate re-open walks to the **next** one on your list instead of retrying the one that
  just failed. Delivery is confirmed by watching for the item to actually land, with a
  5-second backstop — you get a chat line either way.
- **Added:** if you already hold **every** flask you have enabled, the reward window is
  **left open** and Nexus watches your bags — drink one and the replacement is taken
  automatically, with no need to talk to Rin'wosho again.
- **Added:** holding **Shift** as you open the gossip window skips the whole thing, exactly
  as it does at Mau'ari, Vinchaxa and Drazial.
- **Fixed:** "zulian", "razzashi" and "hakkari" were being treated as Zanza keywords. They
  are the three **coins** of the third Zul'Gurub coin turn-in and have nothing to do with
  Rin'wosho; a coin hand-in could pull the Zanza reward priority onto it. They now live
  with the other coins, and the coin turn-ins pick by quest ID with the priority the coins
  you are actually carrying decide — highest-priority complete set first.
- **Fixed:** **the Winterspring E'ko and R.O.I.D.S. turn-ins were two words each and
  nothing else.** Both features were steered entirely by looking for a word in a quest
  title — "e'ko" for one, "roids" for the other — with no idea which NPC they were talking
  to, how many E'ko you were carrying, or which quest was which. Both now know exactly what
  they are doing, by quest ID.
- **Added:** **E'ko is turned in the way it is meant to be:** the first type you are
  carrying **three or more** of, in the order Frostmaul → Winterfall → Chillwind →
  Shardtooth → Ice Thistle → Wildkin → Frostsaber, and only at **Witch Doctor Mau'ari**.
  Two of a type is no longer enough to start a turn-in that cannot finish, and holding
  several types no longer means whichever one Mau'ari happened to list first.
- **Added:** **R.O.I.D.S. checks that you can actually complete it before it starts.** It
  needs **3 Snickerfang Jowls, 2 Blasted Boar Lungs and 1 Scorpok Pincer** — the counts
  matter, one of each is not enough — it only runs at **Bloodmage Drazial**, it takes the
  **two interactions** the quest really needs (accept on the first, hand in on the second),
  and it takes the R.O.I.D.S. itself by item, not by "whatever is first on the board".
- **Added:** a **full bag** no longer costs you the reward. R.O.I.D.S. proceeds on a full
  bag only when at least one of the three reagents is held at exactly the required count —
  that stack is used up by the turn-in and frees the slot in time — and refuses when every
  stack has spares and nothing would be freed.
- **Added:** both turn-ins now use the same safety net as the Zanza flow. A hand-in that
  the server refuses is set aside for **30 seconds**, and for E'ko an immediate re-open
  walks to the **next type** you are carrying rather than retrying the one that just
  failed. Delivery is confirmed by actually watching your bags — the R.O.I.D.S. arriving,
  or the three E'ko leaving — with a 5-second backstop, and you get a chat line either way.
- **Fixed:** **both features could have been doing nothing at all in-game.** They only ever
  looked at the older "quest greeting" list; if Mau'ari or Drazial hand their quests out
  through the **gossip** window instead — which is exactly what turned out to be true of
  Rin'wosho — the flow was never entered. Both windows are now wired for both NPCs, so it
  no longer matters which one they use.
- **Changed:** holding **Shift** as you open either window still skips both flows, and
  quests these features do not own are now left strictly alone: with a quest on screen that
  Nexus can identify as not one of its own, it will not accept, complete or take a reward
  for it, whatever the quest happens to be called.

## 1.1.3 — 2026-08-05

- **Fixed:** **one character's bags could stay wrong on another account for hours, even
  with both accounts logged in the whole time.** A character published new bags (gold up
  from 15,144 to 22,144); the account that was meant to receive it missed that single
  update — an ordinary dropped message — and then never caught up, holding the older
  copy for the better part of a day. The catch-up path was the problem. Accounts notice
  they disagree about a character, and the one that is behind asks for the data; the
  answer used to be **every character in the namespace**, dozens of full bag payloads,
  sent down a link that carries about one message a second. That takes many minutes, and
  the "don't answer this again" window was only fifteen seconds — so every twenty seconds
  another complete re-send piled up behind the one still going out, the queue grew faster
  than it drained, and which character actually made it through was luck. **The account
  that is behind now says exactly what it already has, and gets back only what it is
  missing** — in the case above, one character's bags instead of forty-four. The two
  "don't repeat yourself" windows either side are now two minutes, comfortably longer
  than an answer takes, and the same payload can no longer be queued twice while a copy
  of it is still waiting to go out.
- **Added:** `/nexus debug mesh` prints an `ns-backfill` line — how many catch-up answers
  were targeted versus full re-sends, how many characters were actually sent versus
  skipped as already-current, and how many duplicate sends were suppressed. On two synced
  accounts the targeted count should climb while the full-resend count stays at zero;
  a non-zero full-resend count means a peer is still running an older build.
- Older and newer builds interoperate in both directions with no version bump: an older
  account asking for a catch-up still receives the full re-send it expects, and an older
  account answering one still replies with everything, which the newer side filters on
  arrival exactly as it always did.
- **Added:** **every character in your mesh is now on every character's friends list,
  automatically.** Shortly after you log in, Nexus adds each mesh character that belongs
  to one of your OTHER accounts — same faction, same realm — to this character's friends
  list, once. Nothing has to be configured and nothing has to be mailed first: by the time
  you want to send something, the recipient is already a friend, so Blizzard's "are you
  sure you want to mail this stranger?" confirmation never appears for any of your own
  characters. New characters joining the mesh later are picked up as they appear. It is
  under **General → "Automatically friend your other accounts' characters"** and ships on.
- **Added:** the auto-friend pass **never re-adds anyone you have removed.** If you take
  one of these characters off your friends list, that is remembered permanently for that
  character and Nexus leaves them alone from then on — and the same applies to anyone
  Daseeki Conduit had already put there, whose record Nexus reads and honours. Nexus never
  removes a friend, never touches your ignore list, and stops quietly if your friends list
  is full. Characters on the account you are currently playing are excluded (that is
  answered from the mesh's account map, never guessed from names), as is anyone whose
  faction Nexus has not actually seen.
- **Added:** `/nexus debug friends` shows the setting, whether the friends list has been
  confirmed by the server yet, how full it is, how many names Conduit's record is holding
  back, and exactly what the next pass would do to each mesh character, with the reason.

- **Fixed:** **a fully booned character could suddenly show no world buffs at all.** Every
  so often the character you were logged in as dropped its whole rack in Nexus — all the
  world-buff tiles empty — even though the chronoboon was still holding seven buffs, and
  hovering the chronoboon brought them straight back. Nexus reads what is inside your boon
  off the chronoboon's tooltip, and a tooltip that has not finished loading shows its
  title and nothing else. Nexus could not tell that apart from a boon that had genuinely
  been emptied, so it believed the empty reading, wiped the buffs from your record and
  published the wipe to your other accounts. **An empty reading is no longer allowed to
  delete anything unless the emptiness is provable** — the chronoboon really is gone from
  your bags and bank, or the tooltip really did load and really does list nothing. A
  reading Nexus cannot trust keeps the buffs it already had instead of erasing them, and
  quietly asks the game to load the item so the next look is honest.
- **Fixed:** the same protection now guards the record itself, not just the tooltip read.
  While the Chronoboon Displacement buff is on your character the stored buffs are, by the
  rules of the game, still in there — so **a capture that has lost its own copy of the
  list now rebuilds it from your record rather than writing you down as unbuffed.** This
  covers the case where the list is missing for any reason at all, including the first
  moments after a login.
- **Added:** `/nexus debug sanity` reports the new rule — how many empty chronoboon
  readings were refused (and how many of those were provably a cold tooltip), how many
  were honoured, and whether the buff list Nexus is currently holding is a fresh reading
  or preserved evidence.
- **Added:** **Felwood node timers now show on the minimap**, not just on the world map.
  Songflower, tuber and Night Dragon's Breath minimap pins each carry the same dark
  countdown chip the world map pins got — sitting just above the pin, in the same colour
  the timers panel uses for that node, so a glance at the minimap tells you how long a
  flower has left without opening the map. The chip is sized down to suit the minimap, and
  a pin sitting right at the top edge puts its chip underneath itself instead of off the
  minimap. Pins with nothing to count down (available, or no data) show no chip at all,
  exactly as before.
- **Fixed:** the Felwood pin-size sliders could appear to do nothing on some profiles. The
  sliders read your saved size from three possible keys, but the pins themselves only ever
  read the first one — so a size carried in from an import (or written by an older build)
  showed in the slider while the pins stayed at the default. **The pins now read the size
  the same way the slider does.**

## 1.1.2 — 2026-08-04

- **Fixed:** a **gold-only change could go missing on your other accounts.** Take money
  out of the mailbox (or sell to a vendor, finish a trade, collect an auction) and nothing
  moves except your gold — no bags change, nothing is equipped. Nexus captured the new
  amount correctly on the character itself, but the update could sit unsent for minutes
  behind a queue of bulk catch-up traffic, so the other accounts' cards and tooltips kept
  showing the old number. **A gold change is now published like any other change and gets
  ahead of the bulk backfill**, so the new amount reaches your other accounts within
  seconds. This is the behaviour Daseeki Bags had before the rebuild, where gold had its
  own dedicated push.
- **Fixed:** Nexus republished your whole inventory record every time *anything* nudged
  it, even when nothing had actually changed. That churn is what filled the queue the
  gold update was stuck behind. **Nexus now compares what it just captured with what it
  last sent and stays quiet when they match** — gold is part of that comparison, so a
  gold-only change always counts as a change. Less traffic, and real updates arrive
  sooner.
- **Added:** `/nexus debug inventory` now shows the money side of the story on one line —
  the gold your record currently holds, the gold a fresh look would find, and whether
  Nexus considers that a change worth sending. `/nexus debug inventory push` forces a
  republish of the character you are on.

## 1.1.1 — 2026-08-04

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
