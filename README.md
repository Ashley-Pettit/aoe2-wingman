# AoE2 Map Overlay

90,000 lines that I didn't read. But it's amazing.

<!-- screenshot: save an in-game capture as docs/screenshot.png, then replace this line with:
![AoE2 Map Overlay](docs/screenshot.png) -->

Does:

- **Map:** the map name, its resources, and how many herdables and relics it has for this map size.
- **Opponent:** their civ, how they usually open, the bonuses to watch for, and how to beat their unique unit.
- **Opponent's own openings:** reads your opponent's last few public games and shows how that player actually opened in each, for example "Scouts ×3 · Men-at-arms > Archers ×2 · Feudal around 9:40".
- **Ratings:** your opponent's 1v1 and team ladder ratings, from the official ladder.
- **Score check:** compares your side's total score with theirs and shows CONCEDE AVAILABLE once you have been more than 30% behind for 20 seconds. It only tells you; it never resigns for you.
- **Loading screen:** a short cheat sheet for your civ and theirs while the game loads.
- **Herd and relics:** counts each sheep, pig, goose or buffalo you find, and the relics picked up.
- **Idle TC alert:** a red warning when your Town Center stops working, and a blue one before you get housed.
- **15-minute reminder:** a quick gold flash at 15:00 to check you have the two buildings Castle Age needs.
- **Game start:** if you are in another window when the match loads, it switches you to the game, or shows a banner with a sound if Windows will not allow that.
- **Scouting call-outs:** says out loud when an enemy colour shows up on your minimap.
- **Your record:** win/loss by civ, map and opponent, using results from your official match history. Also suggests map bans and shows a result card after each game.
- **Ranked party invite:** clicks through Multiplayer > Ranked > Invite To Party for everyone on your friends list.
- **Discord:** hosts a lobby and posts the join link to your channel.
- **Mod clash check:** finds enabled mods that overwrite each other's files, and which one wins.

It does not read game memory. It reads the replay file's lobby settings, the game's own data
files, the public ladder service, recorded games of matches that are already over, and text
that is already on your screen.

## Run

Needs Python 3 on PATH. Double-click `AoE2 Map Overlay.bat`.

Settings (Discord webhook, friends) and stats are stored in `%APPDATA%\AoE2MapOverlay`.

## Branches

- `Prod`: the version you play with.
- `dev`: work in progress. Merge into `Prod` once tested.
