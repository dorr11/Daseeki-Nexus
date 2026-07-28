# Daseeki Nexus

Daseeki Nexus is a World of Warcraft Classic Era (Interface 11509) addon that aggregates
every character across your own accounts and trusted friends into one live dashboard —
world-buff auras and durations, chronoboon status, Darkmoon Faire fortune, raid lockouts,
item/hearthstone cooldowns, PvP/resting flags and warlock soul-shard counts — and shares
that state, plus world-buff and Felwood-node timers, over a token-gated peer mesh. This
repository currently contains Wave N1: the two-SavedVariables data store, the live character
tracker, and the mesh-protocol scaffolding (prefixes, token bucket, priority queue, chunker,
and a compact binary state schema with self-tests); the mesh comm layer, timers engine,
dashboard UI, automations, and the settings importer land in later waves.

## Clean-room provenance

Daseeki Nexus is an independent, clean-room reimplementation. It was built solely from
functional specifications describing observed behavior — no source code, assets, or
identifiers from any other addon were read, copied, or referenced. Its comm prefixes
(`DSKN0`–`DSKN3`) and binary state schema are Daseeki's own design and are deliberately not
wire-compatible with any other addon's protocol. A future importer will read the user's own
SavedVariables data (their data, never another addon's code) to migrate settings on request.
