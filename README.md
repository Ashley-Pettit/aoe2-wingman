# AoE2 Map Overlay

90,000 lines that I didn't read. But it's amazing.

<!-- screenshot: save an in-game capture as docs/screenshot.png, then replace this line with:
![AoE2 Map Overlay](docs/screenshot.png) -->

Does:

- **Map:** the map name, its resources, and how many herdables and relics it has for this map size.
- **Opponent:** their civ, how they usually open, the bonuses to watch for, and how to beat their unique unit.
- **Ratings:** your opponent's 1v1 and team ladder ratings, from the official ladder.
- **Loading screen:** a short cheat sheet for your civ and theirs while the game loads.
- **Herd and relics:** counts each sheep, pig, goose or buffalo you find, and the relics picked up.
- **Idle TC alert:** a big red warning when your Town Center stops working, and a heads-up before you get housed.
- **Scouting call-outs:** says out loud when an enemy colour shows up on your minimap.
- **Your record:** win/loss by civ, map and opponent, using results from your official match history. Also suggests map bans and shows a result card after each game.
- **Ranked party invite:** clicks through Multiplayer > Ranked > Invite To Party for everyone on your friends list.
- **Discord:** hosts a lobby and posts the join link to your channel.
- **Mod clash check:** finds enabled mods that overwrite each other's files, and which one wins.

It does not read game memory. It reads the replay file's lobby settings, the game's own data
files, the public ladder service, and text that is already on your screen.

## Run

Needs Python 3 on PATH. Double-click `AoE2 Map Overlay.bat`.

Settings (Discord webhook, friends) and stats are stored in `%APPDATA%\AoE2MapOverlay`.

## Branches

- `Prod`: the version you play with.
- `dev`: work in progress. Merge into `Prod` once tested.
