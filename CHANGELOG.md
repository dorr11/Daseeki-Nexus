# Changelog

## Unreleased

- **⚠ ALL ACCOUNTS SHOULD RELOAD TOGETHER AFTER THIS UPDATE.** This release changes
  how the heartbeat's segment hashes are computed (they now include a coarse
  fingerprint of each character's data, not just the list of names). An updated
  client and an out-of-date one will therefore always disagree about those hashes
  and will keep asking each other to re-sync until both are on this build. Nothing
  breaks and no data is lost — the wire format itself is unchanged, and the existing
  per-target rate limits cap the churn at one manifest per 5s and one segment per
  60s per account — but until every account has reloaded there is avoidable mesh
  chatter. Reload (or relog) all of your accounts once, together, and it stops.

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
