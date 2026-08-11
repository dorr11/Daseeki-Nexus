# CurseForge Description — Daseeki Nexus

<!-- Canonical CurseForge project description. Update here first, then paste to
     https://www.curseforge.com/wow/addons/daseeki-nexus (project 1638357).
     Last synced: 2026-08-10 (v1.1.8). -->

Daseeki Nexus is a cross-account character dashboard for WoW Classic Era. Every character on every account you run appears as a card — world buffs held (including what's stored in a chronoboon), raid lockouts and attunements, rest and XP, gold, cooldowns, and notes — kept current live over a lightweight sync mesh between your accounts.

## Features
- **NEW — Professions tracker**: every character's professions, levels, specializations, and known/missing recipes across all your accounts in one tab. Click a character for their full recipe census with search, source filters, and hover tooltips; recipe items everywhere show "Known: …" / "Learnable: …" lines (you included). Designate per-faction **primary collectors** per profession — down to specialization lanes (your Armorsmith and a future Axesmith can both stand for Blacksmithing) — and recipe tooltips call out loudly when your primary is missing one. A **shopping list** button collects the missing recipes actually buyable on the AH (and fills Auctionator's shopping tab at the auction house). Profession cooldowns (Mooncloth, transmutes, …) show who's ready to craft right now. In-window filter bar for the Blizzard tradeskill window included — MissingTradeSkillsList and ClassicProfessionFilter are fully absorbed and can be uninstalled.
- **Character cards** for your whole roster across accounts: world buffs with time remaining (boon-stored included), raid lockout status colored by available/locked/unattuned, hearth/chronoboon/Darkmoon cooldowns, rest %, gold, and a free-form notes box
- **World buff timers** — Onyxia, Nefarian, Rend, Zandalar, Songflower and friends, fed by the same community timer mesh NovaWorldBuffs uses, so your timers agree with everyone else's
- **Felwood map pins** for songflowers, tubers, and dragons with readable countdown chips, plus a timers dock on the dashboard
- **Instance log** with per-character visit history and live 5-per-hour / 30-per-day cap tracking
- **Buff rules per class** — mark which world buffs each class actually wants (a mage doesn't need Fengus' Ferocity) and the held-count and "missing" flags respect it
- **Online & Summoners tabs** — see who's logged in across your accounts and who can summon
- **Minimap button**: left-click invites all your online characters to a group, right-click opens the dashboard
- **Importers** for ShadowNetwork and Nova Instance Tracker data, so you start with your history instead of from zero
- Cross-account **inventory & gold** — hover any item or your money to see every character's counts and gold across all your accounts, **right in the default Blizzard bags** (no Daseeki Bags required; when Daseeki Bags is installed it renders these instead)
- **Auto-friend across accounts** — your characters automatically friend each other across your linked accounts (same faction/realm), so cross-account mail never trips the "unknown recipient" confirmation; anyone you remove stays removed, and Nexus never deletes a friend
- **No-click automations** (each individually toggleable): Dire Maul tribute and BWL orb gossip, Sayge's Darkmoon fortune with a per-class buff choice, repeatable turn-ins done right at the NPC — Zanza buffs (pick which flasks), Winterspring E'ko, Blasted Lands R.O.I.D.S., Zul'Gurub coins — plus invite/summon helpers and auto-repair at vendors. Every automation is locked to its exact NPC and quest IDs: nothing outside what you enabled is ever touched, and holding Shift skips any of it

## Chat Commands
- `/nexus` — toggle the dashboard
- `/nexus help` — full command list

## Requires
- **Daseeki Core** (required) — the suite's shared UI foundation
- Multi-account sync requires the one-time Setup page pairing (generate credentials on your first account, paste the bundle on the others — the Setup guide walks you through it). Single-account use works fine without it.

DISCLAIMER: I originally developed these addons for my own personal use, and am listing them on CurseForge to allow some friends to test/report bugs. The 'Daseeki' suite of addons is still very much a WIP, so please keep that in mind when downloading.
