# wow-cmangos-teldrassil (vanilla WoW server, cmangos + playerbots)

`wow-cmangos-teldrassil/wow-cmangos-teldrassil.sh`

A gum front-end for **[teldrassil](https://github.com/malahmen/teldrassil)**, a
standalone, gum-free engine for a
[cmangos-classic](https://github.com/cmangos/mangos-classic) server (vanilla
WoW 1.12.1, client build 5875) built with
[playerbots](https://github.com/cmangos/playerbots) - and for shaping the bots
that live in it. scomp-link ships only this interactive front-end; the logic
lives in the engine's own repo, the same split as
[wow-vmangos-nordrassil](wow-vmangos-nordrassil.md) (the VMaNGOS server, kept
separate) and [holo-convert](holo-convert.md).
[wow-dark-portal](wow-dark-portal.md) is the client side and serves both
servers.

## Engine resolution

The front-end finds `teldrassil.sh` automatically, in order:

1. `$TELDRASSIL_DIR/teldrassil.sh` (explicit override)
2. `../../../teldrassil/teldrassil.sh` (a local sibling checkout)
3. `~/.cache/scomp-link/teldrassil/` (a cached clone; offers `git pull`)
4. a fresh `git clone --depth 1` from the public repo (`$TELDRASSIL_REPO`
   overrides the clone URL)

All interactivity is here: answers are saved into the engine's config store
(`~/.config/teldrassil/`) with its `set` command, and each action runs the
matching flag-driven subcommand. The engine itself never prompts.

## What it does

teldrassil builds a server from nothing - pinned sources, the client's data,
the databases - and runs it in containers (a MariaDB container, a realm server
and a world server); then it manages it and its bots.

| Category | Actions |
| --- | --- |
| **Provision** | install (a short wizard - the client folder, realm name and address, how many bots - then one confirmation; steps already done are skipped), or one step at a time: sources, image, build, extract, databases, configure, containers; remove |
| **Server** | status (containers, ports, who is online, the LLM endpoint), start, stop, restart (now, or graceful: players warned, the world saved), save, the remote console |
| **Settings** | the profile (which server everything acts on: an existing one, a new one, or the base config); where the server is - here in containers, another machine in containers, or another machine in Kubernetes, each asking only its own questions; the console account; and the current settings |
| **Accounts** | create, list, set the level (0 player to 3 administrator), delete |
| **Characters** | rename (refused while the character is online) |
| **Search** | bots and characters (filters: zone, level range, class, race, guild, online, roster or random), guilds, items, NPCs, objects (herbs, ore, chests - with spawn counts), quests, teleport locations |
| **Roster** | show the shaped bots as the server has them, plan (what applying would change), check, apply |
| **Bots** | LLM chat (status, on with an endpoint and model, off - optional, and off on a new server), attunements (grant bots the raid attunements they cannot earn), the commands bots obey and who may use them |
| **Administration** | dump (all databases, one, or the accounts only), restore, apply SQL |

## Profiles: more than one server

The engine keeps one profile per server (`~/.config/teldrassil/profiles/`),
layered over its base config. Settings -> profile picks which one every
other menu acts on, and the menus and destructive confirmations name it.
`$TELDRASSIL_PROFILE` picks the starting one; after that only the menu
changes it, so "base config" really means the base config.

A profile can point at a server on another machine, over ssh, and at one run
in Kubernetes there - kalimdor on meksha's cluster, for instance. The
engine's README lists the settings; the front-end asks for them under "where
the server is". Provisioning stays a this-machine job, and the engine refuses
it for such a profile.

## Safety

- **Passwords never reach a command line.** A new account's password goes to
  the engine on stdin; the database and console passwords stay in files the
  engine reads.
- **Every destructive action asks, and defaults to no:** stop, restart,
  deleting an account, applying the roster or attunements (both stop the world
  server for about a minute), restore, apply SQL.
- **Deleting the database takes two separate yeses** (Provision -> remove), and
  recreating it (db-init) one more, each defaulting to no.
- **LLM chat is optional.** A new server starts with it off; turning it on asks
  for an OpenAI-style endpoint and a model, and an API key is given as a file
  path, never typed in.
- **Replacing the whole bot population takes two separate yeses.** Applying
  the roster can first delete every random bot, and every guild a bot leads,
  and create a new population at the roster's counts; declining the second
  question applies the roster alone.
- **The console refuses bot chat commands** (`rndbot c`, `rndbot do`): they get
  no answer from the console and have crashed the world server. Send them in
  game, as the bot's master.
- **Accounts-only dumps** leave out `realmlist`, which holds this realm's
  address: restored elsewhere, a whole realm database would send that server's
  clients here.

## Tests

`tests/test-wow-cmangos-teldrassil.sh` drives the menus through the gum stub
against a fake engine that records each call: the password reaches the engine
on stdin and in no argument; declined actions call nothing; the population is
replaced only after both yeses, and the database deleted only after both of
its own; the install wizard saves its answers and installs only when
confirmed; LLM chat is switched on with exactly the fields given, a key as a
file; search filters arrive as flags; a table-subset dump is restored with
`--db`.
