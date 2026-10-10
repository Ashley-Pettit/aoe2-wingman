@(where pythonw >nul 2>nul && start "" pythonw -x "%~f0" %*) || start "" /min python -x "%~f0" %* & exit /b
# AoE2 Wingman (was AoE2 Map Overlay) - map facts, your opponent, alerts and your record, in a small always-on-top box.
# NOT A CHEAT: it only reads the LOBBY SETTINGS block at the start of the replay file the game writes
# (map picked, each player's name, team and civ - all shown to you in the lobby / loading screen) and
# the game's own description text and map script. It never reads the game's memory.
# Herd count: while a game runs it reads the game's own "--Sheep Found--" style messages off the screen
# (the same text you see top left) and counts them. Nothing else on screen is used.
# Ranked party invite: clicks Multiplayer > Ranked > Invite To Party and invites the friends on your list.
# If you save a Discord webhook in settings it also posts a heads-up to your channel (stored in %APPDATA%\AoE2MapOverlay).
# Score check: reads the score list in the corner of your screen and flags when your side is well behind.
# Opponent openings: looks up your opponent's recent public games and reads how they opened in each.
import os, sys, re, json, glob, time, zlib, struct, collections, threading, difflib, tempfile, io, shutil

VERSION = 'v68'
APP_NAME = 'AoE2 Wingman'
HOME = os.path.expanduser('~')
GAMES = os.path.join(HOME, 'Games', 'Age of Empires 2 DE')
POLL_MS = 3000
FRESH_S = 150

def find_install():
    cands = [r'F:\SteamLibrary\steamapps\common\AoE2DE', r'C:\Program Files (x86)\Steam\steamapps\common\AoE2DE',
             r'C:\Program Files\Steam\steamapps\common\AoE2DE']
    for vdf in [r'C:\Program Files (x86)\Steam\steamapps\libraryfolders.vdf', r'C:\Program Files\Steam\steamapps\libraryfolders.vdf']:
        try:
            for p in re.findall(r'"path"\s+"([^"]+)"', open(vdf, encoding='utf-8', errors='ignore').read()):
                cands.append(os.path.join(p.replace('\\\\', '\\'), 'steamapps', 'common', 'AoE2DE'))
        except OSError:
            pass
    for c in cands:
        if os.path.isfile(os.path.join(c, 'resources', '_common', 'dat', 'maps.json')):
            return c
    return None

LINE = re.compile(r'^(\S+)\s+"(.*)"\s*$')
def read_strings(path, into):
    try:
        for raw in open(path, encoding='utf-8', errors='replace'):
            m = LINE.match(raw.rstrip('\n'))
            if m: into[m.group(1)] = m.group(2)
    except OSError:
        pass

STOCK = {}
INST = [None]
def load_data():
    inst = find_install(); INST[0] = inst
    maps, strings, icons = {}, {}, {}
    if inst:
        dat = os.path.join(inst, 'resources', '_common', 'dat')
        try:
            for m in json.load(open(os.path.join(dat, 'maps.json'), encoding='utf-8-sig'))['map_list']:
                maps[m['storage_id']] = m
        except Exception:
            pass
        for f in glob.glob(os.path.join(dat, 'CivTechTrees', '*.json')):     # unit icon number -> unit name
            try:
                for n in json.load(open(f, encoding='utf-8'))['civ_techs_units']:
                    pi = n.get('Picture Index')
                    if isinstance(pi, int) and pi >= 0 and n.get('Use Type') == 'Unit':
                        icons.setdefault(pi, n['Name'])
            except Exception:
                pass
        read_strings(os.path.join(inst, 'resources', 'en', 'strings', 'key-value', 'key-value-strings-utf8.txt'), strings)
        STOCK.update(strings)
    for prof in glob.glob(os.path.join(GAMES, '*', 'mods', 'local')):
        for mod in ('UnitUpgradeHelper', 'GodMode'):
            read_strings(os.path.join(prof, mod, 'resources', 'en', 'strings', 'key-value', 'key-value-modded-strings-utf8.txt'), strings)
    return maps, strings, icons

# Short, general "what to expect" notes per civ. Common ranked habits, not a rulebook.
OPENINGS = {
 'Britons': 'Feudal archers (often fast Feudal, 2-3 ranges) or a quick Castle Age into mass Crossbows and Longbows. Big range advantage late.',
 'Franks': 'Scouts or men-at-arms into Knights; free farm upgrades make fast Castle Age Knights very common.',
 'Goths': 'Scouts or drush, then a boom into huge infantry (Huskarl and Champion) spam. Weak early, scary late.',
 'Teutons': 'Men-at-arms or scouts, often towers and a slow, strong Castle Age with Knights and Teutonic Knights.',
 'Japanese': 'Men-at-arms into Feudal archers, or fast Castle. Strong fishing on water; Samurai vs unique units.',
 'Chinese': 'Flexible: scouts or archers. Starts with extra villagers so the first minutes look slow, then fast.',
 'Byzantines': 'Cheap counter units: Skirmishers, Spearmen and Camels. Often a defensive tower or trash-heavy game.',
 'Persians': 'Scouts, then Knights or Elephants. Strong Town Centers make early raids and TC pushes common.',
 'Saracens': 'Feudal archers or men-at-arms; Market tricks. Castle Age Camels and Mamelukes.',
 'Turks': 'Scouts or fast Castle into gunpowder; free Light Cavalry and Hussar. Loves gold-heavy maps.',
 'Vikings': 'Men-at-arms or archers with free Wheelbarrow and Hand Cart; infantry with Chieftains later.',
 'Mongols': 'Scouts (strong hunt bonus) into Mangudai or Cavalry Archers; siege Onagers late.',
 'Celts': 'Scouts or men-at-arms with fast lumberjacks; Woad Raiders and siege later.',
 'Spanish': 'Scouts or men-at-arms; Conquistadors in Castle Age. Fast builders so towers or forward castles.',
 'Aztecs': 'Very common Feudal men-at-arms or Eagle rush, then Monks and Jaguar Warriors. No cavalry.',
 'Maya': 'Archers (cheap Plumed Archers later) or Eagle rush. Resources last longer, so strong eco.',
 'Huns': 'Scouts every game, no houses needed. Cavalry Archers and Tarkans for raids.',
 'Koreans': 'Archers or towers; War Wagons and Onagers later. Strong defence.',
 'Italians': 'Archers or fast Castle; cheaper age-ups. Genoese Crossbows vs cavalry. Strong on water.',
 'Hindustanis': 'Scouts or archers; cheaper villagers. Camels and Ghulams, Hand Cannoneers late.',
 'Inca': 'Eagle or men-at-arms rush, villagers fight back. Kamayuks and Slingers later.',
 'Magyars': 'Scouts (extra attack) into Magyar Huszars or Cavalry Archers.',
 'Slavs': 'Scouts or men-at-arms; strong farming eco. Boyars and siege, Druzhina infantry.',
 'Portuguese': 'Archers or fast Castle; gold discount. Organ Guns and strong navy.',
 'Ethiopians': 'Archers with extra resources on age-up; Shotel Warriors and Torsion Engines.',
 'Malians': 'Scouts or men-at-arms; Gbetos and Farimba cavalry later. Cheap buildings.',
 'Berbers': 'Scouts or fast Castle into Camel Archers and Genitours. Fast villagers.',
 'Khmer': 'Scouts, no building requirements, so often fast Castle or Elephants. Farmers drop at houses.',
 'Malay': 'Archers or fast imperial boom (faster age-ups). Karambit Warriors and cheap Elephants.',
 'Burmese': 'Scouts or men-at-arms; free lumber upgrades. Arambai and Battle Elephants.',
 'Vietnamese': 'Archers with enemy positions revealed; Rattan Archers vs archers.',
 'Bulgarians': 'Men-at-arms or scouts; free militia upgrades. Konniks and Krepost towers.',
 'Tatars': 'Scouts or archers; extra hunt/sheep. Keshik and Cavalry Archers.',
 'Cumans': 'Scouts, often an extra Feudal Town Center boom. Cavalry Archers and Kipchaks.',
 'Lithuanians': 'Scouts (+food) into Knights; Leitis and relic-boosted cavalry.',
 'Burgundians': 'Scouts or fast Castle; early Cavalier. Coustilliers and gunpowder late.',
 'Sicilians': 'Scouts or men-at-arms; Donjons and Serjeants. Resist bonus damage.',
 'Poles': 'Scouts or fast Castle into Szlachta cavalry; Obuch infantry. Folwark farms.',
 'Bohemians': 'Monks and gunpowder; Hussite Wagons and Houfnice. Strong spear line.',
 'Dravidians': 'Archers or men-at-arms; Urumi and Skirmishers. Strong on water, no Knights.',
 'Bengalis': 'Archers or elephants; Ratha and Elephant Archers. Villagers resist conversion.',
 'Gurjaras': 'Scouts or men-at-arms; Chakram Throwers and Shrivamsha riders. Camel-heavy.',
 'Romans': 'Men-at-arms or scouts into Legionaries and Centurions; Scorpions late.',
 'Armenians': 'Men-at-arms or archers (early infantry upgrades); Composite Bowmen.',
 'Georgians': 'Scouts or men-at-arms; Monaspa cavalry. Strong on hills.',
 'Achaemenids': None,
 'Athenians': None,
 'Spartans': None,
 'Shu': 'Archers with food from lumberjacks; War Chariots and Crossbows.',
 'Wu': 'Scouts or archers; Fire Archers and strong navy.',
 'Wei': 'Scouts with free villagers from eco upgrades; Tiger Cavalry and Xianbei Raiders.',
 'Jurchens': 'Scouts or archers; Grenadiers and Iron Pagoda cavalry.',
 'Khitans': 'Pastures instead of farms; Mounted Archers and Liao Dao infantry.',
 'Macedonians': None,
 'Thracians': None,
 'Puru': None,
 'Muisca': None,
 'Mapuche': None,
 'Tupi': None,
 'Saxons': 'New civ. Infantry and defence: expect towers and Castles (extra arrows), cheaper foot soldiers per TC/Castle, Hearth Troops.',
 'Varangians': 'New civ. Scouts into Knights and Varangian Guards; extra gold from hunt, sheep and fish. Jarls vs infantry.',
 'Danes': 'New civ. Infantry and siege: Varangian Guards, cheap Jomsvikings and siege that loots destroyed buildings.',
}

# ---------------------------------------------------------------- replay lobby settings
def _ds(h, p):
    if h[p:p+2] != b'\x60\x0a': raise ValueError('bad string')
    n = struct.unpack_from('<H', h, p + 2)[0]
    return h[p+4:p+4+n].decode('utf-8', 'replace'), p + 4 + n

def parse_slots(h, q):
    players = []
    for _ in range(8):
        dlc, color = struct.unpack_from('<Ii', h, q)
        if dlc > 1000: raise ValueError('not a slot')
        team = h[q + 10]
        civ, pool = struct.unpack_from('<II', h, q + 20)
        if civ > 500 or pool > 100: raise ValueError('not a slot')
        r = q + 28 + 4 * pool
        _, r = _ds(h, r); r += 1; ai_name, r = _ds(h, r); name, r = _ds(h, r); _, r = _ds(h, r)
        typ, prof = struct.unpack_from('<II', h, r)
        number = struct.unpack_from('<i', h, r + 12)[0]     # who the recording's commands call this player
        k = h.find(b'\x60\x0a', r + 16, r + 60)
        if k < 0: raise ValueError('no tail')
        _, q = _ds(h, k)
        if typ in (2, 4):                                   # 2 human, 4 computer
            players.append(dict(name=name or ai_name or 'Computer', civ=civ, team=team,
                                human=typ == 2, profile=prof, colour=color,
                                number=number if 1 <= number <= 8 else 0))
    return players

def read_lobby(path, raw=None):
    """The lobby settings from a recorded game: a file on disk, or one already in memory."""
    if raw is not None:
        if len(raw) < 16: return None
        hl = struct.unpack_from('<I', raw, 0)[0]
        if hl < 16 or hl > 50_000_000: return None
        comp = raw[8:hl]
    else:
        with open(path, 'rb') as f:
            hl = struct.unpack('<I', f.read(4))[0]; f.read(4)
            if hl < 16 or hl > 50_000_000: return None
            comp = f.read(hl - 8)
    dz = zlib.decompressobj(-15)
    h = dz.decompress(comp, 16384)
    if not h.startswith(b'VER '): return None
    size = map_size_from_header(h)
    while size is None and dz.unconsumed_tail:                # single player replays store AI scripts first
        h += dz.decompress(dz.unconsumed_tail, 1 << 20)
        size = map_size_from_header(h[-(1 << 20) - 64:])
    n = struct.unpack_from('<I', h, 36)[0]
    p = 40 + 4 * n
    selected, resolved = struct.unpack_from('<II', h, p + 8)
    players = []
    seps = [m.start() for m in re.finditer(re.escape(b'\xa3\x5f\x02\x00'), h[p:p + 600])]
    for s0 in seps:
        try:
            players = parse_slots(h, p + s0 + 4)
            break
        except Exception:
            players = []
    return dict(selected=selected, resolved=resolved, players=players, size=size)

def my_profile():
    files = [p for p, _ in sorted(_replay_entries(), key=lambda x: x[1])[-25:]]
    c = collections.Counter()
    for f in files:
        try:
            for pl in (read_lobby(f) or {}).get('players', []):
                if pl['human']: c[pl['profile']] += 1
        except Exception:
            pass
    return c.most_common(1)[0][0] if c else None

def my_names(profile):
    """Names you've played under (from your recent replays), to spot yourself on the loading screen."""
    names = collections.Counter()
    for f in [p for p, _ in sorted(_replay_entries(), key=lambda x: x[1])[-25:]]:
        try:
            for pl in (read_lobby(f) or {}).get('players', []):
                if pl['human'] and pl['profile'] == profile: names[pl['name']] += 1
        except Exception:
            pass
    return [n for n, _ in names.most_common(3)]

def _replay_entries():
    """Every replay on disk as (path, modified). os.scandir rather than glob plus getmtime:
    the savegame folder holds thousands of files and this runs every few seconds, and a
    DirEntry already carries the timestamp from the directory read, so nothing is stat'd twice."""
    out = []
    for prof in glob.glob(os.path.join(GAMES, '*', 'savegame')):
        try:
            with os.scandir(prof) as it:
                for e in it:
                    if not e.name.endswith('.aoe2record'): continue
                    try: out.append((e.path, e.stat().st_mtime))
                    except OSError: pass
        except OSError:
            continue
    return out

LIVE = {'path': None, 'size': -1, 't': 0.0}       # the newest recording, its size, and when that last changed

def newest_replay():
    """The recording of the game in progress, or None when no game is on.
    The folder listing cannot say whether a recording is still being written: Windows only brings
    a file's listed time and size up to date when the file is closed, so a game in progress looks
    untouched from the minute it starts (and looks brand new the moment it ends). So the listing
    only picks out the newest recording, and the file itself is then asked for its size. A game
    is on for as long as that keeps growing."""
    best, best_t = None, 0.0
    for path, t in _replay_entries():
        if t > best_t: best, best_t = path, t
    if not best: return None
    try: s = os.stat(best)
    except OSError: return None
    now = time.time()
    if best != LIVE['path']:                          # first sight of it: go by the file's own clock
        LIVE.update(path=best, size=s.st_size, t=max(s.st_mtime, best_t) if s.st_size else now)
    elif s.st_size != LIVE['size']:                   # still being written: the game is on
        LIVE.update(size=s.st_size, t=now)
    return best if now - LIVE['t'] < FRESH_S else None

# ---------------------------------------------------------------- relic count from the map script
# Reads the game's own random-map script (the same file the lobby uses) and works out how many relics
# it places for this map size and player count. Nothing is read from the running game.
RMS_CACHE = {}
SIZE_NAMES = [(80, 'MINI'), (120, 'TINY'), (144, 'SMALL'), (168, 'MEDIUM'), (200, 'NORMAL'), (220, 'LARGE'),
              (240, 'HUGE'), (252, 'GIANT'), (276, 'MASSIVE'), (300, 'ENORMOUS'), (320, 'COLOSSAL'),
              (360, 'INCREDIBLE'), (400, 'MONSTROUS'), (480, 'LUDICROUS')]
OLD_NAMES = {'MINI': 'TINY_MAP', 'TINY': 'TINY_MAP', 'SMALL': 'SMALL_MAP', 'MEDIUM': 'MEDIUM_MAP', 'NORMAL': 'LARGE_MAP',
             'LARGE': 'HUGE_MAP', 'HUGE': 'GIGANTIC_MAP', 'LUDICROUS': 'LUDIKRIS_MAP'}
DEBUG_HERD = False
START_SIGHT = 10         # tiles; herd placed this close to your TC counts as your starting herd
START_FILES = {'herdable_starting.inc', 'town_herdable.inc'}
HERD_IDS = {594, 833, 305, 1963, 1060, 705, 1596, 1598, 1600, 1142, 1245, 1243}   # sheep, turkey, llama, goat, cows, buffalo, pig, goose
TOK = re.compile(r'/\*.*?\*/|"[^"]*"|\S+', re.S)

def rms_tokens(path):
    if path not in RMS_CACHE:
        try:
            txt = open(path, encoding='latin-1').read()
            RMS_CACHE[path] = [t for t in TOK.findall(txt) if not t.startswith('/*')]
        except OSError:
            RMS_CACHE[path] = None
    return RMS_CACHE[path]

def map_size_from_header(h):
    for m in re.finditer(re.escape(b'\xad\xde\xad\xde'), h):
        x, y = struct.unpack_from('<II', h, m.start() + 8)
        if x == y and 40 <= x <= 1000: return x
    return None

class _Eval:
    def __init__(self, folder, size, players, rng):
        self.folder, self.rng, self.players, self.size = folder, rng, players, size
        name = min(SIZE_NAMES, key=lambda s: abs(s[0] - size))[1]
        self.defs = {'MAPSIZE_' + name, '%d_PLAYER_GAME' % players, 'DE_AVAILABLE', 'UP_AVAILABLE', 'UP_EXTENSION'}
        self.defs.add(OLD_NAMES.get(name, 'GIGANTIC_MAP'))
        self.consts = {}
        self.relics = 0
        self.unknown = False
        self.herd_start = 0          # herd animals you own at the start (under the TC)
        self.herd_found = 0          # herd animals placed per player for you to find
        self.herd_owned = 0          # of the starting ones, those already yours (no 'found' message for these)
        self.herd_groups = []        # sizes of the herds you have to go and find (one 'found' message each)
        self.cur = ''
        self.depth = 0

    def val(self, toks, i):                       # read a number / const / (expression) / rnd(a,b)
        t = toks[i]
        if t.startswith('('):
            expr, n = t, 1 + 0
            depth = t.count('(') - t.count(')'); j = i + 1
            while depth > 0 and j < len(toks):
                expr += ' ' + toks[j]; depth += toks[j].count('(') - toks[j].count(')'); j += 1
            return self.expr(expr), j
        return self.expr(t), i + 1

    def expr(self, s):
        def rnd(a, b): return self.rng.randint(int(min(a, b)), int(max(a, b)))
        s = re.sub(r'[A-Za-z_][A-Za-z0-9_]*', lambda m: m.group(0) if m.group(0) == 'rnd' else str(self.consts.get(m.group(0), 0)), s)
        if not re.fullmatch(r'[0-9.\s()+\-*/%,rnd]*', s): return 0
        try: return eval(s, {'__builtins__': {}}, {'rnd': rnd})
        except Exception: return 0

    def run(self, path):
        toks = rms_tokens(path)
        if toks is None or self.depth > 12: return
        self.depth += 1
        prev_file, self.cur = self.cur, os.path.basename(path).lower()
        stack = []            # each entry: [active_now, taken_already, parent_active]
        rstack = []           # random blocks: [roll, cum, chosen, parent_active]
        active = True
        i, n = 0, len(toks)
        obj = None
        while i < n:
            t = toks[i]; tl = t.lower()
            if tl == 'if':
                c = active and toks[i + 1] in self.defs or active and toks[i + 1] in self.consts
                stack.append([c, c, active]); active = c; i += 2; continue
            if tl == 'elseif' and stack:
                top = stack[-1]; c = top[2] and not top[1] and (toks[i + 1] in self.defs or toks[i + 1] in self.consts)
                top[0] = c; top[1] = top[1] or c; active = c; i += 2; continue
            if tl == 'else' and stack:
                top = stack[-1]; c = top[2] and not top[1]; top[0] = c; top[1] = True; active = c; i += 1; continue
            if tl == 'endif' and stack:
                active = stack.pop()[2]; i += 1; continue
            if tl == 'start_random':
                rstack.append([self.rng.random() * 100, 0.0, False, active]); active = False; i += 1; continue
            if tl == 'percent_chance' and rstack:
                r = rstack[-1]
                try: p = float(toks[i + 1])
                except ValueError: p = 0
                lo = r[1]; r[1] += p
                take = r[3] and not r[2] and lo <= r[0] < r[1]
                if take: r[2] = True
                active = take; i += 2; continue
            if tl == 'end_random' and rstack:
                active = rstack.pop()[3]; i += 1; continue
            if not active:
                i += 1; continue
            if tl in ('#include_drs', '#include'):
                f = toks[i + 1].strip('"').replace('\\', '/')
                self.run(os.path.join(self.folder, *f.split('/')))
                i += 2; continue
            if tl == '#define':
                self.defs.add(toks[i + 1]); i += 2; continue
            if tl == '#undefine':
                self.defs.discard(toks[i + 1]); i += 2; continue
            if tl == '#const':
                name = toks[i + 1]; v, i = self.val(toks, i + 2); self.consts[name] = v; continue
            if tl == 'create_object':
                nm = toks[i + 1]
                obj = dict(name=nm, oid=self.consts.get(nm), n=1, groups=None, pscale=False, mscale=False, gaia=False, every=False, maxd=None, file=self.cur)
                i += 2; continue
            if obj is not None:
                if t == '}':
                    if obj['name'] == 'RELIC':
                        c = obj['n'] * (1 if obj['groups'] is None else obj['groups'])
                        if obj['pscale'] or obj['every']: c *= self.players
                        if obj['mscale']: c = c * self.size * self.size / 10000.0
                        if obj['n'] >= 1000 or (obj['groups'] or 1) >= 1000: self.unknown = True   # 'fill the area' style
                        self.relics += int(c)
                    elif obj['oid'] in HERD_IDS and obj['every']:
                        c = int(obj['n'] * (1 if obj['groups'] is None else obj['groups']))
                        if DEBUG_HERD: print('herd', obj)
                        # yours at the start: owned outright, or dropped right by your Town Centre
                        if not obj['gaia']: self.herd_owned += c; self.herd_start += c
                        elif obj['file'] in START_FILES or (obj['maxd'] is not None and obj['maxd'] <= START_SIGHT): self.herd_start += c
                        else:
                            self.herd_found += c
                            if obj['groups'] is None: self.herd_groups += [1] * int(obj['n'])     # placed one by one
                            else: self.herd_groups += [int(obj['n'])] * int(obj['groups'])
                    obj = None; i += 1; continue
                if tl == 'number_of_objects': obj['n'], i = self.val(toks, i + 1); continue
                if tl == 'number_of_groups': obj['groups'], i = self.val(toks, i + 1); continue
                if tl == 'set_scaling_to_player_number': obj['pscale'] = True
                if tl == 'set_scaling_to_map_size': obj['mscale'] = True
                if tl == 'set_place_for_every_player': obj['every'] = True
                if tl == 'set_gaia_object_only': obj['gaia'] = True
                if tl == 'max_distance_to_players': obj['maxd'], i = self.val(toks, i + 1); continue
            i += 1
        self.depth -= 1
        self.cur = prev_file

def script_facts(inst, script, size, players):
    """Relics and your starting herd, worked out from the map script. Values are (min, max) or None."""
    import random
    out = dict(relics=None, herd_start=None, herd_total=None)
    if not (inst and script and size): return out
    folder = os.path.join(inst, 'resources', '_common', 'drs', 'gamedata_x2')
    path = os.path.join(folder, script)
    if rms_tokens(path) is None: return out
    rel, start, owned, total, sizes, unknown = [], [], [], [], collections.Counter(), False
    for k in range(24):
        e = _Eval(folder, size, max(1, players), random.Random(k))
        e.run(os.path.join(folder, 'random_map.def'))          # the game loads this before every script
        e.run(path)
        unknown = unknown or e.unknown
        rel.append(e.relics); start.append(e.herd_start); owned.append(e.herd_owned); sizes.update(x for x in e.herd_groups if x > 0); total.append(e.herd_start + e.herd_found)
    out['relics'] = 'varies' if unknown else (min(rel), max(rel))
    out['herd_start'] = (min(start), max(start))
    out['herd_total'] = (min(total), max(total))
    out['herd_owned'] = (min(owned), max(owned))
    out['herd_group'] = sizes.most_common(1)[0][0] if sizes else 2
    return out

# ---------------------------------------------------------------- text
def clean(t):
    t = re.sub(r'<[^<>]*>', '', t)
    return t.replace('\\n', '\n').strip()

HERD_WORD = re.compile(r'\b(Sheep|Goats?|Turkeys?|Llamas?|Cows?|Cattle|Pigs?|Geese|Goose|Water Buffalo(?:es)?)\s+(\d+(?:\s*-\s*\d+)?)', re.I)

def map_text(maps, strings, sel, res, size=None, players=2):
    """Returns (name, animal line, herd) where herd is None or dict(owned, floor, total) for the X of Y count."""
    if sel != res:
        return 'Hidden map', 'The map was hidden in the lobby, so the overlay does not reveal it.', None
    m = maps.get(res)
    if not m: return 'Custom map', 'No built-in information for this map.', None
    name = strings.get(str(m.get('name_string_id')), m.get('const_name', 'Map'))
    desc = clean(strings.get(str(m.get('rollover_string_id')), ''))
    if desc.lower().startswith(name.lower() + ' - '): desc = desc[len(name) + 3:]
    first = (desc.split('\n')[0].strip() if desc else '') or 'No animal information for this map.'
    try: facts = script_facts(INST[0], m.get('script_filename'), size, players)
    except Exception: facts = dict(relics=None, herd_start=None, herd_total=None, herd_owned=None)
    rc = facts.get('relics')
    if rc == 'varies': first += '   \u00b7   Relics vary'
    elif rc: first += '   \u00b7   Relics %s' % (rc[0] if rc[0] == rc[1] else '%d-%d' % rc)
    herd = None
    if facts.get('herd_total'):
        hm = HERD_WORD.search(first)
        total = hm.group(2).replace(' ', '') if hm else str(facts['herd_total'][1])
        if hm or facts['herd_total'][1]:
            herd = dict(owned=facts['herd_owned'][1], floor=facts['herd_start'][1], total=total,
                        group=facts.get('herd_group') or 2,
                        span=hm.span() if hm else None, word=hm.group(1) if hm else 'Herd')
    return name, first, herd

def herd_count(herd, notices):
    """The game shows one 'Sheep Found' message per herd found, not per animal. The first one is the
    herd by your Town Centre (unless you already own all of it); each later one is a herd out on the map,
    sized from the map script (usually pairs)."""
    owned, floor, g = herd['owned'], herd['floor'], herd['group']
    if floor > owned:                                  # starting herd still has to 'turn up'
        x = owned if notices == 0 else floor + g * (notices - 1)
    else:
        x = floor + g * notices
    cap = int(re.split(r'\D+', herd['total'])[-1] or 0)
    return min(x, cap) if cap else x

def herd_line(first, herd, notices, extra):
    """Puts 'Sheep X of Y' into the animal line."""
    if not herd: return first
    x = herd_count(herd, notices) + extra
    piece = '%s %d of %s' % (herd['word'], max(0, x), herd['total'])
    if herd['span']: return first[:herd['span'][0]] + piece + first[herd['span'][1]:]
    return piece + '   \u00b7   ' + first

# ---------------------------------------------------------------- herd tracking from the on-screen messages
LOG = os.path.join(GAMES if os.path.isdir(GAMES) else tempfile.gettempdir(), 'aoe2_map_overlay.log')
def log(msg):
    try:
        with open(LOG, 'a', encoding='utf-8') as f: f.write(time.strftime('%H:%M:%S ') + msg + '\n')
    except OSError: pass

OCR_PKGS = ['winrt-runtime', 'winrt-Windows.Media.Ocr', 'winrt-Windows.Graphics.Imaging', 'winrt-Windows.Storage.Streams',
            'winrt-Windows.Foundation', 'winrt-Windows.Foundation.Collections', 'winrt-Windows.Globalization']
FOUND_IDS = (37161, 37168, 37167, 37156, 37155, 37169, 37170, 37171, 37173)   # Sheep, Goat, Turkey, Llama, Cow,
# Water Buffalo, Pig, Goose, Capybara "Found" messages. All count towards your herd.

def _norm(t): return re.sub(r'[^a-z]', '', t.lower())

def _load_ocr():
    try:
        import winrt.runtime
        from winrt.windows.media.ocr import OcrEngine
        from winrt.windows.graphics.imaging import SoftwareBitmap, BitmapPixelFormat
    except ImportError:
        import subprocess, importlib, site
        log('installing the Windows text reader (winrt) with pip')
        exe = sys.executable
        if exe.lower().endswith('pythonw.exe'): exe = exe[:-11] + 'python.exe'
        subprocess.run([exe, '-m', 'pip', 'install', '--user', '--disable-pip-version-check', '-q'] + OCR_PKGS,
                       creationflags=0x08000000, timeout=600, capture_output=True)
        usp = site.getusersitepackages()
        if usp not in sys.path: sys.path.append(usp)
        importlib.invalidate_caches()
        import winrt.runtime
        from winrt.windows.media.ocr import OcrEngine
        from winrt.windows.graphics.imaging import SoftwareBitmap, BitmapPixelFormat
    try: winrt.runtime.init_apartment(winrt.runtime.MTA)
    except Exception: pass
    eng = OcrEngine.try_create_from_user_profile_languages()
    if eng is None: raise RuntimeError('Windows has no text-recognition language installed')
    def read(bgra, w, h, words=False):
        bmp = SoftwareBitmap.create_copy_from_buffer(bgra, BitmapPixelFormat.BGRA8, w, h)
        lines = eng.recognize_async(bmp).get().lines
        if not words: return [ln.text for ln in lines]
        out = []
        for ln in lines:
            ws = []
            for wd in ln.words:
                r = wd.bounding_rect
                ws.append((wd.text, r.x, r.y, r.width, r.height))
            out.append((ln.text, ws))
        return out
    return read

def _grabber():
    """Screen grab of the game's event-message box (top left), doubled in size so small text reads well."""
    import ctypes
    from ctypes import wintypes
    u, g = ctypes.windll.user32, ctypes.windll.gdi32
    try: u.SetThreadDpiAwarenessContext(ctypes.c_void_p(-4))          # real pixels, this thread only
    except Exception: pass
    vp = ctypes.c_void_p
    u.GetDC.restype = vp; u.GetDC.argtypes = [vp]; u.ReleaseDC.argtypes = [vp, vp]
    g.CreateCompatibleDC.restype = vp; g.CreateCompatibleDC.argtypes = [vp]
    g.CreateCompatibleBitmap.restype = vp; g.CreateCompatibleBitmap.argtypes = [vp, ctypes.c_int, ctypes.c_int]
    g.SelectObject.restype = vp; g.SelectObject.argtypes = [vp, vp]
    g.StretchBlt.argtypes = [vp] + [ctypes.c_int] * 4 + [vp] + [ctypes.c_int] * 4 + [wintypes.DWORD]
    g.SetStretchBltMode.argtypes = [vp, ctypes.c_int]
    g.GetDIBits.argtypes = [vp, vp, wintypes.UINT, wintypes.UINT, vp, vp, wintypes.UINT]
    g.DeleteObject.argtypes = [vp]; g.DeleteDC.argtypes = [vp]
    class BIH(ctypes.Structure):
        _fields_ = [('biSize', wintypes.DWORD), ('biWidth', ctypes.c_long), ('biHeight', ctypes.c_long),
                    ('biPlanes', wintypes.WORD), ('biBitCount', wintypes.WORD), ('biCompression', wintypes.DWORD),
                    ('biSizeImage', wintypes.DWORD), ('biXPelsPerMeter', ctypes.c_long), ('biYPelsPerMeter', ctypes.c_long),
                    ('biClrUsed', wintypes.DWORD), ('biClrImportant', wintypes.DWORD)]
    def grab(region=None):
        if region:
            x, y, w, h, k = region
        else:
            W, H = u.GetSystemMetrics(0), u.GetSystemMetrics(1)
            s = H / 2160.0                                    # the game lays its UI out on a 3840x2160 canvas
            x, y = 0, int(250 * s)
            w, h = min(W, int(900 * s)), int(390 * s)
            k = 2 if H < 1800 else 1
        ow, oh = w * k, h * k
        sdc = u.GetDC(None); mdc = g.CreateCompatibleDC(sdc); bmp = g.CreateCompatibleBitmap(sdc, ow, oh)
        old = g.SelectObject(mdc, bmp)
        try:
            g.SetStretchBltMode(mdc, 4)
            g.StretchBlt(mdc, 0, 0, ow, oh, sdc, x, y, w, h, 0x00CC0020)
            bih = BIH(ctypes.sizeof(BIH), ow, -oh, 1, 32, 0, 0, 0, 0, 0, 0)
            buf = ctypes.create_string_buffer(ow * oh * 4)
            g.GetDIBits(mdc, bmp, 0, oh, buf, ctypes.byref(bih), 0)
            return buf.raw, ow, oh
        finally:
            g.SelectObject(mdc, old); g.DeleteObject(bmp); g.DeleteDC(mdc); u.ReleaseDC(None, sdc)
    return grab

class HerdWatcher(threading.Thread):
    def __init__(self, strings):
        super().__init__(daemon=True)
        self.pause = False
        self.targets = [_norm(strings.get(str(i), '')) for i in FOUND_IDS]
        self.targets = [t for t in self.targets if t] or ['sheepfound']
        self.relic_t = _norm(strings.get('37164', '')) or 'relicpickedup'
        self.early, self.found, self.relics, self.active, self.status = 0, 0, 0, False, ''
        self.t0 = time.time()
        self.hist = collections.deque(maxlen=3)
        self.rhist = collections.deque(maxlen=3)
        self.lock = threading.Lock()
        self.on_lines = None                 # the idle TC alert listens to the same message box

    def reset(self):
        with self.lock:
            self.early = self.found = self.relics = 0; self.hist.clear(); self.rhist.clear(); self.t0 = time.time()

    def is_relic(self, line):
        n = _norm(line)
        return len(n) >= 6 and ((self.relic_t in n and len(n) <= len(self.relic_t) + 4) or
                                difflib.SequenceMatcher(None, n, self.relic_t).ratio() >= 0.8)

    def is_found(self, line):
        n = _norm(line)
        if len(n) < 6: return False
        return any((t in n and len(n) <= len(t) + 4) or difflib.SequenceMatcher(None, n, t).ratio() >= 0.8 for t in self.targets)

    def run(self):
        try:
            self.status = 'setting up'
            read = _load_ocr(); grab = _grabber()
            self.status = ''
        except Exception as e:
            self.status = 'unavailable'; log('herd tracking off: %r' % (e,)); return
        while True:
            if not self.active or self.pause: time.sleep(1); continue
            try:
                lines = read(*grab())
                if self.on_lines: self.on_lines(lines)
                hits = [ln for ln in lines if self.is_found(ln)]
                n = len(hits)
                with self.lock:
                    before = max(self.hist) if self.hist else 0
                    if n > before:
                        self.found += n - before                     # one per 'Found' message
                        log('message %d at %ds: %s' % (self.found, time.time() - self.t0, ' | '.join(hits)))
                    self.hist.append(n)
                    rh = [ln for ln in lines if self.is_relic(ln)]            # '--Relic Picked Up--', one per relic
                    rb = max(self.rhist) if self.rhist else 0
                    if len(rh) > rb:
                        self.relics += len(rh) - rb
                        log('relic %d at %ds' % (self.relics, time.time() - self.t0))
                    self.rhist.append(len(rh))
            except Exception as e:
                log('read failed: %r' % (e,)); time.sleep(2)
            time.sleep(0.5)

# ---------------------------------------------------------------- idle Town Center alert
# Only reads what is already on your screen: the Global Queue under the resource bar (the icons
# of everything you have queued), the population counter, and the game's own '--X Created--' and
# '--X Research Complete--' lines. Nothing is read out of the running game.
TC_BUILDING = 109
HOUSE_GRACE_MIN = 2.0                     # game minutes before 'Build a house' can show
CASTLE_NOTE_MIN = 15                      # game minute for the 'two buildings for Castle Age?' reminder
# each badge strip flashes between its own two shades: red TC idle, blue house, gold reminder
TC_RED, TC_BLUE, TC_GOLD = ('#7d1510', '#e0362b'), ('#0f3f7a', '#1e78d6'), ('#a87a00', '#e6b422')
Q_DX, Q_DY, Q_SIZE = -1300, 84, 74       # first queue icon vs the pop counter (left edge, text middle), UI canvas units
SPAN = 1148                               # wood number to pop counter, UI canvas units (gives the UI scale)
TC_DEBUG = os.path.join(GAMES if os.path.isdir(GAMES) else tempfile.gettempdir(), 'tc_debug')

def mod_dirs():
    """Enabled mods, highest priority first, the way the game layers them."""
    out = []
    for f in glob.glob(os.path.join(GAMES, '*', 'mods', 'mod-status.json')):
        try: d = json.load(open(f, encoding='utf-8-sig'))
        except Exception: continue
        base = os.path.dirname(f)
        for m in sorted((m for m in d.get('Mods', []) if m.get('Enabled')), key=lambda m: m.get('Priority', 999)):
            parts = [p for p in re.split(r'[\\/]+', m.get('Path', '')) if p]
            if parts: out.append(os.path.join(base, *parts))
    return out

def queue_icon(kind, pi, dirs):
    """The picture the game actually shows for a unit or tech: a mod's copy wins over the stock one."""
    pat = ('%03d_50730.*' if kind == 'units' else '%03d_*.*') % pi
    for d in dirs:
        hits = [x for x in glob.glob(os.path.join(d, 'widgetui', 'textures', 'ingame', kind, pat))
                if x.lower().endswith(('.dds', '.png'))]
        if hits: return sorted(hits)[0]
    return None

def ensure_numpy():
    try:
        import numpy  # noqa: F401
        return True
    except ImportError:
        pass
    try:
        import subprocess, importlib, site
        exe = sys.executable
        if exe.lower().endswith('pythonw.exe'): exe = exe[:-11] + 'python.exe'
        log('installing numpy for the idle TC alert')
        subprocess.run([exe, '-m', 'pip', 'install', '--user', '--disable-pip-version-check', '-q', 'numpy'],
                       creationflags=0x08000000, timeout=600, capture_output=True)
        usp = site.getusersitepackages()
        if usp not in sys.path: sys.path.append(usp)
        importlib.invalidate_caches()
        import numpy  # noqa: F401
        return True
    except Exception as e:
        log('no numpy, idle TC alert only works off the empty queue: %r' % (e,))
        return False


class QueueReader(object):
    """Works out what each Global Queue icon is by comparing it with the game's own icon pictures."""
    S = 16                                     # compare at 16x16
    CUT = 0.4                                  # skip the count number in the top left
    ZOOM = 0.9                                 # the queue shows the middle 90% of each icon
    EDGE = 0.055                               # and draws a thin frame round it

    def __init__(self, civ=None):
        import numpy as np
        from PIL import Image
        self.np, self.Image = np, Image
        S, c = self.S, int(self.S * self.CUT)
        m = np.ones((S, S), bool); m[:c, :c] = False
        self.mask = m
        items = {}
        tc_names = set()
        first_age = {}                       # the earliest age anything can make or research it
        dat = os.path.join(INST[0] or '', 'resources', '_common', 'dat', 'CivTechTrees')
        want = re.sub(r'[^a-z]', '', (civ or '').lower())
        for f in glob.glob(os.path.join(dat, '*.json')):
            try: d = json.load(open(f, encoding='utf-8'))
            except Exception: continue
            civ_id = re.sub(r'[^a-z]', '', str(d.get('civ_id', '')).lower())
            mine = bool(want) and (civ_id == want or civ_id.rstrip('s') == want.rstrip('s'))
            for n in d.get('civ_techs_units', []):
                pi, use = n.get('Picture Index'), n.get('Use Type')
                if not isinstance(pi, int) or pi < 0 or use not in ('Unit', 'Tech'): continue
                if n.get('Node Status') == 'NotAvailable' and mine: continue
                key = ('units' if use == 'Unit' else 'tech', pi)
                if want and not mine and key not in items: items.setdefault(('_other',) + key, n['Name'])
                else: items[key] = n['Name']
                if n.get('Building ID') == TC_BUILDING: tc_names.add(key)
                ag = n.get('Age ID')
                if isinstance(ag, int) and ag > 0: first_age[key] = min(first_age.get(key, 9), ag)
        # with a known civ only its own tree is compared (fewer look-alikes); otherwise every civ
        keys = [k for k in items if k[0] != '_other'] or [k[1:] for k in items]
        dirs = mod_dirs() + ([INST[0]] if INST[0] else [])
        feats, self.names, self.is_tc, ages = [], [], [], []
        for key in sorted(set(keys)):
            path = queue_icon(key[0], key[1], dirs)
            if not path: continue
            try: im = Image.open(path).convert('RGB')
            except Exception: continue
            w_, h_ = im.size; c_ = w_ * (1 - self.ZOOM) / 2
            feats.append(self.feat(im.crop((c_, c_, w_ - c_, h_ - c_)))); self.names.append(items.get(key) or items.get(('_other',) + key))
            self.is_tc.append(key in tc_names); ages.append(first_age.get(key, 1))
        self.T = np.array(feats) if feats else np.zeros((0, int(m.sum())))
        self.is_tc = np.array(self.is_tc, bool)
        self.ages = np.array(ages, int)
        self.ok = np.ones(len(self.names), bool)
        log('queue reader: %d icons (%d town centre)%s' % (len(self.names), int(self.is_tc.sum()),
                                                          ' for %s' % civ if civ else ''))

    def set_age(self, age):
        """Only compare against things you can actually make yet: no Two-Handed Swordsman in the Dark Age."""
        self.ok = self.ages <= age

    def feat(self, im):
        np = self.np
        g = np.asarray(im.convert('L').resize((self.S, self.S), self.Image.BOX), dtype=float)
        v = g[self.mask]; v = v - v.mean()
        return v / (np.linalg.norm(v) + 1e-6)

    def best(self, img, x, y, z, r):
        """For an icon near (x, y), size z: the best town-centre match, the best other match, and where it sat."""
        np = self.np
        top_tc, top_other, at, at_sc = -1.0, -1.0, (x, y), -9.0
        name_tc = name_other = '?'
        e = max(1, int(round(z * self.EDGE)))
        tc = self.is_tc
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                q = self.feat(img.crop((x + dx + e, y + dy + e, x + dx + z - e, y + dy + z - e)))
                sc = np.where(self.ok, self.T @ q, -9.0)
                m = float(sc.max())
                if m > at_sc: at_sc, at = m, (x + dx, y + dy)
                if tc.any():
                    i = int(np.argmax(np.where(tc, sc, -9)))
                    if sc[i] > top_tc: top_tc, name_tc = float(sc[i]), self.names[i]
                if (~tc).any():
                    i = int(np.argmax(np.where(tc, -9, sc)))
                    if sc[i] > top_other: top_other, name_other = float(sc[i]), self.names[i]
        return top_tc, name_tc, top_other, name_other, at

    def read(self, img, x, y, z, limit=12):
        """One entry per icon in the queue, left to right: (verdict, label, tc score, other score).
        verdict is 'tc', 'other' or '?'. Town centre work wins any close call, so a doubtful icon can
        only ever stop an alert, never cause one."""
        out = []
        if not len(self.names): return out
        from PIL import ImageStat
        x0, y0 = x, y
        off = getattr(self, 'off', None)
        if off: x, y = x + off[0], y + off[1]
        for k in range(limit):
            if x + z > img.size[0]: break
            # an icon is busy, sharp artwork; the sky or map showing through an empty slot is not
            if ImageStat.Stat(img.crop((x, y, x + z, y + z)).convert('L')).stddev[0] < 30: break
            t, tn, o, on, (ax, ay) = self.best(img, x, y, z, (1 if off else 3) if k == 0 else 1)
            if k == 0:   # lock onto the first icon's exact spot once it reads clearly
                self.off = (ax - x0, ay - y0) if max(t, o) >= 0.65 else None
            if t >= 0.55 and t >= o - 0.04: v, lab = 'tc', tn
            elif o >= 0.6 and o - t >= 0.1: v, lab = 'other', on
            else: v, lab = '?', '%s/%s' % (tn, on)
            out.append((v, lab, t, o))
            x, y = ax + z, ay
        return out

    @staticmethod
    def empty_mark(img, x, y, z):
        """GodMode's red '!' sits under the first queue slot and only shows when nothing is queued."""
        px = img.crop((x, y, x + z, y + z)).convert('RGB').getdata()
        red = sum(1 for r_, g_, b_ in px if r_ > 170 and g_ < 70 and b_ < 70)
        return red > 0.2 * z * z


class TCWatcher(threading.Thread):
    """Keeps an eye on the Global Queue and the pop counter while you play."""
    def __init__(self, strings, notify):
        super().__init__(daemon=True)
        self.notify = notify                  # notify(state, where): 'busy' / 'idle' / 'house' / 'idle+house' / 'off'
        self.active = False                   # a game is on
        self.pause = False                    # the loading screen panels are up
        self.civ = None
        self.reader, self.reader_civ = None, 'unset'
        self.state, self.where = 'off', None
        self.anchor, self.anchor_t = None, 0
        self.idle_since = None
        self.tc_event = 0                      # last '--Villager Created--' style line
        self.vil = 'villager'                 # '--Villager Created--' in the event box
        self.lock = threading.Lock()
        self.pause_fn = lambda: False
        self.fail_log = 0
        self.was_active = False
        self.pop = self.pop_last = None
        self.want, self.seen = 'off', 0
        self.items, self.empty = [], False
        self.age, self.age_t, self.t0 = 1, 0, time.time()
        self.clock, self.clock_t, self.speed = None, 0, 1.7
        self.age_words = [_norm(clean(strings.get(str(4200 + i), d))) for i, d in
                          ((1, 'Dark Age'), (2, 'Feudal Age'), (3, 'Castle Age'), (4, 'Imperial Age'))]
        self.grace = 0

    def reset(self, civ=None, started=None):
        """started is when the game itself began (its recording appeared). The overlay may be opened
        part way through a game, and the start-of-game graces must not begin again when it is."""
        now = time.time()
        with self.lock:
            self.civ = civ; self.anchor = None; self.idle_since = None; self.tc_event = 0
            self.pop = self.pop_last = None; self.want, self.seen = 'off', 0
            self.age, self.age_t, self.grace = 1, 0, 0
            self.t0 = started if started and 0 < started <= now else now
            self.clock, self.clock_t, self.speed = None, 0, 1.7
        self.set('off')

    def needs_house(self, mins, now):
        """Warn before you get housed: how close to the limit depends on how far into the game you are."""
        room = 2 if mins < 10 else 4 if mins < 20 else 8 if mins < 30 else 10 if mins < 40 else 15
        if self.pop and self.pop[1] == 20:
            room = 1          # Ash: nothing at 18/20, but 13/15 still warns
        return (bool(self.pop) and self.pop[1] < 200 and self.pop[1] - self.pop[0] <= room
                and mins >= HOUSE_GRACE_MIN           # you start 4/5: no nagging in the opening,
                and now - self.t0 >= 60)              # even if the game clock is misread early on

    def message_lines(self, lines):
        """Called with the event-box lines the herd tracker already reads."""
        for ln in lines:
            n = _norm(ln)
            if self.vil in n and 'created' in n: self.tc_event = time.time()

    def set(self, state, where=None):
        if state != self.state or (where and where != self.where):
            if state != self.state: log('town centre: %s' % state)
            self.state, self.where = state, where or self.where
            try: self.notify(state, self.where)
            except Exception as e: log('tc notify: %r' % (e,))

    def find_anchor(self, read, grab, x, y, w, hh):
        """The pop counter ('9/15') on the resource bar, read off the screen, and the UI scale."""
        k = 2 if hh < 1400 else 1
        band = (x, y, w, int(hh * 0.075) + 4, k)
        full = read(*grab(band), words=True)
        pop, nums = None, []
        for _, ws in full:
            for i in range(len(ws)):
                for j in range(i, min(i + 3, len(ws))):          # '9/15' can come back as '9/ 15' or '9 / 15'
                    t2 = ''.join(w_[0] for w_ in ws[i:j + 1]).replace('O', '0').replace('o', '0')
                    x0 = ws[i][1]; y0 = min(w_[2] for w_ in ws[i:j + 1])
                    x1 = ws[j][1] + ws[j][3]; y1 = max(w_[2] + w_[4] for w_ in ws[i:j + 1])
                    r = (x + x0 / k, y + y0 / k, (x1 - x0) / k, (y1 - y0) / k)
                    if re.fullmatch(r'\d{1,3}/\d{1,3}', t2): pop = (t2, r); break
                    if j == i and re.fullmatch(r'\d{1,6}', t2): nums.append(r)
        if not pop: return None
        px, py, pw, ph = pop[1]
        cy = py + ph / 2.0
        s = hh / 2160.0
        # the resource amounts are the same size as the pop counter; the small worker counts are not
        left = [r for r in nums if r[0] < px - 200 * s and abs(r[1] + r[3] / 2.0 - cy) < 0.3 * ph
                and abs(r[3] - ph) < 0.25 * ph]
        if left:
            s2 = (px - min(r[0] for r in left)) / float(SPAN)
            if 0.6 * s < s2 < 1.6 * s: s = s2
        return dict(px=px, cy=cy, s=s, pop=pop[0], box=(int(px - 20 * s), int(cy - 30 * s), int(320 * s), int(60 * s)))

    def slow_loop(self):
        """Reads the pop counter (every ~0.7s), the game clock and the age label in the background,
        so the queue check itself runs many times a second."""
        try:
            read = _load_ocr(); grab = _grabber()
        except Exception as e:
            log('pop / clock reading off: %r' % (e,)); return
        while True:
            time.sleep(0.7)
            r = getattr(self, 'rect', None)
            if not self.active or not r: continue
            try:
                x, y, w, hh = r; s = hh / 2160.0; now = time.time()
                a = dict(px=x + w / 2.0, cy=y + 81 * s, s=s,
                         box=(int(x + w / 2.0 - 20 * s), int(y + 51 * s), int(320 * s), int(60 * s)))
                p = self.read_pop(read, grab, a)
                if p and self.pop_ok(p):
                    if p == self.pop_last: self.pop = p          # the same reading twice running
                    self.pop_last = p
                if now - self.clock_t > 3:
                    self.clock_t = now
                    g = self.read_clock(read, grab, x, y, w, s)
                    if g is not None:
                        if self.clock and now > self.clock[1] + 1 and g > self.clock[0]:
                            sp = (g - self.clock[0]) / (now - self.clock[1])
                            if 0.5 < sp < 3: self.speed = sp
                        self.clock = (g, now)
                if now - self.age_t > 4:
                    self.age_t = now
                    ag = self.read_age(read, grab, x, y, w, s)
                    if ag and ag > self.age: self.age = ag; log('age %d' % ag)
            except Exception as e:
                log('pop / clock read: %r' % (e,)); time.sleep(2)

    def read_clock(self, read, grab, x, y, w, s):
        """In-game seconds off the game timer ('00:02:19 (Fast - 2.0)') under the resource bar."""
        cx = x + w / 2.0
        k = 2 if s < 0.7 else 1
        for t in read(*grab((int(cx - 450 * s), int(y + 240 * s), int(900 * s), int(80 * s), k))):
            m = re.search(r'(\d{1,2})\s*[:.]\s*(\d{2})\s*[:.]\s*(\d{2})', t)
            if m: return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        return None

    def game_minutes(self, now):
        if self.clock: return (self.clock[0] + (now - self.clock[1]) * self.speed) / 60.0
        return (now - self.t0) * 1.7 / 60.0          # no timer read yet: guess from the time since loading

    def read_age(self, read, grab, x, y, w, s):
        cx = x + w / 2.0
        k = 2 if s < 0.7 else 1
        txt = _norm(' '.join(read(*grab((int(cx + 600 * s), int(y + 40 * s), int(520 * s), int(80 * s), k)))))
        for i, wd in enumerate(self.age_words, 1):
            if wd and wd in txt: return i
        return None

    @staticmethod
    def pop_ok(p):
        """Throw out misreads like '17/2' or '90/25': pop limits go up in fives, and you are
        never far over yours."""
        n, m = p
        return 1 <= n <= 500 and 5 <= m <= 500 and m % 5 == 0 and n <= m + 20

    def read_pop(self, read, grab, a):
        bx, by, bw, bh = a['box']
        k = 3 if a['s'] < 0.7 else 2
        for t in read(*grab((bx, by, bw, bh, k))):
            m = re.search(r'(\d{1,3})\s*/\s*(\d{1,3})', t.replace('O', '0'))
            if m: return int(m.group(1)), int(m.group(2))
        return None

    def run(self):
        try:
            read = _load_ocr(); grab = _grabber()
            ok = ensure_pillow() and ensure_numpy()
        except Exception as e:
            log('idle TC alert off: %r' % (e,)); return
        from PIL import Image
        ctypes, wintypes, u, _ = _win()
        threading.Thread(target=self.slow_loop, daemon=True).start()
        last_shot = 0
        while True:
            time.sleep(0.08)
            if self.active != self.was_active:
                self.was_active = self.active
                log('idle TC watch %s%s' % ('on' if self.active else 'off', ' (%s)' % self.civ if self.active and self.civ else ''))
            if not self.active or self.pause or not getattr(self, 'enabled', True) or self.pause_fn():
                if self.state != 'off': self.set('off')
                continue
            try:
                fg = u.GetForegroundWindow()
                pid = wintypes.DWORD(); u.GetWindowThreadProcessId(fg, ctypes.byref(pid))
                if not fg or not _proc_name(pid.value).startswith('aoe2de'):
                    if self.state != 'off': self.set('off')
                    time.sleep(1); continue
                x, y, w, hh = client_rect(fg)
                if w < 400 or hh < 300: continue
                now = time.time()
                # GodMode pins the resource bar to the top centre, so the pop counter and the queue
                # always sit in the same place for a given window size (100% HUD scale)
                s = hh / 2160.0
                a = dict(px=x + w / 2.0, cy=y + 81 * s, s=s,
                         box=(int(x + w / 2.0 - 20 * s), int(y + 51 * s), int(320 * s), int(60 * s)))
                self.rect = (x, y, w, hh)                         # for the slow reader thread
                mins = self.game_minutes(now)
                house = self.needs_house(mins, now)
                # the queue strip, at the screen's own resolution
                z = int(round(Q_SIZE * s))
                qx, qy = int(round(a['px'] + Q_DX * s)), int(round(a['cy'] + Q_DY * s))
                sx, sy, sw, sh = qx - 6, qy - 6, min(w - (qx - x) + 6, z * 13), z + 12
                buf, gw, gh = grab((sx, sy, sw, sh, 1))
                img = Image.frombuffer('RGBA', (gw, gh), buf, 'raw', 'BGRA', 0, 1).convert('RGB')
                if self.reader is None or self.reader_civ != self.civ:
                    self.reader_civ = self.civ
                    self.reader = QueueReader(self.civ) if ok else None
                if self.reader:
                    # if the label never reads, stop filtering by age rather than guess wrong all game
                    self.reader.set_age(self.age if (self.age > 1 or now - self.t0 < 90) else 4)
                empty = QueueReader.empty_mark(img, 6, 6, z)
                items = [] if empty or not self.reader else self.reader.read(img, 6, 6, z)
                if any(v == 'tc' for v, _, _, _ in items): verdict = 'busy'
                elif empty or (items and all(v == 'other' for v, _, _, _ in items)): verdict = 'idle'
                else: verdict = '?'                                # not sure: never raise an alert on a guess
                # you just queued something while the alert was up: take it as the answer and clear
                # the alert straight away, then give it a few seconds before judging again
                n_items = 0 if empty else len(items)
                if 'idle' in self.state and n_items > getattr(self, 'n_items', 0):
                    self.grace = now + 3; log('something queued, alert cleared')
                self.n_items = n_items
                if now < self.grace and verdict == 'idle': verdict = 'busy'
                if verdict == '?': verdict = 'busy'                # not sure: never raise an alert on a guess
                if now - self.t0 < 2 and verdict == 'idle': verdict = 'busy'   # 2 seconds' grace as the game starts
                want = verdict + ('+house' if house else '')
                if want == 'busy+house': want = 'house'
                where = (qx, qy + z + int(10 * s), s)
                self.set(want, where)
                self.items, self.empty = items, empty
                if now - last_shot > 30 or (self.state != 'busy' and now - last_shot > 8):
                    last_shot = now
                    self.snapshot(img, items, self.pop, empty)
            except Exception as e:
                log('tc watch: %r' % (e,)); time.sleep(2)

    def snapshot(self, img, items, pop, empty=False):
        """Keeps the last few queue pictures and what was read from them, to tune this by."""
        try:
            os.makedirs(TC_DEBUG, exist_ok=True)
            name = time.strftime('%H%M%S')
            img.save(os.path.join(TC_DEBUG, 'q_%s.png' % name))
            log('queue %s min %.1f pop %s: %s -> %s' % (name, self.game_minutes(time.time()), '%d/%d' % pop if pop else '?',
                'EMPTY (red !)' if empty else ', '.join('%s %s tc%.2f/other%.2f' % (v, lab, t, o) for v, lab, t, o in items) or 'nothing read',
                self.state))
            old = sorted(glob.glob(os.path.join(TC_DEBUG, 'q_*.png')))[:-40]
            for f in old: os.remove(f)
        except Exception as e:
            log('tc snapshot: %r' % (e,))

# ---------------------------------------------------------------- opponent spotted on the minimap
# The minimap only ever draws ground you have already explored: fog is black there. So reading it
# tells us nothing you are not already looking at. Nothing here touches the game's memory or the
# fog, and the overlay never clicks or flares for you.
MINIMAP_ORDER = ['Blue', 'Red', 'Green', 'Yellow', 'Aqua', 'Purple', 'Grey', 'Orange']

def ui_json(name):
    """A widgetui layout file, taking the winning enabled mod's copy if one overrides it.
    mod_dirs() is already in the game's own priority order, so the first hit is the one in play."""
    for d in mod_dirs() + ([INST[0]] if INST[0] else []):
        p = os.path.join(d, 'widgetui', name)
        if os.path.isfile(p):
            try:
                with io.open(p, encoding='utf-8-sig') as fh: return json.load(fh)
            except Exception as e:
                log('could not read %s from %s: %r' % (name, d, e))
    return None

def minimap_colours():
    """{colour index: (r, g, b)} as the minimap actually paints each player, read from the
    game's own UIColors.json. They are deliberately extreme (pure blue, pure green and so on),
    which is what makes them safe to look for without false alarms off the terrain."""
    d = ui_json('UIColors.json') or {}
    tabs = d.get('ColorTables', {})
    out = {}
    for i, n in enumerate(MINIMAP_ORDER):
        c = (tabs.get(n) or {}).get('MiniMap')
        if isinstance(c, list) and len(c) >= 3:
            out[i] = (int(c[0]), int(c[1]), int(c[2]))
    return out

def _align(a):
    """'BottomCentre' -> ('Bottom', 'Centre'). The vertical word comes first."""
    for v in ('Top', 'Bottom', 'Centre'):
        if a.startswith(v):
            h = a[len(v):] or 'Left'
            return v, ('Centre' if h == 'Centre' else h)
    return 'Top', 'Left'

def minimap_rect(cw, ch):
    """The minimap's box on screen, worked out from the game's own mappanel.json.
    The UI is laid out on a 3840x2160 canvas scaled by screen height and pinned to the edges,
    so this follows a UI mod moving the minimap, and any resolution, without being told."""
    d = ui_json('mappanel.json')
    if not d: return None
    try:
        col = d['Collection']
        s = ch / 2160.0
        def top_level(vp):
            w, h = vp['width'] * s, vp['height'] * s
            av, ah = _align(vp.get('alignment', 'TopLeft'))
            x = (vp['xorigin'] * s if ah == 'Left' else
                 cw - (3840 - vp['xorigin']) * s if ah == 'Right' else
                 cw / 2.0 + (vp['xorigin'] - 1920) * s)
            y = (vp['yorigin'] * s if av == 'Top' else
                 ch - (2160 - vp['yorigin']) * s if av == 'Bottom' else
                 ch / 2.0 + (vp['yorigin'] - 1080) * s)
            return (x - (w / 2 if ah == 'Centre' else w if ah == 'Right' else 0),
                    y - (h / 2 if av == 'Centre' else h if av == 'Bottom' else 0), w, h)
        def child(vp, parent):
            px, py, _pw, _ph = parent
            w, h = vp['width'] * s, vp['height'] * s
            av, ah = _align(vp.get('alignment', 'TopLeft'))
            x, y = px + vp['xorigin'] * s, py + vp['yorigin'] * s
            return (x - (w / 2 if ah == 'Centre' else w if ah == 'Right' else 0),
                    y - (h / 2 if av == 'Centre' else h if av == 'Bottom' else 0), w, h)
        box = top_level(col['ViewPort'])
        node = col['Widgets'][0]['Widget']
        box = child(node['ViewPort'], box)                      # Background
        def find(w, name):
            if w.get('Name') == name: return w
            for c in w.get('ChildWidgets', []):
                hit = find(c['Widget'], name)
                if hit: return hit
            return None
        mv = find(node, 'MapView')
        if not mv: return None
        box = child(mv['ViewPort'], box)
        x, y, w, h = box
        pad = 0.06                                              # a little slack for layout rounding
        x, y = x - w * pad, y - h * pad
        w, h = w * (1 + 2 * pad), h * (1 + 2 * pad)
        return int(round(x)), int(round(y)), int(round(w)), int(round(h))
    except Exception as e:
        log('could not work out where the minimap is: %r' % (e,))
        return None

# ---------------------------------------------------------------- score check: is this game gone?
# Reads the score list the game draws in the corner of your own screen ('Name: 1234/5678', which is
# your score and then your team's total) and compares your side's total with the best opposing one.
# When you have been well behind for a while it says so, and that is all it does: it never resigns
# or clicks anything for you.
CONCEDE_BEHIND = 0.30        # flag once your side's total is more than this far behind theirs
CONCEDE_HOLD_S = 20          # ...and has stayed there this long, so one bad reading never sets it off
CONCEDE_FROM_MIN = 5         # not in the opening minutes, when scores are tiny and swing on one upgrade
# zeros often read as the letter o, sometimes after a gap: '1000/1 ooo'
SCORE_PAIR = re.compile(r'([\dOo]{2,6})\s*/\s*([\dOo]{1,6}(?:\s[Oo]{1,4})?)(?![\dOo])')

def score_rect(cw, ch):
    """Where the score list sits, from the game's own scorepanel.json, so a UI mod that moves it
    is followed. The list is pinned to the panel's bottom right corner and grows upwards."""
    s = ch / 2160.0
    xo, yo = 3840, 1800
    try:
        vp = (ui_json('scorepanel.json') or {})['Collection']['Widgets'][0]['Widget']['ViewPort']
        xo, yo = vp['xorigin'], vp['yorigin']
    except Exception:
        pass
    right, bottom = cw - (3840 - xo) * s, ch - (2160 - yo) * s
    w, h = 1000 * s, 480 * s                                  # eight players' worth of lines
    x0, y0 = max(0, right - w), max(0, bottom - h)
    return int(x0), int(y0), int(right - x0), int(bottom - y0)

def _score_name(text, names):
    """How well the words in front of a score match one of these names (0 none, 1 close, 2 exact).
    The game draws a few icons before the name, which read as a letter or two of junk."""
    t = _norm2(text.rsplit(':', 1)[0] if ':' in text else text)
    best = 0
    for nm in names:
        for v in name_variants(nm):
            n = _norm2(v)
            if len(n) < 3 or not t: continue
            if t.endswith(n): best = max(best, 2)
            elif len(n) >= 5 and difflib.SequenceMatcher(None, t[-len(n):], n).ratio() >= 0.8: best = max(best, 1)
    return best

def read_scores(lines, mine, others=(), players=2):
    """Score list text -> (your side's total, the best opposing total), or None when your own line
    could not be picked out. Only your line has to be recognised by name: every line carries its
    team's total, so any total that is not yours belongs to the other side."""
    rows = []
    for t in lines:
        hits = [m for m in SCORE_PAIR.finditer(t) if re.search(r'\d', m.group(1)) and re.search(r'\d', m.group(2))]
        if not hits: continue
        m = hits[-1]
        a, b = [int(re.sub(r'\s', '', v).replace('O', '0').replace('o', '0')) for v in m.groups()]
        if b < a or b < 10: continue                          # a team total under your own score is a misread
        if players == 2 and a != b: continue                  # one against one, the two numbers are the same
        rows.append((t[:m.start()], a, b))
    if len(rows) < 2: return None
    scored = sorted(((_score_name(r[0], mine), i) for i, r in enumerate(rows)), reverse=True)
    me = None
    if scored[0][0] and (len(scored) < 2 or scored[0][0] > scored[1][0] or rows[scored[0][1]][2] == rows[scored[1][1]][2]):
        me = rows[scored[0][1]]
    elif not scored[0][0] and players == 2 and len(rows) == 2 and others:
        theirs = [i for i, r in enumerate(rows) if _score_name(r[0], others)]
        if len(theirs) == 1: me = rows[1 - theirs[0]]         # 1v1 and their line read: the other one is you
    if me is None: return None
    rest = [r[2] for r in rows if r[2] != me[2]]
    return me[2], (max(rest) if rest else me[2])

class ScoreWatcher(threading.Thread):
    """Reads the score list every few seconds while you play and keeps track of how far behind you are."""
    def __init__(self, notify, minutes):
        super().__init__(daemon=True)
        self.notify = notify                  # notify(mine, theirs, behind, flag); notify(None, ...) clears it
        self.minutes = minutes                # how far into the game we are
        self.active, self.enabled = False, True
        self.pause_fn = lambda: False
        self.lock = threading.Lock()
        self.reset()

    def reset(self, mine=(), others=(), players=2):
        with self.lock:
            self.mine, self.others, self.players = list(mine), list(others), players
            self.since, self.n, self.clear, self.flag, self.miss = None, 0, 0, False, 0

    def step(self, mine, theirs, now):
        behind = (1.0 - mine / float(theirs)) if theirs else 0.0
        if behind > CONCEDE_BEHIND and self.minutes() >= CONCEDE_FROM_MIN:
            self.clear = 0; self.n += 1
            if self.since is None: self.since = now
            if not self.flag and self.n >= 4 and now - self.since >= CONCEDE_HOLD_S:
                self.flag = True
                log('score: %d against %d, %d%% behind, flagged' % (mine, theirs, round(behind * 100)))
        else:
            self.clear += 1
            if not self.flag or self.clear >= 3:              # three readings back in it before the flag comes down
                if self.flag: log('score: %d against %d, flag cleared' % (mine, theirs))
                self.since, self.n, self.flag = None, 0, False
        return behind

    def run(self):
        try:
            read = _load_ocr(); grab = _grabber()
        except Exception as e:
            log('score check off: %r' % (e,)); return
        ctypes, wintypes, u, _ = _win()
        was = False
        while True:
            time.sleep(3)
            on = self.active and self.enabled
            if on != was:
                was = on
                log('score check %s' % ('on' if on else 'off'))
                if not on:
                    try: self.notify(None, None, 0, False)
                    except Exception: pass
            if not on or self.pause_fn(): continue
            try:
                fg = u.GetForegroundWindow()
                pid = wintypes.DWORD(); u.GetWindowThreadProcessId(fg, ctypes.byref(pid))
                if not fg or not _proc_name(pid.value).startswith('aoe2de'): continue
                x, y, w, hh = client_rect(fg)
                if w < 400 or hh < 300: continue
                rx, ry, rw, rh = score_rect(w, hh)
                if rw < 50 or rh < 20: continue
                lines = read(*grab((x + rx, y + ry, rw, rh, 2 if hh < 1800 else 1)))
                with self.lock:
                    got = read_scores(lines, self.mine, self.others, self.players)
                    if not got:
                        self.miss += 1
                        if self.miss in (5, 60): log('score list not read: %s' % ' | '.join(lines)[:160])
                        continue
                    self.miss = 0
                    behind = self.step(got[0], got[1], time.time())
                    flag = self.flag
                self.notify(got[0], got[1], behind, flag)
            except Exception as e:
                log('score check: %r' % (e,)); time.sleep(2)

# ---------------------------------------------------------------- host a lobby and post the link to Discord
# Clicks through the game's own menus (Multiplayer > Host Game > Create Lobby) by reading the button
# text off the screen, presses the lobby's Copy button, then posts the join link to your Discord channel.
# the folder keeps the app's first name, so settings and stats carry over from older versions
SETTINGS = os.path.join(os.environ.get('APPDATA', HOME), 'AoE2MapOverlay', 'settings.json')

def load_settings():
    try: return json.load(open(SETTINGS, encoding='utf-8'))
    except Exception: return {'webhook': '', 'friends': [], 'channel': 'wesley'}

def save_settings(cfg):
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    json.dump(cfg, open(SETTINGS, 'w', encoding='utf-8'), indent=2)

STATS = os.path.join(os.path.dirname(SETTINGS), 'stats.json')

_stats_cache = {'key': None, 'data': None}

def _read_stats(path):
    with io.open(path, encoding='utf-8') as fh:
        d = json.load(fh)
    if not isinstance(d.get('games'), list): raise ValueError('no games list')
    return d

def _stats_copy(d):
    """A private copy, so a caller editing its own rows cannot touch the cache.
    Everything else at the top level is kept, civmap and repaired included."""
    out = dict(d)
    out['games'] = [dict(g) for g in d['games']]
    return out

def load_stats():
    """Every game the overlay has seen: {'games': [ ... newest last ... ]}.

    Cached against the file's size and timestamp, because the loading screen asks
    for the record several times in a row and the file grows game by game.
    """
    try:
        sb = os.stat(STATS)
        key = (sb.st_mtime_ns, sb.st_size)
    except OSError:
        key = None
    if key is not None and _stats_cache['key'] == key and _stats_cache['data'] is not None:
        return _stats_copy(_stats_cache['data'])
    d = None
    if key is not None:
        try: d = _read_stats(STATS)
        except Exception as e:
            log('the record file would not read (%r), trying the backup' % (e,))
    if d is None:
        try: d = _read_stats(STATS + '.bak')
        except Exception: d = None
    if d is None: return {'games': []}
    _stats_cache['key'], _stats_cache['data'] = key, _stats_copy(d)
    return d

def save_stats(d):
    """Write the record safely: new file first, keep the old one as the backup.

    A half written stats.json would read as no games at all, so the record is never
    truncated in place. Your history is the one thing here that cannot be rebuilt.
    """
    try:
        os.makedirs(os.path.dirname(STATS), exist_ok=True)
        tmp = STATS + '.new'
        with io.open(tmp, 'w', encoding='utf-8') as fh:
            json.dump(d, fh, indent=1)
            fh.flush()
            try: os.fsync(fh.fileno())
            except OSError: pass
        if os.path.exists(STATS):
            try: shutil.copy2(STATS, STATS + '.bak')
            except Exception: pass
        os.replace(tmp, STATS)
        try:
            sb = os.stat(STATS)
            _stats_cache['key'], _stats_cache['data'] = (sb.st_mtime_ns, sb.st_size), _stats_copy(d)
        except OSError:
            _stats_cache['key'] = None
    except Exception as e:
        _stats_cache['key'] = None
        log('could not write the record: %r' % (e,))

STATS_LOCK = threading.RLock()

def record_game(entry):
    """Add a game, or update the one already stored under the same replay name."""
    with STATS_LOCK:
        return _record_game(entry)

def _record_game(entry):
    d = load_stats()
    for g in d['games']:
        if g.get('id') == entry.get('id'):
            g.update({k: v for k, v in entry.items() if v not in (None, '')})
            save_stats(d); return g
    d['games'].append(entry)
    d['games'] = d['games'][-2000:]
    save_stats(d); return entry

def civ_name(cid, strings):
    return STOCK.get(str(10270 + cid)) or strings.get(str(10270 + cid), 'Civ %d' % cid)

MATCH_URL = ('https://aoe-api.worldsedgelink.com/community/leaderboard/'
             'getRecentMatchHistory?title=age2&profile_ids=[%d]')

def relic_matches(profile):
    """Your recent games as the ranked service recorded them: when, how big, and whether you won.
    Same match history the game shows on your own profile page."""
    out = []
    if not profile: return out
    import urllib.request
    try:
        req = urllib.request.Request(MATCH_URL % int(profile), headers={'User-Agent': 'AoE2Wingman/1.0'})
        with urllib.request.urlopen(req, timeout=8) as r:
            data = json.loads(r.read().decode('utf-8'))
    except Exception as e:
        log('match history lookup failed: %r' % (e,)); return out
    for m in data.get('matchHistoryStats', []):
        rows = m.get('matchhistoryreportresults') or []
        mine = next((x for x in rows if x.get('profile_id') == int(profile)), None)
        if not mine or mine.get('resulttype') not in (0, 1): continue
        teams = {}
        for x in rows:
            teams[x.get('teamid')] = teams.get(x.get('teamid'), 0) + 1
        sizes = sorted(teams.values(), reverse=True)
        out.append(dict(match=m.get('id'),
                        start=int(mine.get('matchstartdate') or m.get('startgametime') or 0),
                        end=int(m.get('completiontime') or 0),
                        result='win' if mine.get('resulttype') == 1 else 'loss',
                        mode='1v1' if len(rows) == 2 else 'TG',
                        size=('v'.join(str(x) for x in sizes) if len(sizes) > 1
                              else '%d players' % len(rows)),
                        civ_id=mine.get('civilization_id'),
                        map=(m.get('mapname') or ''),
                        ranked=(m.get('description') or '').upper() == 'AUTOMATCH',
                        # whose recorded game the service still holds for this match
                        replays=[u.get('profile_id') for u in (m.get('matchurls') or [])
                                 if isinstance(u, dict) and u.get('profile_id')
                                 and str(u.get('size', '0')).lstrip('-').isdigit() and int(u.get('size', 0)) > 0]))
    return out

def _mapkey(name):
    """'Arabia.rms' and 'Arabia' come out the same; '' when there is nothing to compare."""
    return re.sub(r'[^a-z]', '', re.sub(r'\.rms\d*$', '', (name or '').lower()))

def fill_results(profile, days=21):
    """Write in the result for any recent game the service knows about. Only the service sets a
    result: it cannot be misread, and a wrong win in the record is worse than no result at all."""
    cut = time.time() - days * 86400
    if not [g for g in load_stats()['games']
            if max(g.get('started', 0), g.get('ended', 0)) > cut and g.get('src') != 'service']:
        return 0
    matches = relic_matches(profile)       # the slow bit, so no lock is held while it runs
    if not matches: return 0
    with STATS_LOCK:
        return _fill_results(matches, cut)

def _fill_results(matches, cut):
    d = load_stats()
    todo = [g for g in d['games']
            if max(g.get('started', 0), g.get('ended', 0)) > cut and g.get('src') != 'service']
    if not todo: return 0
    taken = {g.get('match') for g in d['games'] if g.get('match')}
    filled = 0
    for g in sorted(todo, key=lambda x: -x.get('started', 0)):
        t, e = g.get('started') or 0, g.get('ended') or 0
        if not t and not e: continue
        best, best_gap = None, 1e9
        for m in matches:
            if m['match'] in taken: continue
            mk, gk = _mapkey(m.get('map')), _mapkey(g.get('map'))
            if mk and gk and mk != gk: continue             # a different map, so a different game
            if t and m['end'] < t - 120: continue           # it finished before this game started
            gap = min(abs(m['start'] - t) if t else 1e9,
                      abs(m['end'] - e) if e else 1e9)
            if gap < best_gap: best, best_gap = m, gap
        if best is None or best_gap > 600: continue         # 10 minutes, or it is not the same game
        g.update(result=best['result'], src='service', match=best['match'],
                 ranked=best['ranked'], mode=best['mode'], size=best['size'])
        taken.add(best['match'])
        if best.get('civ_id') is not None and g.get('civ'):
            d.setdefault('civmap', {})[str(best['civ_id'])] = g['civ']   # learn their civ numbering
        filled += 1
    if filled:
        save_stats(d); log('filled in %d result(s) from the match history' % filled)
    return filled

def repair_results():
    """One off: drop any result that did not come from the service, and the bogus end times that
    an earlier version wrote at the start of a game."""
    with STATS_LOCK:
        return _repair_results()

def _repair_results():
    d = load_stats()
    if d.get('repaired') == 2: return 0
    n = 0
    for g in d['games']:
        if g.get('src') != 'service' and g.get('result') in ('win', 'loss'):
            g['result'] = '?'; g.pop('src', None); n += 1
        if g.get('started') and 0 <= (g.get('ended') or 0) - g['started'] < 180:
            g['ended'] = 0
    d['repaired'] = 2
    save_stats(d)
    if n: log('cleared %d result(s) that were not confirmed by the match history' % n)
    return n

def game_mode(players):
    """('1v1'|'TG', '1v1'|'2v2'|'4 players')."""
    if len(players) <= 2: return '1v1', '1v1'
    teams = {}
    for p in players:
        if p['team'] > 1: teams[p['team']] = teams.get(p['team'], 0) + 1
    sizes = sorted(teams.values(), reverse=True)
    if len(sizes) > 1: return 'TG', 'v'.join(str(x) for x in sizes)
    return 'TG', '%d players' % len(players)

def game_entry(path, lob, maps, strings, me):
    """One row for the record, built from the replay the game just started writing."""
    players = lob['players']
    mine = (next((p for p in players if p['human'] and p['profile'] == me), None)
            or next((p for p in players if p['human']), None))
    opps = [p for p in players if p is not mine and
            (mine is None or p['team'] <= 1 or p['team'] != mine['team'])]
    mode, size = game_mode(players)
    try:
        name = map_text(maps, strings, lob['selected'], lob['resolved'], lob.get('size'), len(players))[0]
    except Exception:
        name = 'Map'
    try:
        started, ended = int(os.path.getctime(path)), int(os.path.getmtime(path))
        if ended - started < 180: ended = 0        # the game has only just started writing this
    except OSError:
        started, ended = int(time.time()), 0
    return dict(id=os.path.basename(path), started=started, ended=ended,
                at=time.strftime('%Y-%m-%d %H:%M', time.localtime(started)),
                map=name, civ=civ_name(mine['civ'], strings) if mine else 'Unknown',
                opp=civ_name(opps[0]['civ'], strings) if opps else '',
                players=len(players), mode=mode, size=size, result='?')

def backfill(maps, strings, me, limit=80):
    """Read the replays already sitting in the savegame folder, so the record is not empty on day one."""
    d = load_stats()
    have = {g.get('id') for g in d['games']}
    files = [p for p, _ in sorted(_replay_entries(), key=lambda x: x[1])[-limit:]]
    rows = []
    for f in files:
        if os.path.basename(f) in have: continue
        try:
            lob = read_lobby(f)
            if lob and lob.get('players'): rows.append(game_entry(f, lob, maps, strings, me))
        except Exception:
            continue
    if rows:
        d['games'] = sorted(d['games'] + rows, key=lambda g: g.get('started', 0))
        save_stats(d); log('added %d past game(s) from the savegame folder' % len(rows))
    return len(rows)

def civ_tally(games, civ_only=True):
    """[(civ, played, wins, losses, unknown)] sorted by games played."""
    rows = {}
    for g in games:
        key = g.get('civ') or 'Unknown'
        r = rows.setdefault(key, [key, 0, 0, 0, 0])
        r[1] += 1
        r[{'win': 2, 'loss': 3}.get(g.get('result'), 4)] += 1
    return sorted(rows.values(), key=lambda r: (-r[1], r[0]))

def filter_games(games, mode='all', days=0, ranked=False):
    """The games the record page is looking at right now."""
    out = games
    if mode in ('1v1', 'TG'): out = [g for g in out if g.get('mode') == mode]
    if days:
        cut = time.time() - days * 86400
        out = [g for g in out if max(g.get('started', 0), g.get('ended', 0)) >= cut]
    if ranked: out = [g for g in out if g.get('ranked')]
    return out

def tally_by(games, key, blank='Unknown'):
    """[(name, played, wins, losses, unknown)] for any field (civ, opp, map), most played first."""
    rows = {}
    for g in games:
        name = (g.get(key) or '').strip() or blank
        r = rows.setdefault(name, [name, 0, 0, 0, 0])
        r[1] += 1
        r[{'win': 2, 'loss': 3}.get(g.get('result'), 4)] += 1
    return sorted(rows.values(), key=lambda r: (-r[1], r[0]))

def current_streak(games):
    """('W', 3) for three wins in a row, newest first; (None, 0) with nothing decided."""
    kind, n = None, 0
    for g in reversed(games):
        r = g.get('result')
        if r not in ('win', 'loss'): continue
        k = 'W' if r == 'win' else 'L'
        if kind is None: kind = k
        if k != kind: break
        n += 1
    return kind, n

def game_length(g):
    """Seconds from start to finish, when both ends were seen and it looks like a real game."""
    t, e = g.get('started') or 0, g.get('ended') or 0
    d = e - t
    return d if 60 <= d <= 4 * 3600 else None

def fmt_len(sec):
    return '-' if not sec else '%d min' % round(sec / 60.0)

def best_worst(rows, least=3):
    """The strongest and weakest entries with at least `least` decided games."""
    ok = [(r[2] / float(r[2] + r[3]), r) for r in rows if r[2] + r[3] >= least]
    if not ok: return None, None
    ok.sort(key=lambda x: (x[0], x[1][2] + x[1][3]))
    return ok[-1], ok[0]

def map_bans(games, least=4, n=3):
    """The maps worth banning: your worst ones, with enough decided games to mean something.
    Sorted by win rate, and a map you have lost more often breaks a tie."""
    rows = [r for r in tally_by(games, 'map')
            if r[2] + r[3] >= least and r[0] != 'Unknown' and r[2] < (r[2] + r[3]) / 2.0]
    rows.sort(key=lambda r: (r[2] / float(r[2] + r[3]), -(r[2] + r[3])))
    return rows[:n]

# ---------------------------------------------------------------- update from GitHub
# Brings the app up to date with a branch of its repository, then restarts it. Prod is the settled
# version and dev has the newest changes first. Where the app sits in a git folder it uses git (and
# the sign-in git already has), so each branch keeps its own folder tidy. A loose copy is replaced
# by a download instead.
REPO = 'Ashley-Pettit/aoe2-wingman'
BAT_NAME = 'AoE2 Wingman.bat'
BRANCHES = ('Prod', 'dev')

def self_path():
    return os.path.abspath(sys.argv[0])

def _sha(path):
    import hashlib
    try:
        with open(path, 'rb') as f: return hashlib.sha1(f.read()).hexdigest()
    except OSError:
        return ''

SELF_SHA = _sha(self_path())                 # this copy as it was when it started

def _git(folder, *args, **kw):
    import subprocess
    r = subprocess.run(['git', '-C', folder] + list(args), capture_output=True, timeout=kw.get('timeout', 30),
                       creationflags=0x08000000, env=dict(os.environ, GIT_TERMINAL_PROMPT='0'))
    return (r.returncode, r.stdout.decode('utf-8', 'replace').strip(), r.stderr.decode('utf-8', 'replace').strip())

def git_branch(folder):
    """The branch a folder is on, or None when the folder is not a checkout of this app's repository."""
    try:
        code, top, _ = _git(folder, 'rev-parse', '--show-toplevel')
        if code or os.path.normcase(os.path.abspath(top)) != os.path.normcase(os.path.abspath(folder)): return None
        code, url, _ = _git(folder, 'remote', 'get-url', 'origin')
        if code or not re.search(r'aoe2-(wingman|map-overlay)', url, re.I): return None
        code, branch, _ = _git(folder, 'rev-parse', '--abbrev-ref', 'HEAD')
        return None if code else branch
    except Exception:
        return None

def script_version(path):
    try:
        with io.open(path, encoding='utf-8', errors='replace') as f:
            m = re.search(r"^VERSION = '([^']+)'", f.read(4000), re.M)
        return m.group(1) if m else '?'
    except OSError:
        return '?'

def update_target(branch, here):
    """(folder that holds this branch, the branch that folder is on now). This folder if it is
    already on the branch, else a folder beside it named after the branch, else this one again."""
    mine = git_branch(here)
    if mine == branch: return here, mine
    beside = os.path.join(os.path.dirname(here), branch)
    if os.path.isdir(beside) and git_branch(beside) == branch: return beside, branch
    return here, mine

def _last_line(text):
    lines = [l.strip() for l in (text or '').splitlines() if l.strip()]
    return lines[-1][:160] if lines else 'no reason given'

def _download_script(branch):
    """The script from GitHub without git: GitHub's own gh tool if it is signed in (the repository is
    private), else the plain public address."""
    import subprocess, urllib.request, urllib.parse
    name = urllib.parse.quote(BAT_NAME)
    try:
        r = subprocess.run(['gh', 'api', '-H', 'Accept: application/vnd.github.raw',
                            'repos/%s/contents/%s?ref=%s' % (REPO, name, branch)],
                           capture_output=True, timeout=60, creationflags=0x08000000)
        if r.returncode == 0 and r.stdout: return r.stdout
    except Exception as e:
        log('gh download: %r' % (e,))
    try:
        req = urllib.request.Request('https://raw.githubusercontent.com/%s/%s/%s' % (REPO, branch, name),
                                     headers={'User-Agent': 'AoE2Wingman/1.0'})
        with urllib.request.urlopen(req, timeout=30) as r: return r.read(20_000_000)
    except Exception as e:
        log('plain download: %r' % (e,))
    return None

def _looks_like_the_app(data):
    """Never replace the running script with something that is not this app, or would not start."""
    try:
        text = data.decode('utf-8')
        first, body = text.split('\n', 1)
        if not first.startswith('@(') or 'pythonw' not in first: return False
        import ast
        ast.parse(body)
        return bool(re.search(r"^VERSION = '[^']+'", body[:4000], re.M)) and 'def main():' in body
    except Exception:
        return False

def update_by_download(branch, target):
    data = _download_script(branch)
    if data is None:
        return False, ('Could not download it. The repository is private, so this copy needs to be in '
                       'a git folder, or GitHub\'s gh tool needs to be signed in.'), None
    if not _looks_like_the_app(data):
        return False, 'What came back from GitHub does not look like the app, so nothing was changed.', None
    try:
        with open(target, 'rb') as f: old = f.read()
    except OSError:
        old = b''
    if data == old:
        return True, 'Already up to date: %s on %s.' % (script_version(target), branch), None
    try:
        keep = os.path.join(os.path.dirname(SETTINGS), 'backup')
        os.makedirs(keep, exist_ok=True)
        if old:
            with open(os.path.join(keep, '%s %s.bat' % (os.path.splitext(os.path.basename(target))[0],
                                                       script_version(target))), 'wb') as f: f.write(old)
        tmp = target + '.new'
        with open(tmp, 'wb') as f: f.write(data)
        os.replace(tmp, target)
    except OSError as e:
        return False, 'Could not write the new version: %s' % e, None
    return True, 'Updated to %s from %s.' % (script_version(target), branch), target

def update_from_github(branch, me_=None, running=None):
    """Bring the app up to date with a branch. me_ is the running script and running is its
    (version, fingerprint) from when it started. Returns (worked, what to tell you, the script
    to start afterwards, or None when there is nothing new to restart into)."""
    me_ = me_ or self_path()
    here = os.path.dirname(me_)
    run_ver, run_sha = running or (VERSION, SELF_SHA)
    if branch not in BRANCHES: return False, 'No such branch: %s' % branch, None
    folder, on = update_target(branch, here)
    if on is None:
        return update_by_download(branch, me_)
    code, _, err = _git(folder, 'fetch', '--quiet', 'origin', timeout=90)
    if code: return False, 'Could not reach GitHub: %s' % _last_line(err), None
    code, _, _ = _git(folder, 'rev-parse', '--verify', '--quiet', 'origin/%s' % branch)
    if code: return False, 'GitHub has no %s branch.' % branch, None
    if on != branch:                              # one folder for both: switch it over, if nothing here was edited
        code, edits, err = _git(folder, 'status', '--porcelain', '--untracked-files=no')
        if code or edits:
            return False, 'This folder has changes that are not on GitHub, so it was left as it is.', None
        code, _, err = _git(folder, 'checkout', '--quiet', '-B', branch, 'origin/%s' % branch)
    else:
        code, _, err = _git(folder, 'merge', '--quiet', '--ff-only', 'origin/%s' % branch)
    if code:
        if re.search(r'local changes|overwritten|not possible to fast-forward|diverg', err, re.I):
            return False, 'This folder has changes that are not on GitHub, so it was left as it is.', None
        return False, 'Could not update: %s' % _last_line(err), None
    bat = os.path.join(folder, BAT_NAME)
    if not os.path.isfile(bat): return False, 'The %s branch has no %s in it.' % (branch, BAT_NAME), None
    new_ver = script_version(bat)
    same_file = os.path.normcase(os.path.abspath(bat)) == os.path.normcase(os.path.abspath(me_))
    if _sha(bat) == run_sha and same_file:
        return True, 'Already up to date: %s on %s.' % (new_ver, branch), None
    if not same_file:                             # that branch has its own folder: start the copy in it
        return True, 'Switching to the %s copy: %s.' % (branch, new_ver), bat
    if on != branch:
        return True, 'Switched this folder to %s: %s.' % (branch, new_ver), bat
    return True, ('Updated from %s to %s (%s).' % (run_ver, new_ver, branch)) if new_ver != run_ver \
        else 'Updated %s (%s).' % (new_ver, branch), bat

def restart_app(bat):
    """Start the given copy. The caller closes this one straight after."""
    import subprocess
    log('restarting from %s' % bat)
    subprocess.Popen(['cmd', '/c', bat], cwd=os.path.dirname(bat), creationflags=0x08000000, close_fds=True)

GOD_MODE_ID = 517794                       # God Mode [CORE] on the official mod site
GOD_MODE_URL = 'https://www.ageofempires.com/mods/details/%d/' % GOD_MODE_ID

def god_mode_status():
    """('on' | 'off' | 'missing', a line to show), read from the game's own mod list.
    Counts the published mod and a local build of it alike."""
    found = False
    for f in glob.glob(os.path.join(GAMES, '*', 'mods', 'mod-status.json')):
        try: d = json.load(open(f, encoding='utf-8-sig'))
        except Exception: continue
        for m in d.get('Mods', []):
            name = _norm2('%s %s' % (m.get('Title') or '', m.get('Path') or ''))
            if m.get('WorkshopID') != GOD_MODE_ID and 'godmode' not in name: continue
            parts = [p for p in re.split(r'[\\/]+', m.get('Path', '')) if p]
            if not parts or not os.path.isdir(os.path.join(os.path.dirname(f), *parts)): continue
            if m.get('Enabled'): return 'on', 'Installed and switched on.'
            found = True
    if found: return 'off', 'Installed but switched off. Turn it on in the game under Mods.'
    return 'missing', 'Not installed.'

def open_god_mode_page():
    """The official mod site needs you signed in to subscribe, so this opens the page for you to do that."""
    import webbrowser
    log('opening the God Mode mod page')
    webbrowser.open(GOD_MODE_URL)

def mod_clashes():
    """Files that more than one enabled mod ships. mod_dirs() is already in the game's own
    priority order, so the first mod listed for a file is the one that actually wins.
    Returns [(winner, loser, count, [example files])] worst first."""
    seen = {}
    for d in mod_dirs():
        name = os.path.basename(d) or d
        res = os.path.join(d, 'resources')
        if not os.path.isdir(res): continue
        for base, _dirs, files in os.walk(res):
            rel_base = os.path.relpath(base, d)
            for f in files:
                rel = os.path.normcase(os.path.join(rel_base, f))
                who = seen.setdefault(rel, [])
                if name not in who: who.append(name)
    pairs = {}
    for rel, who in seen.items():
        if len(who) < 2: continue
        for loser in who[1:]:
            e = pairs.setdefault((who[0], loser), [0, []])
            e[0] += 1
            if len(e[1]) < 4: e[1].append(os.path.basename(rel))
    out = [(w, l, n, ex) for (w, l), (n, ex) in pairs.items()]
    out.sort(key=lambda r: -r[2])
    return out

def post_discord(url, content):
    import urllib.request
    body = json.dumps({'content': content, 'allowed_mentions': {'parse': ['users']}}).encode('utf-8')
    req = urllib.request.Request(url, data=body, method='POST',
                                 headers={'Content-Type': 'application/json', 'User-Agent': 'AoE2Wingman (local, 1.0)'})
    with urllib.request.urlopen(req, timeout=15) as r: return r.status

def mention(name):
    n = name.strip()
    if re.fullmatch(r'\d{15,21}', n): return '<@%s>' % n            # a Discord user ID pings them
    if re.fullmatch(r'<@!?\d+>', n): return n
    return '@' + n.lstrip('@')

def invite_message(link, gid, friends):
    who = ' '.join(mention(f) for f in friends if f.strip())
    lines = ['Lobby is up, jump in: %s' % link]
    if gid: lines.append('Game ID: %s  (paste the link into your browser, or the ID into the lobby browser search)' % gid)
    if who: lines.append(who)
    return '\n'.join(lines)

def _win():
    import ctypes
    from ctypes import wintypes
    u = ctypes.windll.user32; k = ctypes.windll.kernel32
    try: u.SetThreadDpiAwarenessContext(ctypes.c_void_p(-4))
    except Exception: pass
    return ctypes, wintypes, u, k

def _proc_name(pid):
    ctypes, wintypes, u, k = _win()
    k.OpenProcess.restype = ctypes.c_void_p; k.CloseHandle.argtypes = [ctypes.c_void_p]
    k.QueryFullProcessImageNameW.argtypes = [ctypes.c_void_p, wintypes.DWORD, wintypes.LPWSTR, ctypes.POINTER(wintypes.DWORD)]
    hp = k.OpenProcess(0x1000, False, pid)                  # query limited information
    if not hp: return ''
    try:
        buf = ctypes.create_unicode_buffer(520); n = wintypes.DWORD(520)
        return os.path.basename(buf.value).lower() if k.QueryFullProcessImageNameW(hp, 0, buf, ctypes.byref(n)) else ''
    finally:
        k.CloseHandle(hp)

def find_game_window():
    """The AoE2 DE game window, found by its program (AoE2DE_s.exe), not just its title."""
    ctypes, wintypes, u, _ = _win()
    by_exe, by_title = [], []
    proto = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(h, l):
        if u.IsWindowVisible(h) and not u.GetWindow(h, 4):     # top-level, no owner
            pid = wintypes.DWORD(); u.GetWindowThreadProcessId(h, ctypes.byref(pid))
            if _proc_name(pid.value).startswith('aoe2de'): by_exe.append(h)
            else:
                n = u.GetWindowTextLengthW(h)
                b = ctypes.create_unicode_buffer(n + 1); u.GetWindowTextW(h, b, n + 1)
                if b.value.strip() == 'Age of Empires II: Definitive Edition': by_title.append(h)
        return True
    u.EnumWindows(proto(cb), 0)
    return (by_exe or by_title or [None])[0]

def window_elevated(h):
    """True if the game runs as administrator. Windows then blocks clicks from normal programs."""
    ctypes, wintypes, u, k = _win()
    a = ctypes.windll.advapi32
    pid = wintypes.DWORD(); u.GetWindowThreadProcessId(h, ctypes.byref(pid))
    k.OpenProcess.restype = ctypes.c_void_p; k.CloseHandle.argtypes = [ctypes.c_void_p]
    a.OpenProcessToken.argtypes = [ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p)]
    a.GetTokenInformation.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    hp = k.OpenProcess(0x1000, False, pid.value)
    if not hp: return True
    tok = ctypes.c_void_p()
    try:
        if not a.OpenProcessToken(hp, 0x0008, ctypes.byref(tok)): return True
        val = wintypes.DWORD(); n = wintypes.DWORD()
        a.GetTokenInformation(tok, 20, ctypes.byref(val), 4, ctypes.byref(n))      # TokenElevation
        k.CloseHandle(tok)
        return bool(val.value)
    finally:
        k.CloseHandle(hp)

def overlay_is_admin():
    try:
        import ctypes
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False

ADMIN_MSG = ("The game is running as administrator (because Steam is), so Windows blocks the overlay's clicks. "
             "Turn off 'Run as administrator' for Steam, restart Steam and the game, then try again.")

def focus_window(h):
    """Bring the game to the front. Windows blocks this unless we look like the user, so tap Alt first."""
    ctypes, wintypes, u, _ = _win()
    if u.IsIconic(h): u.ShowWindow(h, 9)
    for _ in range(3):
        u.keybd_event(0x12, 0, 0, 0); u.keybd_event(0x12, 0, 2, 0)          # Alt down/up
        u.ShowWindow(h, 5); u.BringWindowToTop(h); u.SetForegroundWindow(h)
        time.sleep(0.4)
        if u.GetForegroundWindow() == h: return True
    log('could not bring the game to the front')
    return False

def client_rect(h):
    ctypes, wintypes, u, _ = _win()
    r = wintypes.RECT(); u.GetClientRect(h, ctypes.byref(r))
    p = wintypes.POINT(0, 0); u.ClientToScreen(h, ctypes.byref(p))
    return p.x, p.y, r.right, r.bottom

def _send_mouse(flags, dx=0, dy=0, data=0):
    ctypes, wintypes, u, _ = _win()
    class MI(ctypes.Structure):
        _fields_ = [('dx', ctypes.c_long), ('dy', ctypes.c_long), ('mouseData', wintypes.DWORD),
                    ('dwFlags', wintypes.DWORD), ('time', wintypes.DWORD), ('dwExtraInfo', ctypes.c_size_t)]
    class INP(ctypes.Structure):
        class _U(ctypes.Union):
            _fields_ = [('mi', MI), ('pad', ctypes.c_byte * 32)]
        _anonymous_ = ('u',)
        _fields_ = [('type', wintypes.DWORD), ('u', _U)]
    i = INP(); i.type = 0
    i.mi = MI(dx, dy, data & 0xFFFFFFFF, flags, 0, 0)
    u.SendInput(1, ctypes.byref(i), ctypes.sizeof(INP))

def _move_to(x, y):
    ctypes, wintypes, u, _ = _win()
    vx, vy, vw, vh = (u.GetSystemMetrics(i) for i in (76, 77, 78, 79))
    ax = int((x - vx) * 65535 / max(1, vw - 1)); ay = int((y - vy) * 65535 / max(1, vh - 1))
    u.SetCursorPos(int(x), int(y))
    _send_mouse(0x0001 | 0x8000 | 0x4000, ax, ay)                # absolute move (virtual desktop)
    time.sleep(0.03)
    _send_mouse(0x0001, 2, 0); time.sleep(0.02); _send_mouse(0x0001, -2, 0)   # small real nudge for the game's own cursor
    time.sleep(0.06)

STOP = threading.Event()                 # set by the Stop button
OVERLAY_TOP = [None]                     # the overlay's window, so a click that lands on it can pass through
class Stopped(Exception): pass

def check_stop():
    if STOP.is_set(): raise Stopped()

def _pass_through(on):
    top = OVERLAY_TOP[0]
    if not top: return
    ctypes, wintypes, u, _ = _win()
    ex = u.GetWindowLongW(top, -20)
    u.SetWindowLongW(top, -20, (ex | 0x20 | 0x80000) if on else (ex & ~0x20))

def _over_overlay(x, y):
    top = OVERLAY_TOP[0]
    if not top: return False
    ctypes, wintypes, u, _ = _win()
    r = wintypes.RECT(); u.GetWindowRect(top, ctypes.byref(r))
    return r.left <= x < r.right and r.top <= y < r.bottom

GAME_HWND = [None]                       # the game window the macro is driving

class NotInGame(Exception): pass

def game_in_front():
    """True if the game is the window in front (so a screen read or click lands on the game, nothing else)."""
    h = GAME_HWND[0]
    if not h: return True
    ctypes, wintypes, u, _ = _win()
    return u.GetForegroundWindow() == h

def point_on_game(x, y):
    h = GAME_HWND[0]
    if not h: return True
    ctypes, wintypes, u, _ = _win()
    u.WindowFromPoint.argtypes = [wintypes.POINT]; u.WindowFromPoint.restype = wintypes.HWND
    w = u.WindowFromPoint(wintypes.POINT(int(x), int(y)))
    root_ = u.GetAncestor(w, 2) if w else None
    return root_ in (h, OVERLAY_TOP[0])

def click(x, y):
    """A real mouse click the game sees: move there, press, hold briefly, release.
    Refuses to click anything that isn't the game, in case another window has come to the front."""
    check_stop()
    if not game_in_front() or not point_on_game(x, y):
        raise NotInGame()
    through = _over_overlay(x, y)            # the overlay sits over the game: let this one click go through it
    if through: _pass_through(True)
    try:
        _move_to(x, y)
        _send_mouse(0x0002); time.sleep(0.09); _send_mouse(0x0004)
        time.sleep(0.05)
    finally:
        if through: _pass_through(False)

def read_clipboard():
    ctypes, wintypes, u, k = _win()
    u.OpenClipboard.argtypes = [ctypes.c_void_p]; u.GetClipboardData.restype = ctypes.c_void_p
    k.GlobalLock.restype = ctypes.c_void_p; k.GlobalLock.argtypes = [ctypes.c_void_p]; k.GlobalUnlock.argtypes = [ctypes.c_void_p]
    for _ in range(5):
        if u.OpenClipboard(None): break
        time.sleep(0.1)
    else:
        return ''
    try:
        hd = u.GetClipboardData(13)                        # unicode text
        if not hd: return ''
        p = k.GlobalLock(hd)
        try: return ctypes.wstring_at(p) if p else ''
        finally: k.GlobalUnlock(hd)
    finally:
        u.CloseClipboard()

def find_phrase(lines, phrase, near=None):
    """Centre (x, y) of where the phrase appears in the OCR words (closest to `near` if given), or None."""
    target = _norm(phrase)
    if not target: return None
    hits = []
    for _, ws in lines:
        for i in range(len(ws)):
            acc = ''
            for j in range(i, min(len(ws), i + 5)):
                piece = _norm(ws[j][0])
                if not piece: break
                acc += piece
                close = len(target) >= 8 and abs(len(acc) - len(target)) <= 2 and \
                    difflib.SequenceMatcher(None, acc, target).ratio() >= 0.82
                if acc == target or close:
                    x0 = min(w[1] for w in ws[i:j + 1]); y0 = min(w[2] for w in ws[i:j + 1])
                    x1 = max(w[1] + w[3] for w in ws[i:j + 1]); y1 = max(w[2] + w[4] for w in ws[i:j + 1])
                    hits.append(((x0 + x1) / 2, (y0 + y1) / 2))
                    break
                if len(acc) > len(target) + 2: break
    if not hits: return None
    if near: return min(hits, key=lambda p: (p[0] - near[0]) ** 2 + (p[1] - near[1]) ** 2)
    return hits[0]

def find_number(lines, digits):
    for _, ws in lines:
        for w in ws:
            if digits in w[0]: return w[1] + w[3] / 2, w[2] + w[4] / 2
    return None

class HostInvite(threading.Thread):
    def __init__(self, strings, cfg, say, done, send_only=False):
        super().__init__(daemon=True)
        self.send_only = send_only
        st = lambda i, d: clean(strings.get(str(i), d)).replace('&&', '&')
        self.l_mp, self.l_host = st(9203, 'Multiplayer'), st(170071, 'Host Game')
        self.l_create, self.l_copy = st(200040, 'Create Lobby'), st(9962, 'Copy')
        gid = st(9961, 'Game ID: %u').split('%')[0].strip().rstrip(':')
        self.gid_re = re.compile(re.escape(gid).replace('\\ ', r'\s*') + r'\W*(\d{4,})', re.I)
        self.cfg, self.say, self.done = cfg, say, done

    def run(self):
        ok = False
        try: ok = self.work()
        except Stopped:
            log('stopped by user'); self.say('Stopped.')
        except NotInGame:
            log('game not in front, stopped'); self.say("Stopped: the game wasn't the window in front, so I didn't click.")
        except Exception as e:
            log('host failed: %r' % (e,)); self.say('Host failed: %s' % e)
        self.done(ok)

    def work(self):
        read = _load_ocr(); grab = _grabber()
        h = find_game_window()
        if not h: self.say('Start the game first, then press Host.'); return False
        GAME_HWND[0] = h
        if not overlay_is_admin() and window_elevated(h):
            self.say(ADMIN_MSG); log('game is elevated, clicks would be blocked'); return False
        if not focus_window(h):
            self.say("Couldn't bring the game to the front. Click on the game once, then press the button again."); return False
        time.sleep(0.5)
        gid, link = None, None
        for step in range(4 if self.send_only else 30):
            x, y, w, hh = client_rect(h)
            k = 2 if hh < 1300 else 1
            lines = read(*grab((x, y, w, hh, k)), words=True)
            text = ' '.join(t for t, _ in lines)
            m = self.gid_re.search(text)
            if m:                                           # we're in the lobby
                gid = m.group(1)
                before = read_clipboard()
                p = find_phrase(lines, self.l_copy, near=find_number(lines, gid))
                if p:
                    click(x + p[0] / k, y + p[1] / k); time.sleep(0.6)
                    after = read_clipboard()
                    if after and after != before and ('://' in after or gid in after): link = after.strip()
                link = link or 'aoe2de://0/%s' % gid
                break
            if self.send_only:                             # just looking for the lobby you're already in
                time.sleep(1); continue
            for label, msg in ((self.l_create, 'Creating the lobby...'), (self.l_host, 'Opening Host Game...'),
                               (self.l_mp, 'Opening Multiplayer...')):
                p = find_phrase(lines, label)
                if p:
                    self.say(msg); log('click %r at %s' % (label, p))
                    click(x + p[0] / k, y + p[1] / k); time.sleep(2.5)
                    break
            else:
                time.sleep(1.5)
        if not link:
            if self.send_only:
                # ranked parties have no join link, so post a heads-up instead
                url = self.cfg.get('webhook', '').strip()
                if not url: self.say('No lobby link on screen (ranked has none). Add your Discord link in settings.'); return False
                who = ' '.join(mention(f) for f in (self.cfg.get('pings') or self.cfg.get('friends', [])) if f.strip())
                post_discord(url, (who + ' ' if who else '') + 'Jumping on ranked now, come online and accept my party invite.')
                self.say('Ranked has no lobby link, so I posted a heads-up to #%s instead.' % (self.cfg.get('channel') or 'discord'))
                return True
            self.say("Couldn't reach the lobby. Get to the main menu and try again."); return False
        log('lobby %s link %s' % (gid, link))
        url = self.cfg.get('webhook', '').strip()
        if not url:
            self.say('Lobby %s is up. Add your Discord link in settings to post it.' % gid); return True
        post_discord(url, invite_message(link, gid, self.cfg.get('pings') or self.cfg.get('friends', [])))
        self.say('Lobby %s is up and posted to #%s.' % (gid, self.cfg.get('channel') or 'discord'))
        return True

def _norm2(t): return re.sub(r'[^a-z0-9]', '', t.lower())

def find_name(lines, name):
    """Centre of a player's name in the OCR words (tolerates the globe icon and small misreads)."""
    target = _norm2(name)
    if not target: return None
    best = None
    for _, ws in lines:
        for i in range(len(ws)):
            acc = ''
            for j in range(i, min(len(ws), i + 5)):
                acc += _norm2(ws[j][0])
                if not acc: break
                score = 1.0 if (acc == target or (acc.endswith(target) and len(acc) - len(target) <= 2)) \
                    else difflib.SequenceMatcher(None, acc, target).ratio()
                if score >= 0.85 and (best is None or score > best[0]):
                    x0 = min(w[1] for w in ws[i:j + 1]); y0 = min(w[2] for w in ws[i:j + 1])
                    x1 = max(w[1] + w[3] for w in ws[i:j + 1]); y1 = max(w[2] + w[4] for w in ws[i:j + 1])
                    best = (score, (x0 + x1) / 2, (y0 + y1) / 2, y1 - y0)
                if len(acc) > len(target) + 3: break
    return best[1:] if best else None

def words_equal(lines, word):
    t = _norm(word)
    return [(w[1] + w[3] / 2, w[2] + w[4] / 2, w[4]) for _, ws in lines for w in ws if _norm(w[0]) == t]

THRESH = bytes(0 if v > 150 else 255 for v in range(256))     # bright text -> black, dark background -> white

def name_variants(name):
    """The name as typed, plus without a clan tag: 'FC|Mash', '[FC] Mash', 'FC.Mash' also try 'Mash'.
    The game draws clan tags in a way the screen reader often drops or misreads (FC| came out as 'I')."""
    out = [name]
    m = re.match(r'^\s*[\[\(\{<]?\s*[^\s|\]\)\}>]{1,6}\s*[|\]\)\}>.:]\s*(.+)$', name)
    if m and _norm2(m.group(1)): out.append(m.group(1))
    return out

def name_score(text, name):
    """3 exact, 2 exact after dropping 1-2 junk letters (globe icon, clan tag) or the clan tag, 1 close, 0 no match."""
    t = _norm2(text)
    best = 0
    for v_i, v in enumerate(name_variants(name)):
        n = _norm2(v)
        if not t or not n: continue
        if t == n: best = max(best, 3 if v_i == 0 else 2)
        elif any(t[c:] == n for c in (1, 2, 3)): best = max(best, 2)
        elif len(n) >= 5 and max(difflib.SequenceMatcher(None, t[c:], n).ratio() for c in (0, 1, 2)) >= 0.85:
            best = max(best, 1)
    return best

def invite_buttons(lines, word):
    """Standalone 'Invite' buttons lined up in one column (ignores 'Invite To Party' and 'Steam Invites')."""
    t = _norm(word); out = []
    for _, ws in lines:
        for i, w in enumerate(ws):
            if _norm(w[0]) != t or not w[0].lstrip('-@(')[:1].isupper(): continue   # buttons, not 'invite' in a sentence
            nxt = _norm(ws[i + 1][0]) if i + 1 < len(ws) else ''
            if nxt in ('to', 'toparty'): continue
            out.append((w[1] + w[3] / 2, w[2] + w[4] / 2, w[4]))
    if len(out) < 2: return out
    xs = sorted(o[0] for o in out); mid = xs[len(xs) // 2]
    return [o for o in out if abs(o[0] - mid) < 3 * o[2]]

def wheel(x, y, notches=-3):
    check_stop()
    _move_to(x, y)
    for _ in range(abs(notches)):
        _send_mouse(0x0800, data=120 if notches > 0 else -120); time.sleep(0.06)

class RankedParty(threading.Thread):
    """Main menu > Multiplayer > Ranked > Invite To Party > Invite each friend on your list who is online."""
    def __init__(self, strings, cfg, say, done):
        super().__init__(daemon=True)
        st = lambda k, d: clean(strings.get(str(k), d))
        self.l_mp, self.l_ranked = st(9203, 'Multiplayer'), st(170100, 'Ranked')
        self.l_party, self.l_invite = st('IDS_MATCHMAKING_INVITE_TO_PARTY', 'Invite To Party'), st('INVITE', 'Invite')
        self.l_offline, self.l_online = st(300103, 'Offline'), st(300102, 'Online')
        self.l_status = st(300001, 'Status')
        self.l_cancel = st(4002, 'Cancel')
        self.l_retract = st(300015, 'Retract')      # what the button says once they are invited
        self.l_find, self.l_queue = st(170102, 'Find Match'), st(170101, 'Ranked Queue')
        self.l_steaminv, self.l_ageinv = st(300580, 'Steam Invites'), st('IDS_INVITATION_POPUP_INVITE', 'Age II Invite')
        self.cfg, self.say, self.done = cfg, say, done

    def run(self):
        ok = False
        try: ok = self.work()
        except Stopped:
            log('stopped by user'); self.say('Stopped.')
        except NotInGame:
            log('game not in front, stopped'); self.say("Stopped: the game wasn't the window in front, so I didn't click.")
        except Exception as e:
            log('ranked invite failed: %r' % (e,)); self.say('Invite failed: %s' % e)
        self.done(ok)

    def list_open(self, lines):
        """The Invite To Party window: its own headings, plus a column of Invite buttons."""
        heading = find_phrase(lines, self.l_steaminv) or find_phrase(lines, self.l_ageinv)
        btns = invite_buttons(lines, self.l_invite)
        return bool(heading) and len(btns) >= 1 or len(btns) >= 3

    def close_list(self, read, grab, h):
        """Close the Invite To Party window once the invites are sent: its Cancel button (bottom right),
        or Esc if that can't be read. Cancel only closes the window, the invites already went out."""
        time.sleep(0.4)
        (x, y, k), lines = self.ocr(read, grab, h)
        if not self.list_open(lines): return
        hits = [(w[1] + w[3] / 2, w[2] + w[4] / 2) for _, ws in lines for w in ws if _norm(w[0]) == _norm(self.l_cancel)]
        if hits:
            cx, cy = max(hits, key=lambda p: p[1])         # the lowest one: the window's own Cancel button
            log('close invite list: Cancel at %s' % ((cx, cy),))
            click(x + cx / k, y + cy / k)
        else:
            log('close invite list: Esc')
            if not game_in_front(): raise NotInGame()
            ctypes, wintypes, u, _ = _win()
            u.keybd_event(0x1B, 0, 0, 0); time.sleep(0.05); u.keybd_event(0x1B, 0, 2, 0)
        time.sleep(0.4)

    def statuses(self, lines):
        """(y, 'on'/'off') for each row's status word, top to bottom."""
        on, off = _norm(self.l_online), _norm(self.l_offline)
        rows = [(w[2] + w[4] / 2, 'on' if _norm(w[0]) == on else 'off', w[4], w[1])
                for _, ws in lines for w in ws if _norm(w[0]) in (on, off)]
        return sorted(rows)

    def read_rows(self, read, grab, h, x, y, k, lines, rows):
        """Read each online player's name on its own strip, blown up. The strip runs through to the status word so
        short names like GG sit in a proper line of text, which the reader handles much better. If a strip comes
        back blank it is tried again as black text on white, then bigger."""
        if not rows: return []
        ats = [w for _, ws in lines for w in ws if '@' in w[0][:3]]
        stat_x = min(r[3] for r in rows)
        stat_r = max(r[3] for r in rows) + 7 * max(r[2] for r in rows)
        left = (min(w[1] for w in ats) - 4) if ats else stat_x - 900 * k * client_rect(h)[3] / 1079.0
        on, off = _norm(self.l_online), _norm(self.l_offline)
        out = []
        for ry, st_, rh, _ in rows:
            if st_ == 'off': continue                      # offline players can't be invited, skip reading them
            sx, sy = int(x + left / k), int(y + (ry - rh * 1.1) / k)
            sw, sh = int((stat_r - left) / k), int(rh * 2.2 / k)
            if sw < 20 or sh < 8: continue
            txt = ''
            for scale, thresh in ((3, False), (3, True), (4, True)):
                buf, ow, oh = grab((sx, sy, sw, sh, scale))
                if thresh: buf = buf.translate(THRESH)
                raw = ' '.join(read(buf, ow, oh))
                txt = ' '.join(t for t in raw.split() if _norm(t) not in (on, off)).strip()
                if _norm2(txt): break
            out.append((ry, txt, st_))
        return out

    def button_at(self, lines, col, ny, rh):
        """What the button on this row actually says. Once a friend has been invited the same
        button turns into Retract, and clicking it would cancel their invite."""
        best, gap = '', 1e9
        for _, ws in lines:
            for w in ws:
                cx_, cy_ = w[1] + w[3] / 2, w[2] + w[4] / 2
                if abs(cy_ - ny) > max(rh, w[4]) * 1.1: continue
                d = abs(cx_ - col)
                if d < gap and d < max(w[3], rh * 2) * 2.5:
                    gap, best = d, _norm(w[0])
        return best

    def invite_column(self, lines):
        """x of the Invite buttons column (OCR sometimes misreads a few of them)."""
        btns = invite_buttons(lines, self.l_invite)
        if btns: return sorted(b[0] for b in btns)[len(btns) // 2]
        hd = find_phrase(lines, self.l_ageinv)
        return hd[0] if hd else None

    def ocr(self, read, grab, h):
        if not game_in_front(): raise NotInGame()
        x, y, w, hh = client_rect(h)
        k = 2 if hh < 900 else 1                       # 1:1 is plenty for these screens and much quicker to read
        return (x, y, k), read(*grab((x, y, w, hh, k)), words=True)

    def state(self, lines):
        if self.list_open(lines): return 'list'
        if find_phrase(lines, self.l_find) or find_phrase(lines, self.l_queue): return 'ranked'
        if find_phrase(lines, self.l_ranked): return 'mp'
        if find_phrase(lines, self.l_mp): return 'main'
        return None

    def wait_change(self, read, grab, h, before, timeout=6.0):
        """Re-read the screen every moment until it shows something new (or time runs out)."""
        end = time.time() + timeout
        time.sleep(0.25)
        while True:
            check_stop()
            got = self.ocr(read, grab, h)
            st_ = self.state(got[1])
            if st_ != before and st_ is not None or time.time() > end: return got
            time.sleep(0.1)

    def work(self):
        friends = [f for f in self.cfg.get('friends', []) if f.strip()]
        if not friends: self.say('Add the friends to invite in settings first.'); return False
        read = _load_ocr(); grab = _grabber()
        h = find_game_window()
        if not h: self.say('Start the game first, then press the button.'); return False
        GAME_HWND[0] = h
        if not overlay_is_admin() and window_elevated(h):
            self.say(ADMIN_MSG); log('game is elevated, clicks would be blocked'); return False
        if not focus_window(h):
            self.say("Couldn't bring the game to the front. Click on the game once, then press the button again."); return False
        time.sleep(0.15)
        # 1) get to the Invite To Party window. After each click, watch the screen and move on the moment it changes.
        (x, y, k), lines = self.ocr(read, grab, h)
        unknown = 0
        for step in range(12):
            state = self.state(lines)
            unknown = unknown + 1 if state is None else 0
            if unknown >= 2:
                self.say("Couldn't find the game menus. Go to the main menu (not in a match) and try again."); return False
            log('screen %d (%s): %s' % (step, state, ' | '.join(t for t, _ in lines)[:300]))
            if state == 'list': break
            p = None
            if state == 'ranked':
                p = find_phrase(lines, self.l_party)
                if not p:                                  # button text not read: use its spot relative to the screen layout
                    fm = find_phrase(lines, self.l_find); rq = find_phrase(lines, self.l_queue)
                    s_ = client_rect(h)[3] / 1079.0 * k
                    p = (fm[0] - 657 * s_, fm[1] - 73 * s_) if fm else (rq[0] - 234 * s_, rq[1] + 204 * s_)
                self.say('Opening Invite To Party...')
            elif state == 'mp':
                p = find_phrase(lines, self.l_ranked); self.say('Opening Ranked...')
            elif state == 'main':
                p = find_phrase(lines, self.l_mp); self.say('Opening Multiplayer...')
            if p:
                log('click at %s' % (p,))
                click(x + p[0] / k, y + p[1] / k)
            (x, y, k), lines = self.wait_change(read, grab, h, state)
        else:
            self.say("Couldn't open Invite To Party. Go to the main menu and try again."); return False
        # 2) put online players first (click the Status heading if the list starts with offline players)
        for _ in range(3):
            (x, y, k), lines = self.ocr(read, grab, h)
            if not self.list_open(lines):
                self.say("The Invite To Party list isn't open. Open it and press the button again."); return False
            rows = self.statuses(lines)
            if not rows or rows[0][1] == 'on': break
            sp = find_phrase(lines, self.l_status)
            if not sp: break
            self.say('Sorting online players first...'); log('double-click Status at %s' % (sp,))
            click(x + sp[0] / k, y + sp[1] / k); time.sleep(0.1)       # quick double click = online first
            click(x + sp[0] / k, y + sp[1] / k); time.sleep(0.5)
        # 3) invite each friend who is online: click Invite on the same row as their name
        invited, offline, already, missing = [], [], [], list(friends)
        seen, same = None, 0
        for page in range(25):
            (x, y, k), lines = self.ocr(read, grab, h)
            log('list page %d: %s' % (page, ' | '.join(t for t, _ in lines)[:500]))
            rows = self.statuses(lines)
            col = self.invite_column(lines)
            if col is None: self.say("Couldn't find the Invite buttons."); return False
            row_names = self.read_rows(read, grab, h, x, y, k, lines, rows)
            log('rows: %s' % ' | '.join('%d:%s=%s' % (ry, t, st_) for ry, t, st_ in row_names))
            for name in list(missing):
                p = None
                scored = [(name_score(rt, name), ry) for ry, rt, _ in row_names]   # names read row by row
                best = max(scored, default=(0, 0))
                if best[0]: p = (0, best[1], 0)
                if not p:
                    p = find_name(lines, name)             # fall back to the whole-window read
                if not p: continue
                nx, ny, nh = p
                nh = nh or (rows[0][2] if rows else 30)
                near = [r for r in rows if abs(r[0] - ny) < nh * 1.2]
                status = min(near, key=lambda r: abs(r[0] - ny))[1] if near else 'on'
                missing.remove(name)
                if status == 'off': offline.append(name); continue
                btn = self.button_at(lines, col, ny, nh)
                if btn.startswith('retr') or btn == _norm(self.l_retract):
                    log('%s already invited (button says %r), leaving it' % (name, btn))
                    already.append(name); continue         # clicking it would retract their invite
                self.say('Inviting %s...' % name); log('invite %s at %s (button %r)' % (name, (col, ny), btn))
                click(x + col / k, y + ny / k); time.sleep(0.3)
                invited.append(name)
            # online players come first, so once offline rows show up there is nobody left to find
            if not missing or not rows or any(r[1] == 'off' for r in rows): break
            sig = tuple(t for t, _ in lines if t.startswith('@') or '@' in t[:3])
            same = same + 1 if sig == seen else 0
            seen = sig
            if same >= 2: break
            names_x = min((w[1] for _, ws in lines for w in ws if '@' in w[0][:3]), default=col - 900)
            mid_y = rows[len(rows) // 2][0] if rows else 600 * k
            if same == 1:                                  # the wheel didn't move it: click the scroll bar track
                last_y = rows[-1][0] if rows else mid_y
                click(x + (col + 150 * k * client_rect(h)[3] / 1079.0) / k, y + last_y / k); time.sleep(0.8)
            else:
                wheel(x + (names_x + 150) / k, y + mid_y / k, -5); time.sleep(0.8)
        self.close_list(read, grab, h)
        parts = []
        if invited: parts.append('Invited ' + ', '.join(invited))
        if already: parts.append('already invited: ' + ', '.join(already))
        if offline or missing: parts.append('not online: ' + ', '.join(offline + missing))
        self.say(('; '.join(parts) or 'Nobody to invite') + '.')
        url = self.cfg.get('webhook', '').strip()
        if url and invited:
            who = ' '.join(mention(f) for f in (self.cfg.get('pings') or invited) if f.strip())
            try: post_discord(url, '%s Ranked party invite sent in game, accept it in AoE2.' % who)
            except Exception as e: log('discord failed: %r' % (e,))
        return bool(invited)

def sound_dir():
    d = os.path.join(os.path.dirname(SETTINGS), 'sounds')
    try: os.makedirs(d, exist_ok=True)
    except OSError: pass
    return d

def make_voice(text, path):
    """Record one spoken line to a wav with Windows' own voice, once. Playing a wav later is
    instant; shelling out to the speech engine mid-game would not be."""
    if os.path.isfile(path): return True
    try:
        import subprocess
        ps = ("$v = New-Object -ComObject SAPI.SpVoice; "
              "$f = New-Object -ComObject SAPI.SpFileStream; "
              "$f.Open('%s', 3); $v.AudioOutputStream = $f; $v.Speak('%s'); $f.Close()"
              % (path.replace("'", "''"), text.replace("'", "''")))
        subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', ps],
                       creationflags=0x08000000, timeout=40, capture_output=True)
        return os.path.isfile(path)
    except Exception as e:
        log('could not record "%s": %r' % (text, e))
        return False

def play_voice(path):
    try:
        import winsound
        if path and os.path.isfile(path):
            winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC | winsound.SND_NODEFAULT)
        else:
            winsound.Beep(880, 90); winsound.Beep(1245, 140)      # no voice available, two notes
    except Exception as e:
        log('could not play the alert: %r' % (e,))

class ScoutWatcher(threading.Thread):
    """Says the colour out loud the first time an opponent turns up on your minimap.

    It reads the minimap and nothing else. The minimap only paints ground you have already
    explored, fog stays black on it, so this can never tell you something you are not already
    being shown. It does not read the game's memory and it never clicks or flares for you.
    """
    TOL = 34               # sum of the three channel differences; the minimap colours are extreme
    BLOCK = 24             # a hit has to be a cluster this big, not a stray pixel
    NEED = 6               # pixels inside one block
    SURE = 20              # this many is a building, no second look needed
    CONFIRM = 2            # a smaller one has to still be there on the next look

    def __init__(self, notify):
        super().__init__(daemon=True)
        self.notify = notify               # notify(colour_index, label)
        self.active = False
        self.pause_fn = lambda: False
        self.grab = None
        self.targets = {}                  # colour index -> label, the opponents only
        self.found = set()
        self.near = {}
        self.rect = None
        self.mask = None                   # whatever already matched at the start: static UI bits
        self.colours = {}
        self.t0 = 0
        self.look = 0
        self.lock = threading.Lock()
        self.fail = 0

    def start_game(self, targets, voices=True):
        """targets: {colour index: 'Blue'} for the opponents in this game, nobody else."""
        with self.lock:
            self.targets = dict(targets)
            self.found, self.near, self.mask, self.rect = set(), {}, None, None
            self.colours = minimap_colours()
            self.t0 = time.time()
        if voices and targets:
            def record():
                for name in sorted(set(targets.values())):
                    make_voice('%s found' % name, os.path.join(sound_dir(), '%s.wav' % name.lower()))
            threading.Thread(target=record, daemon=True).start()

    def stop_game(self):
        with self.lock:
            self.targets, self.found, self.near = {}, set(), {}
            self.mask, self.rect = None, None

    def _region(self):
        h = find_game_window()
        if not h: return None
        x, y, w, hh = client_rect(h)
        box = minimap_rect(w, hh)
        if not box: return None
        bx, by, bw, bh = box
        bx, by = max(0, bx), max(0, by)
        bw, bh = min(bw, w - bx), min(bh, hh - by)
        if bw < 40 or bh < 20: return None
        return (x + bx, y + by, bw, bh, 1)

    def run(self):
        if not ensure_numpy():
            log('no numpy, so the opponent spotted alert is off'); return
        import numpy as np
        while True:
            try:
                time.sleep(1.1)
                with self.lock:
                    targets = dict(self.targets)
                    left = [i for i in targets if i not in self.found]
                if not (self.active and left) or self.pause_fn(): continue
                if self.grab is None: self.grab = _grabber()
                if self.rect is None:
                    self.rect = self._region()
                    if self.rect is None: continue
                raw, w, h = self.grab(self.rect)
                a = np.frombuffer(raw, dtype=np.uint8).reshape(h, w, 4)[:, :, :3].astype(np.int16)
                bgr = a                                   # the grab hands back B, G, R
                hits = {}
                for idx in left:
                    col = self.colours.get(idx)
                    if not col: continue
                    want = np.array([col[2], col[1], col[0]], dtype=np.int16)
                    m = (np.abs(bgr - want).sum(axis=2) <= self.TOL)
                    hits[idx] = m
                if self.mask is None:                     # first look: anything already showing is
                    self.mask = {i: m.copy() for i, m in hits.items()}   # part of the UI, not a player
                    continue
                for idx, m in hits.items():
                    base = self.mask.get(idx)
                    if base is not None and base.shape == m.shape: m = m & ~base
                    big = self._cluster(np, m)
                    if big < self.NEED:
                        self.near[idx] = 0
                        continue
                    self.near[idx] = self.near.get(idx, 0) + 1
                    # a solid blob is a building or a group and is called straight away; a couple of
                    # pixels has to still be there next time round, so a stray dot cannot set it off
                    if big >= self.SURE or self.near[idx] >= self.CONFIRM:
                        with self.lock: self.found.add(idx)
                        self.notify(idx, targets.get(idx, ''))
                self.fail = 0
                self.look += 1
                if self.look % 40 == 0: self.rect = None     # in case the window has moved
            except Exception as e:
                self.fail += 1
                if self.fail < 4: log('minimap watch: %r' % (e,))
                self.rect = None
                time.sleep(2)

    def _cluster(self, np, m):
        """The biggest bunch of matching pixels anywhere in the picture. One stray pixel off a
        compression artefact scores 1; a scout scores a handful; a building scores plenty."""
        total = int(m.sum())
        if total < self.NEED: return total
        best, b = 0, self.BLOCK
        for y in range(0, m.shape[0] - 1, b):
            row = m[y:y + b]
            if int(row.sum()) <= best: continue
            for x in range(0, m.shape[1] - 1, b):
                best = max(best, int(row[:, x:x + b].sum()))
        return best

def icon_names(seg, icons):
    out = []
    for m in re.finditer(r'<MATERIAL=UnitIcons(\d{3})50730,1>(\s*\([^)]*\))?', seg):
        nm = icons.get(int(m.group(1)))
        if nm: out.append(nm + ((' ' + m.group(2).strip().lower()) if m.group(2) else ''))
    return out


# ---------------------------------------------------------------- the game's own artwork
# AoE2 keeps its civ crests and unit icons as plain PNGs in the install, so the panels can
# show the real thing instead of something drawn by hand. Nothing is copied or installed.
ART_CACHE = {}
EMBLEM_ALIAS = {'hindustanis': 'indians', 'malays': 'malay'}

def art_dir(*parts):
    if not INST[0]: return None
    return os.path.join(INST[0], 'resources', '_common', 'wpfg', 'resources', *parts)

def emblem_path(civ_name_):
    d = art_dir('civ_emblems')
    if not d: return None
    slug = re.sub(r'[^a-z]', '', (civ_name_ or '').lower())
    for name in (EMBLEM_ALIAS.get(slug, slug), slug):
        f = os.path.join(d, name + '.png')
        if os.path.isfile(f): return f
    return None

def unit_icon_path(unit_name, icons):
    """The unique unit's own icon, found through the picture index the tech tree gives it."""
    d = art_dir('uniticons')
    if not d or not unit_name: return None
    want = re.sub(r'[^a-z]', '', unit_name.lower())
    for pi, nm in icons.items():
        if re.sub(r'[^a-z]', '', str(nm).lower()) == want:
            f = os.path.join(d, '%03d_50730.png' % pi)
            if os.path.isfile(f): return f
    return None

def load_art(path, width, tint=None):
    """A PhotoImage scaled to roughly `width` across, kept in a cache because Tk throws away
    an image nothing holds a reference to. The civ crests are black silhouettes meant for the
    game's parchment, so `tint` repaints the shape in a light colour over a dark plate."""
    import tkinter as tk
    key = (path, width, tint)
    if key in ART_CACHE: return ART_CACHE[key]
    img = None
    try:
        from PIL import Image, ImageTk
        im = Image.open(path).convert('RGBA')
        box = im.split()[3].getbbox()                 # trim the empty margin around the crest
        if box: im = im.crop(box)
        h = max(1, int(im.height * width / float(im.width)))
        im = im.resize((width, h), Image.LANCZOS)
        if tint:
            shape = Image.new('RGBA', im.size, tint)
            shape.putalpha(im.split()[3])
            im = Image.alpha_composite(Image.new('RGBA', im.size, PANEL), shape)
        img = ImageTk.PhotoImage(im)
    except Exception:
        if tint: return None                          # without Pillow a black crest on a dark
        try:                                          # panel is worse than the drawn one
            raw = tk.PhotoImage(file=path)
            n = max(1, int(round(raw.width() / float(width))))
            img = raw.subsample(n, n) if n > 1 else raw
            ART_CACHE[(path, 'raw')] = raw            # the parent image has to stay alive too
        except Exception as e:
            log('could not load %s: %r' % (os.path.basename(path or '?'), e))
    ART_CACHE[key] = img
    return img

def ensure_pillow():
    """The crests are silhouettes, so they need recolouring to show on a dark panel, and that
    needs Pillow. Install it quietly the first time if this PC does not have it."""
    try:
        import PIL  # noqa: F401
        return True
    except ImportError:
        pass
    try:
        import subprocess, importlib, site
        exe = sys.executable
        if exe.lower().endswith('pythonw.exe'): exe = exe[:-11] + 'python.exe'
        log('installing Pillow so the civ crests can be shown')
        subprocess.run([exe, '-m', 'pip', 'install', '--user', '--disable-pip-version-check', '-q', 'Pillow'],
                       creationflags=0x08000000, timeout=300, capture_output=True)
        usp = site.getusersitepackages()
        if usp not in sys.path: sys.path.append(usp)
        importlib.invalidate_caches()
        import PIL  # noqa: F401
        return True
    except Exception as e:
        log('no Pillow, falling back to drawn crests: %r' % (e,))
        return False

PLAYER_COLOURS = ['#3f6fd8', '#c4402f', '#3e9b39', '#d6c131',    # blue red green yellow
                  '#2fb3c4', '#9142b5', '#9b9b93', '#e07f22']   # cyan purple grey orange
PLAYER_NAMES = ['Blue', 'Red', 'Green', 'Yellow', 'Cyan', 'Purple', 'Grey', 'Orange']

def player_colour(idx):
    """The colour this player actually has in the game, or None when it is not known."""
    try: return PLAYER_COLOURS[int(idx) % 8], PLAYER_NAMES[int(idx) % 8]
    except Exception: return None, None

def lighten(hex_colour, amount=0.42):
    """Mix a colour towards white. The player colours are picked to read on grass, not on a
    dark panel, so names drawn in them need lifting before they are easy to read."""
    try:
        r, g, b = (int(hex_colour[i:i + 2], 16) for i in (1, 3, 5))
        mix = lambda c: int(round(c + (255 - c) * amount))
        return '#%02x%02x%02x' % (mix(r), mix(g), mix(b))
    except Exception:
        return hex_colour

def name_colour(idx, fallback):
    """The tone to write a player's name in: their own colour, lifted so it reads."""
    hexc, _ = player_colour(idx)
    return lighten(hexc) if hexc else fallback

def short_record(games):
    w_ = sum(1 for g in games if g.get('result') == 'win')
    l_ = sum(1 for g in games if g.get('result') == 'loss')
    if w_ + l_ == 0: return ''
    return '%d-%d (%d%%)' % (w_, l_, round(100 * w_ / (w_ + l_)))

def record_vs(opp_civ):
    """How you have gone against this civ."""
    try:
        g_ = [g for g in load_stats()['games'] if g.get('opp') == opp_civ]
        w_ = sum(1 for g in g_ if g.get('result') == 'win')
        l_ = sum(1 for g in g_ if g.get('result') == 'loss')
        if w_ + l_ == 0: return ''
        return 'Against %s: %d won, %d lost' % (opp_civ, w_, l_)
    except Exception:
        return ''

def record_on_map(map_name):
    """How you have gone on this map."""
    try:
        g_ = [g for g in load_stats()['games'] if g.get('map') == map_name]
        w_ = sum(1 for g in g_ if g.get('result') == 'win')
        l_ = sum(1 for g in g_ if g.get('result') == 'loss')
        if w_ + l_ == 0: return ''
        return 'On %s: %d won, %d lost' % (map_name, w_, l_)
    except Exception:
        return ''

def civ_parts(blurb):
    """Split a civ's description into its pieces: what it is, bonuses, unique unit, techs, team bonus."""
    b = (blurb or '').replace('<b>', '').split('\\n')
    out = dict(kind='', bonuses=[], uu='', uu_class='', techs=[], team='')
    where = 'top'
    for raw in b:
        ln = clean(raw).strip()
        if not ln: continue
        low = ln.lower()
        if low.startswith('unique unit'): where = 'uu'; continue
        if low.startswith('unique tech'): where = 'tech'; continue
        if low.startswith('team bonus'): where = 'team'; continue
        if where == 'top':
            if ln.startswith('\u2022'): out['bonuses'].append(ln.lstrip('\u2022 ').strip())
            elif not out['kind']: out['kind'] = ln
            elif out['bonuses']: out['bonuses'][-1] += ' ' + ln          # a bonus that wrapped
        elif where == 'uu' and not out['uu']:
            m = re.match(r'(.*?)\s*\((.*?)\)\s*$', ln)
            out['uu'], out['uu_class'] = (m.group(1), m.group(2)) if m else (ln, '')
        elif where == 'tech':
            if ln.startswith('\u2022'): out['techs'].append(ln.lstrip('\u2022 ').strip())
        elif where == 'team' and not out['team']:
            out['team'] = ln
    return out

def unique_units(blurb):
    m = re.search(r'Unique Units?:\s*(?:<b>)?\s*(?:\\n)+\s*(.*?)(?:\\n\\n|$)', blurb)
    if not m: return []
    return [re.sub(r'\s*\(.*?\)\s*$', '', u).strip(' •') for u in m.group(1).split('\\n') if u.strip(' •')]

def uu_info(name, strings, icons):
    key = next((k for k, v in strings.items() if k.startswith('26') and v.startswith('Create <b>%s<b>' % name)), None)
    if not key: return None
    v = strings[key]
    strong = re.search(r'<GREEN>Strong vs (.*?)<DEFAULT>', v)
    counter = re.search(r'<AQUA>Countered by:(.*?)<DEFAULT>', v)
    situ = re.search(r'<ORANGE>Situationally countered by:(.*?)<DEFAULT>', v)
    lines = []
    if strong: lines.append('Strong vs ' + clean(strong.group(1)))
    if counter:
        c = icon_names(counter.group(1), icons)
        if c: lines.append('Counter with: ' + ', '.join(c))
    if situ:
        c = icon_names(situ.group(1), icons)
        if c: lines.append('Sometimes: ' + ', '.join(c))
    return lines

def civ_text(civ, strings, icons):
    name = STOCK.get(str(10270 + civ)) or strings.get(str(10270 + civ), 'Civ %d' % civ)
    from_openings = OPENINGS.get(name)
    blurb = strings.get(str(120149 + civ), '')
    lines = []
    if blurb:
        first = clean(blurb.split('\\n')[0])
        lines.append(first)
    lines.append('Openings: ' + (from_openings or 'no notes yet, check their bonuses below.'))
    if blurb and not from_openings:
        bullets = [clean(b) for b in blurb.split('\\n') if b.strip().startswith('•')][:3]
        lines += bullets
    for uu in unique_units(blurb):
        info = uu_info(uu, strings, icons)
        lines.append('Unique unit: ' + uu)
        if info: lines += ['   ' + x for x in info]
    return name, '\n'.join(lines)


# ---------------------------------------------------------------- your opponent's own openings
# How this player has actually opened in their recent games, rather than what their civ usually does.
# The ladder service lists their recent matches, and the official site hands out the recorded game
# for each one (the same download the in-game match history offers). The recording's command list
# shows what they built and trained early on. All of it is public, and all of it is about games
# that are already over. Nothing here looks at the game you are playing.
REPLAY_URL = 'https://aoe.ms/replay/?gameId=%d&profileId=%d'
OPEN_FILE = os.path.join(os.path.dirname(SETTINGS), 'openings.json')
OPEN_LOCK = threading.Lock()
OPEN_MEM = {'games': None, 'players': {}}
OPEN_GAMES = 8                          # how many of their recent games to read
FEUDAL_MS, CASTLE_MS = 130000, 160000   # how long the age-ups take to research
FEUDAL_ARMY = {4: 'Archers', 7: 'Skirmishers', 448: 'Scouts', 751: 'Eagles', 1755: 'Camel Scouts',
               93: 'Spearmen', 539: 'Galleys', 1103: 'Galleys', 1795: 'Galleys'}
CASTLE_ARMY = {38: 'Knights', 4: 'Crossbows', 24: 'Crossbows', 125: 'Monks', 280: 'Mangonels', 329: 'Camels',
               39: 'Cavalry Archers', 751: 'Eagles', 753: 'Eagles', 1370: 'Steppe Lancers',
               1132: 'Battle Elephants', 448: 'Light Cavalry', 546: 'Light Cavalry', 1258: 'Rams'}

def replay_commands(raw):
    """(ms, player number, kind, id, amount) for each build, train and research command in a
    recorded game. Only the command list is walked; the game state in the header is not needed."""
    n = len(raw)
    p = struct.unpack_from('<I', raw, 0)[0]
    if struct.unpack_from('<I', raw, p)[0] != 500: p += 4
    p += 24
    a, b, _ = struct.unpack_from('<III', raw, p); p += 12
    if a != 0: p -= 12
    if b == 2: p -= 8
    ms = 0
    try:
        while p + 4 <= n:
            op = struct.unpack_from('<I', raw, p)[0]; p += 4
            if op == 1:                                           # a command
                ln = struct.unpack_from('<I', raw, p)[0]; p += 4
                act = raw[p]; d = raw[p + 1:p + ln]; p += ln + 4
                if act == 255: break                              # the end-of-game block
                if len(d) < 3: continue
                pl, dl = struct.unpack_from('<bh', d)
                if len(d) != dl + 3: continue
                d = d[3:]
                try:
                    if act == 102: yield ms, pl, 'build', struct.unpack_from('<h2xffI', d)[3], 1
                    elif act == 129:
                        _s, _b, uid, amt = struct.unpack_from('<h4xhhh', d)
                        yield ms, pl, 'queue', uid, max(1, amt)
                    elif act == 101: yield ms, pl, 'tech', struct.unpack_from('<Ihh', d)[2], 1
                except struct.error:
                    pass
            elif op == 2:                                         # the clock
                inc, marker = struct.unpack_from('<II', raw, p); p += 4
                ms += inc
                if marker == 0:
                    if struct.unpack_from('<I', raw, p + 16)[0]:
                        p += 356; ms = struct.unpack_from('<I', raw, p)[0]; p += 4
                    else:
                        p += 28
            elif op == 3: p += 12                                 # where the camera was
            elif op == 4: p += 8 + struct.unpack_from('<I', raw, p + 4)[0]     # chat
            else: break
    except (struct.error, IndexError):
        pass
    yield ms, 0, 'end', 0, 0

def classify_opening(ev, end_ms):
    """One player's commands [(ms, kind, id, amount)] -> {'o': 'Men-at-arms > Archers', 'f': feudal
    time in seconds, 'c': castle time}, or None when the game was too short to tell."""
    techs = {}
    for ms, kind, i, amt in ev:
        if kind == 'tech': techs.setdefault(i, ms)
    f_click, c_click = techs.get(101), techs.get(102)
    if f_click is None:
        if c_click is None and not any(k == 'queue' and i in FEUDAL_ARMY for _, k, i, _ in ev): return None
        start = 0                                                 # Empire Wars: the game starts in Feudal
    else:
        start = f_click + FEUDAL_MS
    cut = min(c_click if c_click is not None else 1e12, start + 7 * 60000)   # the opening, not the whole game
    if end_ms < start + 150000 and c_click is None: return None  # over before anyone showed their hand
    army, first, militia, militia_t, dark, towers = collections.Counter(), {}, 0, None, 0, []
    for ms, kind, i, amt in ev:
        if ms > cut: break
        if kind == 'queue':
            if i == 74:
                militia += amt
                if militia_t is None: militia_t = ms
                if ms < start: dark += amt
            elif i in FEUDAL_ARMY:
                army[FEUDAL_ARMY[i]] += amt; first.setdefault(FEUDAL_ARMY[i], ms)
        elif kind == 'build' and i == 79:
            towers.append(ms)
    parts = []
    maa = 222 in techs and techs[222] <= cut + 60000
    if militia >= 2 and maa: parts.append((militia_t, 'Men-at-arms'))
    elif dark >= 2: parts.append((militia_t, 'Drush'))
    main = sorted(((n, k) for k, n in army.items() if k != 'Spearmen' and n >= 3), reverse=True)[:2]
    parts += [(first[k], k) for _, k in main]
    if len(towers) >= 3: parts.append((towers[2], 'Towers'))
    if c_click is not None and c_click <= start + 7 * 60000 and sum(n for n, _ in main) < 4 and len(towers) < 3:
        cast = c_click + CASTLE_MS
        nxt, tcs = collections.Counter(), 0
        for ms, kind, i, amt in ev:
            if cast - 20000 <= ms <= cast + 240000:
                if kind == 'queue' and i in CASTLE_ARMY: nxt[CASTLE_ARMY[i]] += amt
                elif kind == 'build' and i in (109, 621): tcs += 1
        top = nxt.most_common(1)
        follow = (' into ' + top[0][0]) if top and top[0][1] >= 2 else ' into a boom' if tcs >= 2 else ''
        parts.append((c_click, 'Fast Castle' + follow))
    if not parts and army.get('Spearmen', 0) >= 4: parts.append((first['Spearmen'], 'Spearmen'))
    label = ' > '.join(lab for _, lab in sorted(parts)) or 'No early army'
    return {'o': label, 'f': int(start / 1000) if f_click is not None else 0,
            'c': int((c_click + CASTLE_MS) / 1000) if c_click is not None else 0}

def replay_openings(raw):
    """{profile id: {'o': opening, 'f': .., 'c': .., 'civ': civ id}} for every human in a recorded game."""
    lob = read_lobby(None, raw)
    if not lob: return {}
    by, end = collections.defaultdict(list), 0
    for ms, pl, kind, i, amt in replay_commands(raw):
        if kind == 'end': end = ms
        else: by[pl].append((ms, kind, i, amt))
    out = {}
    for p in lob['players']:
        if not p['human'] or not p.get('number'): continue
        o = classify_opening(by.get(p['number'], []), end)
        if o: o['civ'] = p['civ']; out[str(p['profile'])] = o
    return out

def _open_games():
    if OPEN_MEM['games'] is None:
        try: OPEN_MEM['games'] = json.load(open(OPEN_FILE, encoding='utf-8'))
        except Exception: OPEN_MEM['games'] = {}
    return OPEN_MEM['games']

def match_openings(mid, holders):
    """Everyone's opening in one finished game. Read once, then kept on disk: a finished game never changes."""
    key = str(mid)
    with OPEN_LOCK:
        got = _open_games().get(key)
    if got is not None: return got
    import urllib.request, zipfile
    raw = None
    for pid in holders[:2]:
        try:
            req = urllib.request.Request(REPLAY_URL % (int(mid), int(pid)), headers={'User-Agent': 'AoE2Wingman/1.0'})
            with urllib.request.urlopen(req, timeout=20) as r:
                blob = r.read(40_000_000)
            z = zipfile.ZipFile(io.BytesIO(blob))
            info = z.infolist()[0]
            if info.file_size > 120_000_000: raise ValueError('recording too large')
            raw = z.read(info); break
        except Exception as e:
            log('recorded game %s not available: %r' % (mid, e))
    if raw is None: return None                               # not kept, so it is tried again another day
    try:
        res = replay_openings(raw)
    except Exception as e:
        log('could not read recorded game %s: %r' % (mid, e)); res = {}
    with OPEN_LOCK:
        g = _open_games(); g[key] = res
        for k in sorted(g, key=lambda x: int(x) if x.isdigit() else 0)[:-800]: g.pop(k, None)
        try:
            os.makedirs(os.path.dirname(OPEN_FILE), exist_ok=True)
            with open(OPEN_FILE, 'w', encoding='utf-8') as f: json.dump(g, f)
        except OSError as e:
            log('could not save openings: %r' % (e,))
    return res

def opponent_openings(profile, mode='1v1', n=OPEN_GAMES):
    """This player's last few games, newest first: [{'o': opening, 'f', 'c', 'civ', 'result', 'start'}].
    Games of the same kind as the one you are in (1v1 or team) when they have played enough of them."""
    if not profile: return []
    key = (int(profile), mode)
    with OPEN_LOCK:
        busy = OPEN_MEM.setdefault('busy', {}).setdefault(key, threading.Lock())
    with busy:                                   # the loading panel and the overlay both ask: read once
        return _opponent_openings(profile, mode, n, key)

def _opponent_openings(profile, mode, n, key):
    if key in OPEN_MEM['players']: return OPEN_MEM['players'][key]
    games = sorted((m for m in relic_matches(profile) if m.get('replays')), key=lambda m: -m['start'])
    if not games: return []
    same = [m for m in games if m['mode'] == mode]
    pick = (same if len(same) >= 3 else games)[:n]
    def one(m):
        holders = sorted(m['replays'], key=lambda pid: pid != int(profile))    # their own copy first
        o = (match_openings(m['match'], holders) or {}).get(str(int(profile)))
        return dict(o, result=m['result'], start=m['start']) if o else None
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=4) as ex:
        rows = [r for r in ex.map(one, pick) if r]
    OPEN_MEM['players'][key] = rows
    log('openings for %s: %s' % (profile, ', '.join(r['o'] for r in rows) or 'none readable'))
    return rows

def openings_lines(rows, civ=None, strings=None):
    """Two short lines: what they open with most, then when they hit Feudal and how those games went."""
    if not rows: return []
    tally = collections.Counter(r['o'] for r in rows)
    top = [('%s ×%d' % (k, v)) if v > 1 else k for k, v in tally.most_common(4)]
    out = ['Last %d game%s:  %s' % (len(rows), '' if len(rows) == 1 else 's', '  ·  '.join(top))]
    bits = []
    fs = sorted(r['f'] for r in rows if r.get('f'))
    if fs:
        mid = fs[len(fs) // 2]
        bits.append('Feudal around %d:%02d' % (mid // 60, mid % 60))
    won = sum(1 for r in rows if r.get('result') == 'win')
    bits.append('won %d, lost %d' % (won, len(rows) - won))
    if civ is not None and strings is not None:
        mine = collections.Counter(r['o'] for r in rows if r.get('civ') == civ)
        if mine:
            bits.append('as %s: %s' % (civ_name(civ, strings), ', '.join(k for k, _ in mine.most_common(2))))
    out.append('  ·  '.join(bits))
    return out

# ---------------------------------------------------------------- ratings (public, from the game's own ladder service)
ELO_CACHE = {}
ELO_URL = 'https://aoe-api.worldsedgelink.com/community/leaderboard/GetPersonalStat?title=age2&'

def fetch_elo(profile=None, name=None, fresh=False):
    """A player's ladder ratings: {'1v1': .., 'tg': .., 'ew': ..}. Looked up by profile id, or by name if that's
    all we have. These are the same public ratings shown on the in-game leaderboard."""
    key = profile or ('name:' + (name or '').lower())
    if key in ELO_CACHE and not fresh: return ELO_CACHE[key]   # fresh=True for before/after a game
    import urllib.request, urllib.parse
    q = 'profile_ids=[%d]' % profile if profile else 'aliases=' + urllib.parse.quote(json.dumps([name]))
    res = {}
    try:
        req = urllib.request.Request(ELO_URL + q, headers={'User-Agent': 'AoE2Wingman/1.0'})
        with urllib.request.urlopen(req, timeout=6) as r:
            data = json.loads(r.read().decode('utf-8'))
        stats = {s.get('leaderboard_id'): s.get('rating') for s in data.get('leaderboardStats', [])}
        res = {'1v1': stats.get(3), 'tg': stats.get(4), 'ew': stats.get(13)}
    except Exception as e:
        log('rating lookup failed for %s: %r' % (key, e))
    ELO_CACHE[key] = res
    return res

def elo_text(e, team_game):
    """'1v1 1524 · TG 1402', with the ladder for this kind of game first."""
    if not e: return ''
    order = (('TG', 'tg'), ('1v1', '1v1')) if team_game else (('1v1', '1v1'), ('TG', 'tg'))
    parts = ['%s %d' % (lab, e[k]) for lab, k in order if e.get(k)]
    return '  ·  '.join(parts)

# ---------------------------------------------------------------- loading screen: your civ and your opponent's
def _civ_bonuses(blurb, n=4):
    head = re.split(r'Unique (?:Units?|Techs?)', blurb)[0]           # civ bonuses only, not the unique techs
    bullets = []
    for ln in head.split('\\n'):                                     # a bonus can wrap onto the next line
        ln = clean(ln)
        if ln.startswith('\u2022'): bullets.append(ln.lstrip('\u2022 ').strip())
        elif bullets and ln and not ln.endswith(':'): bullets[-1] += ' ' + ln
    return bullets[:n]

def civ_name(civ, strings):
    return STOCK.get(str(10270 + civ)) or strings.get(str(10270 + civ), 'Civ %d' % civ)

def my_civ_sections(civ, strings, icons=None):
    """Your civ, kept short: how it opens, its best bonuses, its unique unit and techs.
    Returns (name, sections, extras) where extras holds the one-liner and the team bonus."""
    name = civ_name(civ, strings)
    parts = civ_parts(strings.get(str(120149 + civ), ''))
    out = []
    if OPENINGS.get(name): out.append(('Common openings', [OPENINGS[name]]))
    if parts['bonuses']: out.append(('Bonuses', parts['bonuses'][:3]))
    if parts['techs']: out.append(('Unique techs', parts['techs']))
    return name, out, dict(kind=parts['kind'],
                           team=('Team bonus: ' + parts['team']) if parts['team'] else '')

def opp_sections(civ, strings, icons):
    """Your opponent's civ, with how they will open first, since that is what you act on."""
    name = civ_name(civ, strings)
    parts = civ_parts(strings.get(str(120149 + civ), ''))
    out = []
    if OPENINGS.get(name): out.append(('Likely openings', [OPENINGS[name]]))
    if parts['bonuses']: out.append(('Watch for', parts['bonuses'][:4]))
    if parts['uu']:
        lines = []
        for ln in uu_info(parts['uu'], strings, icons) or []:
            if ln.startswith('Strong'): continue                 # what matters here is how to stop it
            lines.append(ln.replace('Counter with: ', 'Beat it with: ').replace('Sometimes: ', 'Also works: '))
        out.append(('Unique unit: ' + parts['uu'], lines or ['No counter notes.'],
                    unit_icon_path(parts['uu'], icons)))
    if parts['techs']: out.append(('Unique techs', parts['techs']))
    return name, out, dict(kind=parts['kind'], team='')

def civ_labels(strings):
    """Every way a civ name can appear on the loading screen (stock and UUH's 'Malian - Inf' style) -> civ id."""
    out = {}
    for cid in range(1, 120):
        for src in (strings, STOCK):
            v = src.get(str(10270 + cid))
            if v and _norm2(v): out[_norm2(v)] = cid
    return out

def read_loading_players(lines, labels, mine):
    """Players and civs from the loading screen text: a name line with its civ line just under it."""
    rows = []
    for text, ws in lines:
        if not ws: continue
        rows.append((_norm2(text), text, ws[0][1], sum(w[2] for w in ws) / len(ws), max(w[4] for w in ws)))
    civs = []
    for n, text, x0, yc, hgt in rows:
        if len(n) < 4: continue
        best = max(((difflib.SequenceMatcher(None, n, lab).ratio(), cid) for lab, cid in labels.items()), default=(0, 0))
        if best[0] >= 0.8: civs.append((x0, yc, hgt, best[1]))
    players = []
    for x0, yc, hgt, cid in civs:
        above = [r for r in rows if 0 < yc - r[3] < hgt * 3 and abs(r[2] - x0) < hgt * 6 and _norm2(r[1]) not in labels]
        if not above: continue
        nm = max(above, key=lambda r: r[3])
        teams = [r for r in rows if r[3] < nm[3] and ('team' in r[0]) and abs(r[2] - x0) < hgt * 12]
        team = max(teams, key=lambda r: r[3])[0] if teams else ''
        me_ = any(name_score(nm[1], m) >= 2 for m in mine)
        players.append(dict(name=nm[1].strip(), civ=cid, team=team, me=me_))
    return players

class LoadWatcher(threading.Thread):
    """Spots the game's loading screen (it shows 'Game Mode:' top right) and hands over its layout and text."""
    def __init__(self, strings, show, hide, ended=None, in_game=None):
        super().__init__(daemon=True)
        self.gm = _norm(clean(strings.get('200018', 'Game Mode:')))
        self.show, self.hide = show, hide
        self.ended, self.in_game = ended, in_game or (lambda: False)
        self.needs_text = lambda: True
        self.started = lambda: True        # a game this PC has actually begun recording
        # the end-of-game statistics screen has these tabs; Victory!/Defeat! banners too
        self.end_tabs = {_norm(clean(strings.get(str(i), d))) for i, d in
                         ((9939, 'Military'), (9940, 'Economy'), (9941, 'Technology'), (9942, 'Society'), (9943, 'Timeline'))}
        self.win_word = _norm(clean(strings.get('1150', 'Victory!')))
        self.loss_word = _norm(clean(strings.get('1151', 'Defeat!')))
        self.end_first = 0
        self.last_end_check = 0
        # lobby screens can show the same map line; these words only appear there, never on the loading screen
        self.lobby_phrases = {_norm(clean(strings.get(str(i), d))) for i, d in
                              ((9472, 'Start Game'), (170301, 'Leave Lobby'), (13578, 'Lobby Settings'),
                               (170300, 'Return to Main Menu'), (13577, 'Randomize'), (200025, 'Game Settings'),
                               (170102, 'Find Match'))} - {''}
        self.ready_word = _norm(clean(strings.get('1200', 'Ready')))
        self.lobby_until, self.prefull = 0, None
        self.pause, self.showing, self.misses = False, False, 0

    def is_lobby(self, full):
        joined_n = _norm(' '.join(t for t, _ in full))
        words = {_norm(wd[0]) for _, ws in full for wd in ws}
        return any(p in joined_n for p in self.lobby_phrases) or self.ready_word in words

    def end_screen(self, read, grab, x, y, w, hh):
        """True on the end-of-game screen. Who won is not read here: that comes from the match
        history, which cannot be misread."""
        lines = read(*grab((x, y, w, hh, 1)))
        words = {_norm(t) for t in ' '.join(lines).split()}
        banner = any(_norm(t) in (self.win_word, self.loss_word) for t in lines)
        return len(self.end_tabs & words) >= 3 or banner

    def run(self):
        try:
            read = _load_ocr(); grab = _grabber()
        except Exception as e:
            log('loading screen watch off: %r' % (e,)); return
        ctypes, wintypes, u, _ = _win()
        while True:
            time.sleep(0.18 if self.showing else 0.35)         # quick off the mark, quicker to clear
            if self.pause: continue
            try:
                fg = u.GetForegroundWindow()
                pid = wintypes.DWORD(); u.GetWindowThreadProcessId(fg, ctypes.byref(pid))
                if not fg or not _proc_name(pid.value).startswith('aoe2de'):
                    if self.showing: self.showing = False; self.hide()
                    time.sleep(1.5); continue
                h = fg
                x, y, w, hh = client_rect(h)
                if w < 400 or hh < 300: continue
                lines = read(*grab((x + int(w * 0.62), y + int(hh * 0.33), int(w * 0.37), int(hh * 0.2), 1)))
                joined = ' '.join(lines)
                # the loading screen's settings panel: 'Game Mode:' (fancy font, often unread) or 'Tiny (2 player) [120]'
                loading = self.gm in _norm(joined) or bool(re.search(r'\(\s*\d+\s*pl', joined, re.I))
                if loading and not self.showing:
                    # Lobby and setup screens show the same 'Tiny (2 player)' line, so before showing anything read
                    # the whole screen once: the loading screen has none of the lobby's buttons. This is done every
                    # time (a replay from the last few minutes doesn't prove a new game is loading).
                    if time.time() < self.lobby_until:
                        loading = False
                    else:
                        full = read(*grab((x, y, w, hh, 1)), words=True)
                        if self.is_lobby(full):
                            self.lobby_until = time.time() + 2.5; loading = False
                            log('lobby screen, not the loading screen')
                        else:
                            self.prefull = full
                seen = ' | '.join(lines)[:120]
                if seen != getattr(self, 'last_seen', None) and time.time() - getattr(self, 'last_log', 0) > 5:
                    self.last_seen, self.last_log = seen, time.time()
                    log('loading watch (%dx%d): %s' % (w, hh, seen or '-'))
                if loading and not self.showing:
                    ratio = u.GetSystemMetrics(0)
                    self.showing, self.misses = True, 0
                    # put the panels up straight away off the replay the game has just written,
                    # then read the whole screen only if that did not give us the players
                    self.show((x, y, w, hh), ratio, None)
                    if self.needs_text():
                        full = self.prefull or read(*grab((x, y, w, hh, 1)), words=True)
                        self.prefull = None
                        log('loading screen: %s' % ' | '.join(t for t, _ in full)[:400])
                        if self.showing: self.show((x, y, w, hh), ratio, full)
                    self.prefull = None
                elif not loading and self.showing:
                    self.misses += 1
                    if self.misses >= 2:                       # two quick misses in a row: the game is up
                        self.showing = False; self.hide(); log('loading screen gone')
                elif loading:
                    self.misses = 0
                # a game is on: every few seconds look for the end-of-game screen, and reset when it shows
                if not loading and self.ended and self.in_game() and time.time() - self.last_end_check > 3:
                    self.last_end_check = time.time()
                    if self.end_screen(read, grab, x, y, w, hh):
                        log('end of game screen seen'); self.ended()
            except Exception as e:
                log('loading screen watch: %r' % (e,)); time.sleep(3)


# ---------------------------------------------------------------- look and feel
# One place for the colours and type, so the overlay, the civ boxes and the
# settings window all read as the same app.
INK    = '#17130c'   # dark stone, the panel background
PANEL  = '#241d13'   # the raised plates: chips, fields, pills
EDGE   = '#3a2f1f'   # hairline between sections
RIM    = '#6d5222'   # dark bronze, the metal edge
BRONZE = '#a9823c'   # bronze trim and corner pieces
BORDER = '#4a3a20'   # the card's inner border
SHADOW = '#0a0805'   # the ring around the card
GOLDC  = '#d8b253'   # headings and the primary button
GOLDD  = '#f0d796'   # gold, hover
TXT    = '#e9dcc0'   # parchment
MUT    = '#a2937a'
FAINT  = '#7c6f5c'
GREEN  = '#88b060'
REDC   = '#c0503a'

# AoE2's panels use a warm serif. pick_fonts() swaps in whichever one this PC actually has.
DISPLAY = 'Georgia'
F_TITLE = (DISPLAY, 12, 'bold')
F_HEADLINE = (DISPLAY, 16, 'bold')
F_HEAD  = (DISPLAY, 10, 'bold')
F_BODY  = ('Segoe UI', 10)
F_SMALL = ('Segoe UI', 8)
F_TINY  = ('Segoe UI', 7)

def pick_fonts():
    """Called once Tk is up, when the font list can be read."""
    global DISPLAY, F_TITLE, F_HEADLINE, F_HEAD
    try:
        import tkinter.font as tkfont
        have = set(f.lower() for f in tkfont.families())
        for fam in ('Georgia', 'Palatino Linotype', 'Book Antiqua', 'Constantia',
                    'Times New Roman', 'DejaVu Serif', 'Liberation Serif'):
            if fam.lower() in have:
                DISPLAY = fam; break
    except Exception:
        pass
    F_TITLE = (DISPLAY, 12, 'bold')
    F_HEADLINE = (DISPLAY, 16, 'bold')
    F_HEAD = (DISPLAY, 10, 'bold')

def hover(widget, normal, hot, key='fg'):
    """Light up on mouse over. Used for the gear, the close cross and headings."""
    widget.bind('<Enter>', lambda e: widget.config(**{key: hot}), add='+')
    widget.bind('<Leave>', lambda e: widget.config(**{key: normal}), add='+')

def rule(parent, colour=EDGE, pad=(6, 6)):
    """A hairline separator."""
    import tkinter as tk
    f = tk.Frame(parent, bg=colour, height=1)
    f.pack_propagate(False)
    return f

def style_entry(widget):
    """Dark field with a gold focus ring, instead of the default white box."""
    widget.configure(bg=PANEL, fg=TXT, insertbackground=GOLDC, relief='flat',
                     highlightthickness=1, highlightbackground=EDGE, highlightcolor=GOLDC,
                     font=F_BODY)

def icon_button(parent, glyph, bg, hot=GOLDD, size=11):
    """A header icon with a hit area and a hover background, instead of a bare glyph."""
    import tkinter as tk
    b = tk.Label(parent, text=glyph, fg=MUT, bg=bg, font=('Segoe UI', size), cursor='hand2', padx=6, pady=2)
    b.bind('<Enter>', lambda e: b.config(bg=PANEL, fg=hot), add='+')
    b.bind('<Leave>', lambda e: b.config(bg=bg, fg=MUT), add='+')
    return b

def flat_button(parent, text, command, accent=GOLDC, fill=False, hot=None):
    """A flat button that matches the overlay: gold fill for the primary action,
    outline for the rest. Built from a Label so it styles the same on every box."""
    import tkinter as tk
    hot = hot or GOLDD
    b = tk.Label(parent, text=text, font=F_HEAD, cursor='hand2', padx=14, pady=5)
    if fill:
        b.configure(bg=accent, fg=INK)
        b.bind('<Enter>', lambda e: b.config(bg=GOLDD))
        b.bind('<Leave>', lambda e: b.config(bg=accent))
    else:
        b.configure(bg=PANEL, fg=accent, highlightthickness=1,
                    highlightbackground=EDGE, highlightcolor=EDGE)
        b.bind('<Enter>', lambda e: b.config(fg=hot, highlightbackground=RIM))
        b.bind('<Leave>', lambda e: b.config(fg=accent, highlightbackground=EDGE))
    b.bind('<Button-1>', lambda e: command())
    return b



# ---------------------------------------------------------------- small drawn icons
# Simple vector marks, drawn on a canvas so they need no files and scale with the box.
def draw_icon(c, kind, s, col):
    """Draw `kind` on canvas `c`, inside an s by s square, in colour `col`."""
    m = s / 16.0
    def L(*pts, **kw): c.create_line(*[p * m for p in pts], fill=col, width=kw.get('w', 1.6), capstyle='round')
    def P(*pts, **kw): c.create_polygon(*[p * m for p in pts], fill=kw.get('fill', ''), outline=col, width=1.5)
    def O(x1, y1, x2, y2, **kw): c.create_oval(x1 * m, y1 * m, x2 * m, y2 * m, outline=col,
                                               fill=kw.get('fill', ''), width=1.5)
    if kind == 'shield':                      # bonuses, defence
        P(8, 1, 14, 4, 14, 9, 8, 15, 2, 9, 2, 4)
        L(8, 4, 8, 12)
    elif kind == 'sword':                     # unique unit
        L(4, 13, 12, 4, w=2); L(2, 15, 5, 12); L(9, 3, 13, 2); L(12, 2, 13, 6)
    elif kind == 'swords':                    # how to beat it
        L(3, 13, 12, 3, w=1.8); L(13, 13, 4, 3, w=1.8); L(2, 14, 4, 12); L(12, 12, 14, 14)
    elif kind == 'clock':                     # openings, timings
        O(2, 2, 14, 14); L(8, 5, 8, 8, w=1.4); L(8, 8, 11, 10, w=1.4)
    elif kind == 'banner':                    # plays as
        L(4, 2, 4, 15, w=1.6); P(4, 2, 13, 4, 13, 9, 4, 11)
    elif kind == 'eye':                       # watch out for
        P(1, 8, 8, 3, 15, 8, 8, 13); O(6, 6, 10, 10)
    elif kind == 'horse':                     # cavalry
        P(3, 14, 5, 7, 9, 4, 9, 2, 12, 4, 13, 8, 11, 14)
    elif kind == 'bow':                       # archers
        c.create_arc(3 * m, 2 * m, 13 * m, 14 * m, start=250, extent=220, style='arc', outline=col, width=1.6)
        L(5, 3, 5, 13, w=1.2); L(5, 8, 14, 8, w=1.4)
    elif kind == 'crown':                     # your record
        P(2, 12, 2, 5, 5, 8, 8, 3, 11, 8, 14, 5, 14, 12)
    elif kind == 'castle':
        P(3, 14, 3, 6, 5, 6, 5, 4, 7, 4, 7, 6, 9, 6, 9, 4, 11, 4, 11, 6, 13, 6, 13, 14)
    else:                                     # a plain diamond
        P(8, 2, 14, 8, 8, 14, 2, 8)

def icon_for(head):
    """Pick a mark from the wording of a section heading."""
    h = head.lower()
    for key, kind in (('bonus', 'shield'), ('opening', 'clock'), ('beat', 'swords'), ('counter', 'swords'),
                      ('watch', 'eye'), ('unique', 'sword'), ('plays as', 'banner'), ('record', 'crown'),
                      ('cavalry', 'horse'), ('archer', 'bow'), ('castle', 'castle')):
        if key in h: return kind
    return 'diamond'

# ---------------------------------------------------------------- window
def main():
    import tkinter as tk
    maps, strings, icons = load_data()
    me = my_profile()
    root = tk.Tk()
    pick_fonts()
    root.overrideredirect(True); root.attributes('-topmost', True)
    try: root.attributes('-alpha', 0.88)
    except tk.TclError: pass
    BG, FG, GOLD, RED = INK, TXT, GOLDC, REDC
    root.configure(bg=RIM)                          # a bronze edge around the panel, like the game's frames
    frame = tk.Frame(root, bg=BG, padx=16, pady=13, highlightthickness=1, highlightbackground=BORDER)
    frame.pack(fill='both', expand=True, padx=2, pady=2)
    frame.columnconfigure(0, weight=1)

    class Rule(tk.Canvas):
        """A bronze divider with a diamond in the middle, the way the game rules off a panel."""
        def __init__(self, parent):
            tk.Canvas.__init__(self, parent, height=9, width=1, bg=BG, highlightthickness=0, bd=0)
            self.bind('<Configure>', self.draw)
        def draw(self, _=None):
            self.delete('all')
            w = self.winfo_width(); m = w // 2; y = 4
            self.create_line(0, y, m - 10, y, fill=EDGE)
            self.create_line(m + 10, y, w, y, fill=EDGE)
            self.create_polygon(m, y - 4, m + 5, y, m, y + 4, m - 5, y, fill=RIM, outline=BRONZE)

    # header: accent stripe, the map name as the headline, state pill, then the window controls
    head = tk.Frame(frame, bg=BG)
    head.grid(row=0, column=0, columnspan=4, sticky='we')
    head.columnconfigure(1, weight=1)
    title = tk.Label(head, text=APP_NAME, fg=GOLDC, bg=BG, font=F_HEADLINE, anchor='w', cursor='hand2')
    title.grid(row=0, column=1, sticky='w', padx=(2, 0))
    state = tk.Label(head, text='WAITING', fg=MUT, bg=PANEL, font=F_TINY, padx=7, pady=3,
                     highlightthickness=1, highlightbackground=RIM)
    state.grid(row=0, column=2, sticky='e', padx=(10, 2))
    stats_btn = icon_button(head, 'W/L', BG, size=8)
    stats_btn.configure(font=(DISPLAY, 8, 'bold'))
    stats_btn.grid(row=0, column=3, sticky='e', padx=(6, 0))
    gear = icon_button(head, '\u2699', BG)
    gear.grid(row=0, column=4, sticky='e', padx=(4, 0))
    close = icon_button(head, '\u2715', BG, hot=REDC)
    close.grid(row=0, column=5, sticky='e')
    sep = Rule(frame)
    sep.grid(row=1, column=0, columnspan=4, sticky='we', pady=(8, 8))

    # the map's facts, laid out as chips rather than one run-on line
    class Facts(object):
        """Stands in for the old body label: same .config(text=...) in, a tidy chip strip out."""
        WIDTH = 430

        def __init__(self, parent):
            self.frame = tk.Frame(parent, bg=BG)
            self.text = ''
            self.binds = []

        # the bits the rest of main() uses it as a widget for
        def grid(self, **kw): self.frame.grid(**kw)
        def grid_remove(self): self.frame.grid_remove()
        def winfo_manager(self): return self.frame.winfo_manager()
        def cget(self, key): return self.text
        def bind(self, seq, fn, add=None):
            self.binds.append((seq, fn)); self.frame.bind(seq, fn, add=add)

        def config(self, text=None, **kw):
            if text is None or text == self.text: return
            self.text = text; self.render()

        def _chip(self, row, label):
            c = tk.Frame(row, bg=PANEL, highlightthickness=1, highlightbackground=RIM)
            tk.Label(c, text=label, fg=TXT, bg=PANEL, font=F_SMALL, padx=8, pady=3).pack()
            c.pack(side='left', padx=(0, 6), pady=(0, 6))
            return c

        def _note(self, parent, label, colour):
            n = tk.Label(parent, text=label, fg=colour, bg=BG, font=F_SMALL, anchor='w',
                         justify='left', wraplength=self.WIDTH)
            n.pack(fill='x', pady=(0, 4))
            return n

        def render(self):
            for w in self.frame.winfo_children(): w.destroy()
            made = []
            lines = [l for l in self.text.split('\n') if l.strip()]
            for li, line in enumerate(lines):
                if li and line.startswith('('):                       # the herd-tracking status notes
                    made.append(self._note(self.frame, line.strip('()'), FAINT)); continue
                parts = [p.strip() for p in line.split('\u00b7') if p.strip()]
                chips, prose = [], []
                for part in parts:
                    bits = [b.strip() for b in part.split(',') if b.strip()]
                    if len(bits) > 1 and all(len(b) <= 26 and any(ch.isdigit() for ch in b) for b in bits):
                        chips.extend(bits)                            # '8 Sheep, 4 Boar, 2 Deer'
                    elif len(part) <= 26 and any(ch.isdigit() for ch in part):
                        chips.append(part)                            # 'Relics 5'
                    else:
                        prose.append(part)                            # the map's own description
                if prose:
                    made.append(self._note(self.frame, '  \u00b7  '.join(prose), '#bdb7a6'))
                row, used = None, 0
                for ch in chips:
                    w = 9 + 7 * len(ch)                               # near enough for wrapping
                    if row is None or used + w > self.WIDTH:
                        row = tk.Frame(self.frame, bg=BG); row.pack(fill='x'); used = 0
                        made.append(row)
                    made.append(self._chip(row, ch)); used += w
            for w in made + [c for m in made for c in m.winfo_children()]:
                for seq, fn in self.binds: w.bind(seq, fn, add='+')

    body = Facts(frame)
    body.grid(row=2, column=0, columnspan=4, sticky='we')
    # holds the card to one width in a game, so it does not jump about as the facts change.
    # Out of a game there is nothing to hold, so the pin comes off and the card shrinks to
    # its header, which is all there is to show while you are waiting.
    pin = tk.Frame(frame, bg=BG, width=0, height=0)
    pin.grid(row=8, column=0, columnspan=4)

    waiting_now = [True]                 # st does not exist yet when this first runs

    def idle_size(waiting):
        waiting_now[0] = waiting
        pin.config(width=0 if waiting else 400)
        if waiting:                                   # pull everything in: there is nothing to show
            body.config(text=''); body.grid_remove()
            sep.grid_remove(); footsep.grid_remove()   # no dividers, nothing to divide
            frame.configure(padx=12, pady=9)
            host_row.grid_configure(pady=(6, 0))       # button tucked under the header
        else:
            body.grid()
            if not st.get('rolled'):
                sep.grid()
                if st.get('footer', True): footsep.grid()
            frame.configure(padx=16, pady=13)
            host_row.grid_configure(pady=(10, 0))
    rec_line = tk.Label(frame, text='', fg=MUT, bg=BG, font=F_SMALL, anchor='w')
    rec_line.grid(row=3, column=0, columnspan=4, sticky='w', pady=(8, 0)); rec_line.grid_remove()

    # the card that goes up once the service confirms how the last game went
    card = tk.Frame(frame, bg=PANEL, highlightthickness=1, highlightbackground=RIM, padx=10, pady=7)
    card.grid(row=3, column=0, columnspan=4, sticky='we', pady=(8, 0)); card.grid_remove()
    card.columnconfigure(1, weight=1)
    card_word = tk.Label(card, text='', fg=GREEN, bg=PANEL, font=(DISPLAY, 11, 'bold'), anchor='w')
    card_word.grid(row=0, column=0, sticky='w')
    card_elo = tk.Label(card, text='', fg=MUT, bg=PANEL, font=F_SMALL, anchor='e')
    card_elo.grid(row=0, column=1, sticky='e')
    card_line = tk.Label(card, text='', fg=TXT, bg=PANEL, font=F_SMALL, anchor='w', justify='left')
    card_line.grid(row=1, column=0, columnspan=2, sticky='w', pady=(3, 0))
    # the score line: how your side's total compares, and the flag when the game looks gone
    score_line = tk.Label(frame, text='', fg=MUT, bg=BG, font=F_SMALL, anchor='w', pady=2)
    score_line.grid(row=4, column=0, columnspan=4, sticky='we', pady=(8, 0)); score_line.grid_remove()
    opp_area = tk.Frame(frame, bg=BG)
    opp_area.grid(row=5, column=0, columnspan=4, sticky='we')

    # footer: the one action, with the hint that only appears while the mouse is over the overlay
    footsep = Rule(frame)
    footsep.grid(row=6, column=0, columnspan=4, sticky='we', pady=(9, 0))
    host_row = tk.Frame(frame, bg=BG)
    host_row.grid(row=7, column=0, columnspan=4, sticky='we', pady=(10, 0))
    host_row.columnconfigure(1, weight=1)
    btn_plate = tk.Frame(host_row, bg=RIM, padx=1, pady=1)       # dark edge around the bronze face
    host_btn = tk.Label(btn_plate, text='Ranked party invite', fg='#2a2113', bg=GOLD, font=F_HEAD,
                        padx=14, pady=5, cursor='hand2')
    host_btn.pack()
    host_btn.bind('<Enter>', lambda e: host_btn.cget('bg') == GOLD and host_btn.config(bg=GOLDD), add='+')
    host_btn.bind('<Leave>', lambda e: host_btn.cget('bg') == GOLDD and host_btn.config(bg=GOLD), add='+')
    btn_plate.grid(row=0, column=0, sticky='w')
    hint = tk.Label(host_row, text='drag to move  \u00b7  click the name to roll up  \u00b7  W/L for your record', fg=FAINT, bg=BG,
                    font=F_TINY, anchor='e')
    hint.grid(row=0, column=1, sticky='e', padx=(12, 2)); hint.grid_remove()
    host_msg = tk.Label(host_row, text='', fg='#b8b19f', bg=BG, font=F_SMALL, anchor='w',
                        justify='left', wraplength=430)
    host_msg.grid(row=1, column=0, columnspan=2, sticky='w', pady=(7, 0))
    idle_size(True)                 # the app opens with no game on, so start small
    try:
        if god_mode_status()[0] != 'on':
            host_msg.config(text='God Mode mod is %s. The idle Town Center alert needs it: '
                                 'click the cog to install it.' % ('not installed' if god_mode_status()[0] == 'missing'
                                                                   else 'switched off'))
    except Exception as e:
        log('god mode check: %r' % (e,))
    cfg0 = load_settings()
    pos = cfg0.get('pos')
    try:                                   # go back to where it was left, if that spot is still on a screen
        px, py = int(pos[0]), int(pos[1])
        if not (-60 <= px <= root.winfo_screenwidth() - 80 and -20 <= py <= root.winfo_screenheight() - 40):
            raise ValueError
    except Exception:
        px, py = 20, 120
    root.geometry('+%d+%d' % (px, py))
    st = {'drag': None, 'last': None, 'actions': {}, 'shift': False,
          'first': None, 'herd': None, 'extra': 0}
    root.update_idletasks()
    try:                                  # keep the overlay out of its own screen reads (Windows 10 2004+)
        import ctypes
        u32 = ctypes.windll.user32
        u32.GetAncestor.restype = ctypes.c_void_p
        u32.GetWindowLongW.argtypes = [ctypes.c_void_p, ctypes.c_int]
        u32.SetWindowLongW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_long]
        top = u32.GetAncestor(root.winfo_id(), 2)
        u32.SetWindowDisplayAffinity(ctypes.c_void_p(top), 0x11)
        OVERLAY_TOP[0] = top
        # Clicking the overlay must not pull Windows' focus off the game: the game mutes itself
        # the moment it stops being the window in front. NOACTIVATE means a click lands on the
        # overlay without activating it, TOOLWINDOW keeps it out of alt-tab and the taskbar.
        ex = u32.GetWindowLongW(ctypes.c_void_p(top), -20)
        u32.SetWindowLongW(ctypes.c_void_p(top), -20, ex | 0x08000000 | 0x00000080)
        ctypes.windll.dwmapi.DwmSetWindowAttribute(                 # rounded corners on Windows 11
            ctypes.c_void_p(top), 33, ctypes.byref(ctypes.c_int(2)), 4)
    except Exception as e:
        log('window setup: %r' % (e,))
    try:
        with open(LOG, 'w', encoding='utf-8') as f: f.write('%s %s started\n' % (APP_NAME, VERSION))
    except OSError: pass
    watcher = HerdWatcher(strings); watcher.start()

    # ---- idle Town Center alert: a silent red badge under the Global Queue
    tc = {'win': None, 'label': None, 'state': 'off', 'on': True, 'snooze': False, 'beep': 0, 'flash': 0}

    def tc_window():
        if tc['win'] is not None: return tc['win']
        w_ = tk.Toplevel(root); w_.overrideredirect(True); w_.attributes('-topmost', True)
        try: w_.attributes('-alpha', 0.96)        # makes it a layered window, which click-through needs
        except tk.TclError: pass
        w_.configure(bg='#ffd27a')
        # one strip each, each in its own colour, so you know which it is without reading it:
        # red for the idle Town Center, blue for the house, gold for a timed reminder
        lab = tk.Label(w_, text='TC IDLE', fg='white', bg=TC_RED[0], font=(DISPLAY, 15, 'bold'),
                       padx=14, pady=4)
        house = tk.Label(w_, text='BUILD A HOUSE', fg='white', bg=TC_BLUE[0], font=(DISPLAY, 15, 'bold'),
                         padx=14, pady=4)
        note = tk.Label(w_, text='', fg='#1d1606', bg=TC_GOLD[0], font=(DISPLAY, 13, 'bold'),
                        padx=14, pady=4)
        tc['house'], tc['note'] = house, note
        sub = tk.Label(w_, text='click to mute for this game', fg='#ffe9c2', bg='#b3261e', font=F_TINY)
        # (the 'click to mute' line is kept but not shown; clicking the badge still mutes it)
        # the badge sits over the map, so clicks go straight through it to the game (no muting by accident)
        w_.update_idletasks()
        try:
            import ctypes
            u32 = ctypes.windll.user32
            top_ = u32.GetAncestor(w_.winfo_id(), 2)
            u32.SetWindowDisplayAffinity(ctypes.c_void_p(top_), 0x11)        # never in our own screen reads
            ex = u32.GetWindowLongW(ctypes.c_void_p(top_), -20)
            # no focus, no taskbar, and click-through (layered + transparent) so it never eats a click
            u32.SetWindowLongW(ctypes.c_void_p(top_), -20, ex | 0x08000000 | 0x00000080 | 0x00080000 | 0x00000020)
        except Exception as e:
            log('tc badge setup: %r' % (e,))
        w_.withdraw()
        tc['win'], tc['label'], tc['sub'] = w_, lab, sub
        return w_

    def tc_draw():
        w_ = tc_window()
        st_ = tc['state']
        alerts = tc['on'] and not tc['snooze']
        want = [(tc['label'], alerts and 'idle' in st_), (tc['house'], alerts and 'house' in st_),
                (tc['note'], time.time() < tc.get('note_until', 0))]
        if not any(on for _, on in want):
            w_.withdraw(); return
        if [on for _, on in want] != tc.get('shown'):
            tc['shown'] = [on for _, on in want]
            for lb, _ in want: lb.pack_forget()
            for lb, on in want:
                if on: lb.pack(fill='x', padx=2, pady=2)
        where = tc.get('where')
        if where:
            qx, qy, phys_w = where
            sc = root.winfo_screenwidth() / float(phys_w or root.winfo_screenwidth())
            w_.geometry('+%d+%d' % (int(qx * sc), int(qy * sc)))
        else:                                       # no queue position yet: top middle of the screen
            w_.update_idletasks()
            w_.geometry('+%d+%d' % ((root.winfo_screenwidth() - w_.winfo_reqwidth()) // 2, 150))
        w_.deiconify(); w_.lift()

    def tc_pulse():
        """Flash whatever is up (silently), each strip between its own two shades."""
        if tc['win'] is not None and tc['win'].winfo_viewable():
            tc['flash'] ^= 1
            tc['label'].config(bg=TC_RED[tc['flash']]); tc['sub'].config(bg=TC_RED[tc['flash']])
            tc['house'].config(bg=TC_BLUE[tc['flash']])
            tc['note'].config(bg=TC_GOLD[tc['flash']])
        if tc.get('note_until') and time.time() >= tc['note_until']:
            tc['note_until'] = 0; tc_draw()         # the reminder has had its few seconds
        root.after(450, tc_pulse)

    def tc_note(text, seconds=8):
        """A timed reminder on the same badge: up for a few seconds, then gone."""
        tc_window()
        tc['note'].config(text=text); tc['note_until'] = time.time() + seconds
        tc_draw()

    def castle_reminder():
        """At 15 game minutes, one quick nudge to check the two buildings Castle Age needs.
        Not if you are already in Castle Age, and only once a game."""
        if st.get('last') is None or st.get('castle_note') or not tcw.active: return
        mins = tcw.game_minutes(time.time())
        if mins < CASTLE_NOTE_MIN: return
        st['castle_note'] = True
        if mins >= CASTLE_NOTE_MIN + 1 or tcw.age >= 3: return               # opened part way through, or already up
        if not load_settings().get('castle_note', True): return
        log('%d minute reminder shown' % CASTLE_NOTE_MIN)
        tc_note('%d:00  ·  2 BUILDINGS FOR CASTLE AGE?' % CASTLE_NOTE_MIN)

    # ---- the game has started: get it in front of you, or say so loudly if Windows will not allow that
    start_box = {'win': None, 'until': 0, 'flash': 0}

    def start_alert():
        """Windows would not hand the game the foreground, so put up a banner and make a noise instead.
        Clicking it switches to the game (a click is what Windows wants before it allows that)."""
        if start_box['win'] is None:
            w_ = tk.Toplevel(root); w_.overrideredirect(True); w_.attributes('-topmost', True)
            w_.configure(bg='#ffd27a')
            lab = tk.Label(w_, text='YOUR GAME HAS STARTED', fg='white', bg=TC_RED[0],
                           font=(DISPLAY, 26, 'bold'), padx=34, pady=14, cursor='hand2')
            lab.pack(padx=3, pady=(3, 0), fill='x')
            sub = tk.Label(w_, text='click here to switch to Age of Empires II', fg='#1d1606', bg=TC_GOLD[0],
                           font=F_HEAD, pady=5, cursor='hand2')
            sub.pack(padx=3, pady=(0, 3), fill='x')
            def go(_=None):
                start_box['until'] = 0; w_.withdraw()
                h = find_game_window()
                if h: threading.Thread(target=lambda: focus_window(h), daemon=True).start()
            for x_ in (w_, lab, sub): x_.bind('<Button-1>', go)
            start_box['win'], start_box['label'] = w_, lab
        w_ = start_box['win']
        w_.update_idletasks()
        w_.geometry('+%d+%d' % ((root.winfo_screenwidth() - w_.winfo_reqwidth()) // 2, root.winfo_screenheight() // 5))
        start_box['until'] = time.time() + 45
        w_.deiconify(); w_.lift()
        try:
            import winsound
            winsound.PlaySound('SystemExclamation', winsound.SND_ALIAS | winsound.SND_ASYNC)
        except Exception: pass
        start_pulse()

    def start_pulse():
        w_ = start_box['win']
        if w_ is None or not start_box['until']: return
        ctypes_, _wt, u_, _k = _win()
        h = find_game_window()
        if time.time() > start_box['until'] or (h and u_.GetForegroundWindow() == h):
            start_box['until'] = 0; w_.withdraw(); return        # you are in the game now
        start_box['flash'] ^= 1
        start_box['label'].config(bg=TC_RED[start_box['flash']])
        w_.lift()
        root.after(450, start_pulse)

    def game_started(f):
        """Called when a new match's recording turns up, which is the moment loading finishes."""
        if not load_settings().get('focus_game', True): return
        try:
            if time.time() - os.path.getctime(f) > 40: return   # the overlay was opened part way through a game
        except OSError:
            return
        def work():
            try:
                size0 = os.path.getsize(f)
                for _ in range(60):                             # the recording grows once the game clock runs
                    if os.path.getsize(f) > size0: break
                    time.sleep(0.25)
                ctypes_, _wt, u_, _k = _win()
                h = find_game_window()
                if not h or (u_.GetForegroundWindow() == h and not u_.IsIconic(h)): return   # already looking at it
                log('the game started while another window was in front: switching to it')
                if focus_window(h): return
                root.after(0, start_alert)
            except Exception as e:
                log('game start switch: %r' % (e,))
        threading.Thread(target=work, daemon=True).start()

    def tc_notify(state, where):
        def go():
            tc['state'] = state
            if where:
                import ctypes
                tc['where'] = (where[0], where[1], ctypes.windll.user32.GetSystemMetrics(0))
            tc_draw()
        root.after(0, go)

    def tc_settings():
        c = load_settings()
        tc['on'] = c.get('tc_alert', True)
        tcw.enabled = tc['on']
    tcw = TCWatcher(strings, tc_notify)
    tcw.enabled = True
    tc_settings()
    tcw.start(); tc_pulse()
    watcher.on_lines = tcw.message_lines

    # ---- score check: your side's total against theirs, and a flag once the game looks gone
    def score_notify(mine_, theirs, behind, flag):
        def go():
            if mine_ is None or st.get('last') is None:
                score_line.config(text=''); score_line.grid_remove(); return
            pct = int(round(abs(behind) * 100))
            nums = '{:,} against {:,}'.format(mine_, theirs)
            if flag:
                score_line.config(text='  CONCEDE AVAILABLE   \u00b7   %d%% behind   \u00b7   %s  ' % (pct, nums),
                                  fg='white', bg='#b3261e', font=(DISPLAY, 9, 'bold'))
            else:
                where = 'level' if pct == 0 else '%d%% %s' % (pct, 'behind' if behind > 0 else 'ahead')
                score_line.config(text='Score   %s   \u00b7   %s' % (nums, where), bg=BG, font=F_SMALL,
                                  fg=REDC if behind > CONCEDE_BEHIND else MUT)
            if not st.get('rolled'): score_line.grid()
        try: root.after(0, go)
        except Exception: pass
    scorew = ScoreWatcher(score_notify, lambda: tcw.game_minutes(time.time()))
    scorew.enabled = load_settings().get('concede_flag', True)
    scorew.start()

    def score_off():
        scorew.active = False
        score_line.config(text=''); score_line.grid_remove()

    def scout_found(idx, label):
        """An opponent's colour has turned up on your own minimap for the first time."""
        def go():
            civ = (st.get('opp_civ') or {}).get(idx, '')
            rec_line.config(text='\u25b8 %s found%s' % (label, ('   \u00b7   ' + civ) if civ else ''),
                            fg=name_colour(idx, GOLDC))
            rec_line.grid()
            def clear():
                if '%s found' % label in rec_line.cget('text'):
                    rec_line.config(text=''); rec_line.grid_remove()
            root.after(25000, clear)
        try: root.after(0, go)
        except Exception: pass
        play_voice(os.path.join(sound_dir(), '%s.wav' % (label or '').lower()))

    scout = ScoutWatcher(scout_found)
    scout.start()

    def start_scout(players, mine_p, strings_):
        """Watch for the opponents in this game, and nobody else. Allies and your own colour
        are never looked for, so your own units can never set it off."""
        st['opp_civ'] = {}
        targets = {}
        if load_settings().get('scout_alert', True) and mine_p is not None:
            for pp in players:
                if pp is mine_p: continue
                if mine_p.get('team', 0) > 1 and pp.get('team') == mine_p.get('team'): continue
                idx = pp.get('colour')
                if idx is None or not (0 <= idx < len(PLAYER_NAMES)): continue
                targets[idx] = PLAYER_NAMES[idx]
                try: st['opp_civ'][idx] = civ_name(pp['civ'], strings_)
                except Exception: pass
        scout.start_game(targets)
        scout.active = bool(targets)

    def first_scan():
        try:
            ensure_pillow()
            repair_results()
            backfill(maps, strings, me)
            fill_results(me)
        except Exception as e:
            log('first scan: %r' % (e,))
    threading.Thread(target=first_scan, daemon=True).start()
    mine = my_names(me)
    labels = civ_labels(strings)
    boxes = []

    def hide_boxes():
        for b_ in boxes:
            try: b_.destroy()
            except tk.TclError: pass
        boxes.clear()

    def crest(parent, letter, colour, size=38):
        """A small shield with the civ's initial, in that player's colour."""
        c = tk.Canvas(parent, width=size, height=size, bg=INK, highlightthickness=0, bd=0)
        m = size / 16.0
        c.create_polygon(8 * m, 0.5 * m, 14.5 * m, 3.5 * m, 14.5 * m, 9 * m, 8 * m, 15.5 * m,
                         1.5 * m, 9 * m, 1.5 * m, 3.5 * m, fill=PANEL, outline=colour, width=2)
        c.create_text(size / 2, size / 2 - size * 0.03, text=(letter or '?')[:1].upper(),
                      fill=colour, font=(DISPLAY, max(9, int(size * 0.42)), 'bold'))
        return c

    def make_box(geo, colour, name, sections, tag='', meta='', letter=None, emblem=None,
                 footer='', edge=None, edge_name=''):
        """A framed panel: crest and name across the top, then each section with its own mark."""
        bx, by, bw, bh = geo
        BOXBG = INK
        win = tk.Toplevel(root); win.overrideredirect(True); win.attributes('-topmost', True)
        try: win.attributes('-alpha', 0.94)
        except tk.TclError: pass
        win.configure(bg=edge or colour)               # their real player colour, when we know it
        shell = tk.Frame(win, bg=BORDER)
        shell.pack(fill='both', expand=True, padx=2, pady=2)
        inner = tk.Frame(shell, bg=BOXBG, padx=18, pady=13)
        inner.pack(fill='both', expand=True, padx=1, pady=1)

        marks_extra = []
        band = tk.Frame(inner, bg=PANEL)               # the header sits on a band of its own
        band.pack(fill='x', pady=(0, 2))
        hd = tk.Frame(band, bg=PANEL, padx=10, pady=8); hd.pack(fill='x')
        art = load_art(emblem, 52, tint=TXT) if emblem else None
        if art is not None:                            # the civ's own crest out of the game files
            plate = tk.Frame(hd, bg=BOXBG, highlightthickness=1, highlightbackground=edge or colour)
            lab = tk.Label(plate, image=art, bg=BOXBG, bd=0)
            lab.image = art
            lab.pack(padx=5, pady=4)
            plate.pack(side='left', padx=(0, 14))
            marks_extra.append(lab)
        else:
            crest(hd, letter if letter is not None else name, colour).pack(side='left', padx=(0, 12))
        who = tk.Frame(hd, bg=PANEL); who.pack(side='left', fill='x', expand=True)
        top = tk.Frame(who, bg=PANEL); top.pack(fill='x', anchor='w')
        tk.Label(top, text=name, fg=colour, bg=PANEL, font=(DISPLAY, 17, 'bold'), anchor='w').pack(side='left')
        if tag:
            tk.Label(top, text=tag, fg=BOXBG, bg=colour, font=F_TINY, padx=7,
                     pady=2).pack(side='left', padx=(10, 0))
        if edge:                                       # which colour you will be on the minimap
            dot = tk.Frame(top, bg=edge, width=9, height=9, highlightthickness=1,
                           highlightbackground=BOXBG)
            dot.pack(side='left', padx=(10, 4), pady=(2, 0))
            tk.Label(top, text=edge_name or '', fg=MUT, bg=PANEL, font=F_TINY).pack(side='left')
        for ln in ([meta] if isinstance(meta, str) else list(meta)):
            fg_ = MUT
            if isinstance(ln, (tuple, list)):          # ('their name', their colour)
                ln, fg_ = ln[0], ln[1] or MUT
            if ln:
                tk.Label(who, text=ln, fg=fg_, bg=PANEL, font=F_SMALL, anchor='w',
                         justify='left').pack(fill='x', anchor='w', pady=(3, 0))
        r_ = Rule(inner); r_.configure(bg=BOXBG); r_.pack(fill='x', pady=(6, 0))

        txt = tk.Text(inner, bg=BOXBG, fg=TXT, bd=0, highlightthickness=0, wrap='word', cursor='arrow',
                      font=('Segoe UI', 10), padx=0, pady=0, spacing3=2)
        txt.tag_configure('h', font=(DISPLAY, 10, 'bold'), foreground=colour, spacing1=11, spacing3=4)
        txt.tag_configure('p', lmargin1=26, lmargin2=26, spacing1=1)
        txt.tag_configure('b', lmargin1=26, lmargin2=38, spacing1=3)
        txt.tag_configure('d', foreground=BRONZE)                    # the bullet mark
        txt.tag_configure('key', foreground=GOLDC, font=('Segoe UI Semibold', 10))
        txt.tag_configure('n', foreground=GOLDC)                     # numbers, so they stand out
        txt.tag_configure('sub', font=(DISPLAY, 12, 'bold'), foreground=GOLDD, spacing1=13, spacing3=3)
        txt.tag_configure('big', font=('Segoe UI Semibold', 13), foreground=GOLDD,
                          lmargin1=26, lmargin2=26, spacing1=4, spacing3=5)

        marks = []
        imgs = []
        def put(line, tag_):
            """Insert a line, lighting up anything numeric."""
            for part in re.split(r'(\d[\d,./+%x-]*\s?%?)', line):
                if not part: continue
                txt.insert('end', part, (tag_, 'n') if part[0].isdigit() else tag_)

        first = True
        for sec in sections:
            head, body = sec[0], sec[1]
            art_path = sec[2] if len(sec) > 2 else None
            own = sec[3] if len(sec) > 3 else None       # that player's own colour, when we know it
            if head.startswith('#'):                     # a player's name when there are several opponents
                tag_ = 'sub'
                if own:
                    tag_ = 'sub' + own
                    txt.tag_configure(tag_, font=(DISPLAY, 12, 'bold'), foreground=own,
                                      spacing1=13, spacing3=3)
                txt.insert('end', ('' if first else '\n') + head[1:] + '\n', tag_); first = True; continue
            if not first: txt.insert('end', '\n')
            pic = load_art(art_path, 22) if art_path else None
            if pic is not None:                          # the unit's own icon from the game files
                lb = tk.Label(txt, image=pic, bg=BOXBG, bd=0)
                lb.image = pic; imgs.append(lb)
                txt.window_create('end', window=lb, padx=0, pady=0, align='center')
            else:
                ic = tk.Canvas(txt, width=15, height=15, bg=BOXBG, highlightthickness=0, bd=0)
                draw_icon(ic, icon_for(head), 15, colour)
                txt.window_create('end', window=ic, padx=0, pady=0, align='center')
                marks.append(ic)
            txt.insert('end', '  ' + head.upper() + '\n', 'h')
            first = False
            bullet = len(body) > 1
            big = 'opening' in head.lower()
            for i_, ln in enumerate(body):
                body_tag = ('big' if big else 'b') if bullet or big else 'p'
                if big: bullet = False
                if bullet: txt.insert('end', '\u2022  ', ('b', 'd'))
                lead = re.match(r'^(Beat it with|Also works|Counter with|Sometimes)\s*:\s*', ln)
                if lead:                                  # the part worth acting on, in gold
                    txt.insert('end', lead.group(1) + '  ', (body_tag, 'key'))
                    ln = ln[lead.end():]
                put(ln, body_tag)
                if i_ < len(body) - 1: txt.insert('end', '\n')
        txt.configure(state='disabled')
        # footer first so it is pinned to the bottom, then the text takes what is left
        foot = tk.Frame(inner, bg=BOXBG); foot.pack(side='bottom', fill='x')
        tk.Label(foot, text='click anywhere to close', fg=FAINT, bg=BOXBG,
                 font=F_TINY, anchor='w').pack(side='left')
        if footer:
            tk.Label(foot, text=footer, fg=MUT, bg=BOXBG, font=F_TINY, anchor='e').pack(side='right')
        r2_ = Rule(inner); r2_.configure(bg=BOXBG); r2_.pack(side='bottom', fill='x', pady=(6, 3))
        txt.pack(fill='both', expand=True)
        win.geometry('%dx%d+%d+%d' % (bw, bh, bx, by))
        try:
            import ctypes
            win.update_idletasks()
            top_ = ctypes.windll.user32.GetAncestor(win.winfo_id(), 2)
            ctypes.windll.dwmapi.DwmSetWindowAttribute(
                ctypes.c_void_p(top_), 33, ctypes.byref(ctypes.c_int(2)), 4)
        except Exception:
            pass
        for wdg in ([win, shell, inner, txt, band] + marks + imgs + marks_extra +
                    list(inner.winfo_children()) + list(hd.winfo_children()) + list(who.winfo_children())):
            wdg.bind('<Button-1>', lambda e: hide_boxes())
        boxes.append(win)

    def show_boxes(rect, phys_w, lines):
        if not load_settings().get('loading_panels', False):
            st['boxes_ok'] = True; return          # the panels are switched off: nothing to draw or read
        st['boxes_ok'] = False                     # set once the panels are up with real players
        def go():
            hide_boxes()
            # who is playing what: the replay if the game has already written it, else read off the loading screen
            players = []
            f = newest_replay()
            # only trust a replay the game has just started writing, not the one from your last game
            lob = read_lobby(f) if f and time.time() - os.path.getctime(f) < 25 else None
            if lob and lob['players']:
                mine_ = next((p for p in lob['players'] if p['human'] and p['profile'] == me), None)
                for p in lob['players']:
                    players.append(dict(name=p['name'], civ=p['civ'], me=p is mine_, profile=p.get('profile'),
                                        human=p['human'], colour=p.get('colour'),
                                        team='' if p['team'] <= 1 else str(p['team'])))
            ocr_players = read_loading_players(lines, labels, mine) if lines else []
            if ocr_players and any(p['me'] for p in ocr_players) or not players:
                players = ocr_players or players
            log('loading players: %s' % players)
            me_p = next((p for p in players if p['me']), None)
            st['boxes_ok'] = bool(me_p)            # drawn from the replay, no screen reading needed
            opps = [p for p in players if not p['me'] and (me_p is None or not me_p['team'] or 'no' in me_p['team']
                                                           or p['team'] != me_p['team'])]
            sc = root.winfo_screenwidth() / float(phys_w or root.winfo_screenwidth())   # physical px -> Tk px
            x, y, w, hh = [v * sc for v in rect]
            s_ = hh / 1079.0; cx = x + w / 2
            # where the two panels sit on the loading screen, as a fraction of its 1079 tall layout
            # your panel is the small one up top, theirs is the big one you actually read
            BW, YOURS, YH, THEIRS, TH = 760, 106, 334, 452, 434
            green = (int(cx - BW / 2 * s_), int(y + YOURS * s_), int(BW * s_), int(YH * s_))
            red = (int(cx - BW / 2 * s_), int(y + THEIRS * s_), int(BW * s_), int(TH * s_))
            map_now = (st.get('game') or {}).get('map', '')
            if me_p:
                nm, secs, extra = my_civ_sections(me_p['civ'], strings, icons)
                hexc, cname = player_colour(me_p.get('colour'))
                mine_rec = short_record([g for g in load_stats()['games'] if g.get('civ') == nm])
                map_rec = short_record([g for g in load_stats()['games'] if g.get('map') == map_now])
                bits = [b for b in (('%s %s' % (nm, mine_rec)) if mine_rec else '',
                                    ('%s %s' % (map_now, map_rec)) if map_rec else '') if b]
                make_box(green, GREEN, nm, secs, tag='YOU',
                         meta=[extra['kind'], '   \u00b7   '.join(bits)],
                         emblem=emblem_path(nm), footer=extra['team'], edge=hexc, edge_name=cname)
            if opps:
                team_game = len(players) > 2
                def draw_red(elos):
                    for b_ in list(boxes):
                        if getattr(b_, 'is_red', False):
                            try: b_.destroy()
                            except tk.TclError: pass
                            boxes.remove(b_)
                    if not loadw.showing: return
                    tag = lambda p: ('   \u2022   ' + elos[id(p)]) if elos.get(id(p)) else ''
                    if len(opps) == 1:
                        nm, secs, extra = opp_sections(opps[0]['civ'], strings, icons)
                        if box_state.get('habits'): secs = [('Their recent openings', box_state['habits'])] + secs
                        who = opps[0]['name'] + tag(opps[0])
                        hexc, cname = player_colour(opps[0].get('colour'))
                        make_box(red, REDC, nm, secs, tag='OPPONENT',
                                 meta=[(who, name_colour(opps[0].get('colour'), MUT)),
                                       extra['kind'], record_vs(nm)],
                                 emblem=emblem_path(nm), edge=hexc, edge_name=cname)
                    else:
                        secs = []
                        for p in opps[:3]:
                            nm, ss, _x = opp_sections(p['civ'], strings, icons)
                            secs.append(('#%s  (%s)%s' % (nm, p['name'], tag(p)), [],
                                         None, name_colour(p.get('colour'), None)))
                            secs += [x for x in ss if x[0] != 'Plays as']
                        make_box(red, REDC, 'Opponents', secs,
                                 tag='%d PLAYERS' % len(opps), letter='O')
                    boxes[-1].is_red = True
                box_state = {'elos': {}, 'habits': None}
                draw_red({})
                def look():
                    elos = {}
                    for p in opps[:3]:
                        if p.get('human', True) and p['name']:
                            elos[id(p)] = elo_text(fetch_elo(p.get('profile') or None, p['name']), team_game)
                    box_state['elos'] = elos
                    if any(elos.values()): root.after(0, lambda: draw_red(elos))
                threading.Thread(target=look, daemon=True).start()
                def look_habits():
                    p0 = opps[0]
                    if len(opps) != 1 or not p0.get('profile') or not p0.get('human', True): return
                    if not load_settings().get('opp_openings', True): return
                    try:
                        rows = opponent_openings(p0['profile'], 'TG' if team_game else '1v1',
                                                 5 if team_game else OPEN_GAMES)
                        box_state['habits'] = openings_lines(rows, p0['civ'], strings) or None
                        if box_state['habits']: root.after(0, lambda: draw_red(box_state['elos']))
                    except Exception as e:
                        log('openings lookup failed: %r' % (e,))
                threading.Thread(target=look_habits, daemon=True).start()
        root.after(0, go)

    def stamp_rating(gid, mode, field):
        """Write your own ladder rating onto a game, before it starts or once it is over.
        Public ladder data about yourself, the same number the in-game leaderboard shows."""
        if not me: return
        try:
            e = fetch_elo(me, fresh=True)
            r = e.get('tg' if mode == 'TG' else '1v1')
            if r: record_game({'id': gid, field: r})
        except Exception as e:
            log('rating stamp failed: %r' % (e,))

    def log_game_start(f, lob):
        """Write the game down the moment it starts, so it is kept even if the app is closed."""
        try:
            g = game_entry(f, lob, maps, strings, me)
            st['game'] = g
            record_game(dict(g))
            threading.Thread(target=lambda: (stamp_rating(g['id'], g.get('mode'), 'rating'),
                                             service_check(0)), daemon=True).start()
        except Exception as e:
            log('could not log the game start: %r' % (e,))

    def service_check(first_wait=45, gid=None):
        """Ask the ranked service how the game went. It takes a minute or two to show up there.
        With a game id, keep asking until that game in particular comes back, then show the card."""
        for wait in (first_wait, 75, 120, 180, 300):
            if wait: time.sleep(wait)
            try:
                n = fill_results(me)
            except Exception as e:
                log('result check: %r' % (e,)); return
            if n: root.after(0, refresh_stats_window)
            if gid is None:
                if n: return
                continue
            g = next((x for x in load_stats()['games'] if x.get('id') == gid), None)
            if g and g.get('result') in ('win', 'loss'):
                stamp_rating(gid, g.get('mode'), 'rating_after')
                root.after(0, lambda: show_result_card(gid))
                root.after(0, refresh_stats_window)
                return

    def refresh_stats_window():
        b = st.get('stats_build')
        if b:
            try: b()
            except Exception: pass

    def civ_record(civ, skip_id=''):
        """'Your record: 6 won, 2 lost (75%)' for the civ you are playing."""
        try:
            past = [g for g in load_stats()['games'] if g.get('civ') == civ and g.get('id') != skip_id]
            w_ = sum(1 for g in past if g.get('result') == 'win')
            l_ = sum(1 for g in past if g.get('result') == 'loss')
            if w_ + l_ == 0: return 'Your record: first game recorded with this civ'
            return 'Your record: %d won, %d lost  \u00b7  %d%%' % (w_, l_, round(100 * w_ / (w_ + l_)))
        except Exception:
            return ''

    def show_record(civ, skip_id=''):
        """Your own record with the civ you are playing, on the overlay itself."""
        t = civ_record(civ, skip_id)
        if not t:
            rec_line.config(text=''); rec_line.grid_remove(); return
        rec_line.config(text='%s  \u00b7  %s' % (civ, t.replace('Your record: ', '')))
        rec_line.grid()

    def hide_card():
        st['card'] = None
        card.grid_remove()

    def show_result_card(gid):
        """How the last game went, on the overlay, as soon as the service confirms it.
        Only ever shown while you are back at the menu, never over a live game."""
        try:
            g = next((x for x in load_stats()['games'] if x.get('id') == gid), None)
        except Exception:
            return
        if not g or g.get('result') not in ('win', 'loss'): return
        if st.get('last') is not None: return             # a new game has already started
        won = g['result'] == 'win'
        card.config(highlightbackground=GREEN if won else REDC)
        card_word.config(text='WON' if won else 'LOST', fg=GREEN if won else REDC)
        bits = [b for b in (g.get('civ'), ('on ' + g['map']) if g.get('map') else '',
                            fmt_len(game_length(g)) if game_length(g) else '',
                            ' '.join(x for x in (g.get('size') or g.get('mode') or '',
                                                 'ranked' if g.get('ranked') else '') if x).strip()) if b]
        card_line.config(text='   \u00b7   '.join(bits))
        before, after = g.get('rating'), g.get('rating_after')
        if after and before:
            d = after - before
            card_elo.config(text='%d   %s%d' % (after, '+' if d >= 0 else '', d),
                            fg=GREEN if d >= 0 else REDC)
        elif after or before:
            card_elo.config(text='%d' % (after or before), fg=MUT)
        else:
            card_elo.config(text='')
        st['card'] = gid
        rec_line.config(text=''); rec_line.grid_remove()
        if not st.get('rolled'): card.grid()
        root.after(180000, lambda: st.get('card') == gid and hide_card())
    st['actions'][card] = hide_card
    st['actions'][card_word] = hide_card
    st['actions'][card_line] = hide_card
    st['actions'][card_elo] = hide_card

    def game_over(result=None):
        def go():
            gid = None
            if st.get('game'):                             # the result comes from the service, not from here
                st['game']['ended'] = int(time.time())
                gid = st['game'].get('id')
                record_game(dict(st['game'])); st['game'] = None
            threading.Thread(target=lambda: service_check(45, gid), daemon=True).start()
            if st['last'] is None: return
            st['ended'] = st['last']                       # ignore this game's replay from now on
            st['last'] = None; st['first'] = None; st['herd'] = None
            watcher.active = False; watcher.reset()
            tcw.active = False
            scout.active = False; scout.stop_game(); score_off()
            title.config(text=APP_NAME); idle_size(True)
            rec_line.config(text=''); rec_line.grid_remove(); show_footer(True)
            stats_btn.grid()
            show_opponents([]); hide_boxes()
        root.after(0, go)

    def boxes_pending():
        """Did the panels go up off the replay? If so the screen never has to be read."""
        for _ in range(8):
            if st.get('boxes_ok'): return False
            time.sleep(0.05)
        return True

    loadw = LoadWatcher(strings, show_boxes, lambda: root.after(0, hide_boxes), game_over,
                        lambda: st.get('last') is not None)
    loadw.needs_text = boxes_pending
    tcw.pause_fn = lambda: loadw.showing or bool(st.get('hosting'))
    scout.pause_fn = lambda: loadw.showing or bool(st.get('hosting'))

    def game_starting():
        """True once the game has begun writing this match's replay, which is the moment the
        real loading screen comes up. Keeps the panels out of the lobby before it."""
        try:
            f = newest_replay()
            return bool(f) and time.time() - os.path.getctime(f) < 180
        except Exception:
            return True
    loadw.started = game_starting
    loadw.start()

    def toggle(widget):
        if widget.winfo_manager(): widget.grid_remove()
        else: widget.grid()
    st['actions'][title] = lambda: toggle(body)

    def press(e):
        st['shift'] = bool(e.state & 1)
        st['drag'] = (e.x_root - root.winfo_x(), e.y_root - root.winfo_y(), e.x_root, e.y_root)
    def motion(e):
        if st['drag']: root.geometry('+%d+%d' % (e.x_root - st['drag'][0], e.y_root - st['drag'][1]))
    def remember_pos():
        try:
            c = load_settings(); c['pos'] = [root.winfo_x(), root.winfo_y()]; save_settings(c)
        except Exception: pass
    def release(e):
        d = st['drag']; st['drag'] = None
        if d and abs(e.x_root - d[2]) < 4 and abs(e.y_root - d[3]) < 4:
            act = st['actions'].get(e.widget)
            if act: act()
        elif d:
            remember_pos()                 # moved: keep this spot for next time
    def bind_all(w):
        w.bind('<ButtonPress-1>', press); w.bind('<B1-Motion>', motion)
        w.bind('<ButtonRelease-1>', release)
    for w in (root, frame, head, title, state, stats_btn, body, rec_line, opp_area, footsep, sep,
              host_row, btn_plate, host_btn, host_msg, hint,
              card, card_word, card_line, card_elo): bind_all(w)

    for cx, cy, ax, ay in ((0, 0, 1, 1), (1, 0, -1, 1), (0, 1, 1, -1), (1, 1, -1, -1)):
        for w_, h_ in ((10, 2), (2, 10)):      # the little L pieces in each corner of the panel
            piece = tk.Frame(root, bg=BRONZE, width=w_, height=h_)   # on root, inside the bronze ring
            piece.place(relx=cx, rely=cy, x=6 if ax > 0 else -6, y=6 if ay > 0 else -6,
                        anchor=('nw' if ax > 0 else 'ne') if ay > 0 else ('sw' if ax > 0 else 'se'))
            piece.lift(); bind_all(piece)
    st['actions'][close] = root.destroy

    def show_footer(on):
        """The party invite button only makes sense at the menu. Out of a game it is there,
        in a game it is gone, so there is nothing to fat finger while you play."""
        st['footer'] = on
        if st.get('rolled'): return
        for w in (footsep, host_row):
            if on:
                if w is footsep and waiting_now[0]: continue      # no divider while idle
                w.grid()
            else:
                w.grid_remove()

    def toggle_roll():
        """Click the name to roll the overlay up to just its header, and again to open it."""
        up = not st.get('rolled')
        for w in (sep, body, rec_line, card, score_line, opp_area, footsep, host_row):
            if up: w.grid_remove()
            elif w is score_line:
                if score_line.cget('text'): w.grid()
            elif w in (footsep, host_row) and not st.get('footer', True): continue
            elif w is footsep and waiting_now[0]: continue
            elif w is body and not body.cget('text'): continue      # nothing to show while waiting
            elif w is card: 
                if st.get('card'): w.grid()
            elif w is not rec_line or rec_line.cget('text'): w.grid()
        st['rolled'] = up
    st['actions'][title] = toggle_roll

    def hover_fade():
        """Solid while the mouse is over it, faded while you are playing. Polled, because
        Tk fires a Leave on the window every time the pointer crosses into one of its labels."""
        try:
            px_, py_ = root.winfo_pointerxy()
            inside = (root.winfo_rootx() <= px_ < root.winfo_rootx() + root.winfo_width() and
                      root.winfo_rooty() <= py_ < root.winfo_rooty() + root.winfo_height())
            want = 0.97 if inside else 0.88
            if st.get('alpha') != want:
                st['alpha'] = want; root.attributes('-alpha', want)
            if inside != st.get('showing_hint'):            # the hint only while you are pointing at it
                st['showing_hint'] = inside
                hint.grid_remove()                          # the hover hint is switched off
        except Exception:
            pass

    def open_settings():
        if st.get('settings_win') is not None:
            try: st['settings_win'].lift(); return
            except tk.TclError: st['settings_win'] = None
        cfg = load_settings()
        win = tk.Toplevel(root); st['settings_win'] = win
        win.title(APP_NAME + ' settings'); win.configure(bg=BORDER); win.attributes('-topmost', True)
        win.resizable(False, False)

        # The sections scroll (mouse wheel or the bar) so the window always fits the screen,
        # and the Save row is pinned underneath where it can always be reached.
        shell_ = tk.Frame(win, bg=INK); shell_.pack(fill='both', expand=True, padx=1, pady=1)
        foot = tk.Frame(shell_, bg=INK, padx=18); foot.pack(side='bottom', fill='x', pady=(0, 14))
        bar_ = tk.Scrollbar(shell_, orient='vertical', width=12)
        board_ = tk.Canvas(shell_, bg=INK, highlightthickness=0, bd=0, yscrollcommand=bar_.set)
        bar_.config(command=board_.yview)
        board_.pack(side='left', fill='both', expand=True)
        outer = tk.Frame(board_, bg=INK, padx=18, pady=14)
        board_.create_window((0, 0), window=outer, anchor='nw')
        def fit_(_=None):
            room = win.winfo_screenheight() - 230               # leave space for the Save row and the taskbar
            board_.configure(scrollregion=board_.bbox('all'), width=outer.winfo_reqwidth(),
                             height=min(outer.winfo_reqheight(), room))
            if outer.winfo_reqheight() > room: bar_.pack(side='right', fill='y')
            else: bar_.pack_forget()
        outer.bind('<Configure>', fit_)
        def wheel_(e):
            if outer.winfo_reqheight() > board_.winfo_height():
                board_.yview_scroll(-1 if e.delta > 0 else 1, 'units')
        win.bind('<MouseWheel>', wheel_)

        hd = tk.Frame(outer, bg=INK); hd.pack(fill='x')
        tk.Frame(hd, bg=GOLD, width=3, height=18).pack(side='left', padx=(0, 9))
        tk.Label(hd, text='Settings', fg=GOLD, bg=INK, font=F_TITLE).pack(side='left')
        tk.Label(hd, text=VERSION, fg=MUT, bg=PANEL, font=F_TINY, padx=5, pady=1).pack(side='right')
        sr_ = Rule(outer); sr_.configure(bg=INK); sr_.pack(fill='x', pady=(8, 0))

        def section(label, note=None, gap=14):
            """A gold field label with its grey one-liner under it."""
            tk.Label(outer, text=label, fg=GOLD, bg=INK, font=F_HEAD, anchor='w').pack(fill='x', pady=(gap, 2))
            if note:
                tk.Label(outer, text=note, fg=MUT, bg=INK, font=F_SMALL, anchor='w',
                         justify='left', wraplength=400).pack(fill='x', pady=(0, 4))

        section('Update', 'Gets the newest version from GitHub, then closes and restarts the app. '
                          'Prod is the settled version. dev gets new changes first.', gap=10)
        up_row = tk.Frame(outer, bg=INK); up_row.pack(fill='x', pady=(2, 0))
        up_msg = tk.Label(outer, text='This copy is %s.' % VERSION, fg='#b8b19f', bg=INK, font=F_SMALL,
                          anchor='w', justify='left', wraplength=400)
        def run_update(branch):
            if st.get('updating'): return
            st['updating'] = True
            up_msg.config(text='Checking GitHub for the newest %s...' % branch, fg=MUT)
            def work():
                try:
                    ok_, text_, bat_ = update_from_github(branch)
                except Exception as e:
                    log('update failed: %r' % (e,))
                    ok_, text_, bat_ = False, 'Update failed: %s' % e, None
                log('update from %s: %s' % (branch, text_))
                def done():
                    st['updating'] = False
                    try: up_msg.config(text=text_ + ('  Restarting...' if bat_ else ''), fg=GREEN if ok_ else REDC)
                    except tk.TclError: pass
                    if bat_:
                        def swap():
                            try: restart_app(bat_)
                            except Exception as e:
                                log('restart failed: %r' % (e,))
                                try: up_msg.config(text='Updated, but could not restart: %s' % e, fg=REDC)
                                except tk.TclError: pass
                                return
                            try: root.destroy()
                            finally: os._exit(0)
                        root.after(1200, swap)
                root.after(0, done)
            threading.Thread(target=work, daemon=True).start()
        flat_button(up_row, 'Update from Prod', lambda: run_update('Prod'), fill=True).pack(side='left')
        flat_button(up_row, 'Update from dev', lambda: run_update('dev')).pack(side='left', padx=(8, 0))
        up_msg.pack(fill='x', pady=(6, 0))
        def where_am_i():
            b = git_branch(os.path.dirname(self_path()))
            def say():
                try:
                    if up_msg.cget('text').startswith('This copy'):
                        up_msg.config(text='This copy is %s%s.' % (
                            VERSION, (', from the %s branch' % b) if b else ', not in a git folder'))
                except tk.TclError: pass                       # the window was closed in the meantime
            try: root.after(0, say)
            except Exception: pass
        threading.Thread(target=where_am_i, daemon=True).start()

        section('Discord channel name')
        ch = tk.Entry(outer, width=46); style_entry(ch)
        ch.insert(0, cfg.get('channel', 'wesley')); ch.pack(fill='x', ipady=3)

        section('Discord webhook link for that channel',
                'In Discord: channel settings > Integrations > Webhooks > New Webhook > Copy Webhook URL')
        wh = tk.Entry(outer, width=46, show='\u2022'); style_entry(wh)
        wh.insert(0, cfg.get('webhook', '')); wh.pack(fill='x', ipady=3)

        section('Friends to invite to your ranked party (one per line)',
                "Type their names exactly as they show in the game's Invite To Party list.")
        fr = tk.Text(outer, width=46, height=6); style_entry(fr)
        fr.insert('1.0', '\n'.join(cfg.get('friends', []))); fr.pack(fill='x')

        section('Discord people to tag (optional, one per line)',
                'A plain name shows as @name. A Discord user ID (numbers) pings them properly. Blank uses the list above.')
        pg = tk.Text(outer, width=46, height=4); style_entry(pg)
        pg.insert('1.0', '\n'.join(cfg.get('pings', []))); pg.pack(fill='x')

        section('Idle Town Center alert',
                'A red badge under the Global Queue when nothing is queued at your Town Center, or BUILD A HOUSE '
                'when you are close to the pop limit (2 spare to 10 min, 4 to 20, 8 to 30, 10 to 40, then 15; '
                'not in the first 2 game minutes). Clicks go straight through the badge to the game.')
        tc_on = tk.BooleanVar(value=cfg.get('tc_alert', True))
        for var, txt in ((tc_on, 'Show the alert'),):
            tk.Checkbutton(outer, text=txt, variable=var, fg=TXT, bg=INK, selectcolor=PANEL, activebackground=INK,
                           activeforeground=GOLDD, font=F_SMALL, anchor='w', highlightthickness=0).pack(fill='x')

        lp_on = tk.BooleanVar(value=cfg.get('loading_panels', False))
        section('Loading screen panels',
                'Two panels over the loading screen with a cheat sheet for your civ and your opponent\'s. '
                'Off by default. Your opponent\'s details are on the main overlay either way.')
        tk.Checkbutton(outer, text='Show the two panels while the game loads', variable=lp_on, fg=TXT, bg=INK,
                       selectcolor=PANEL, activebackground=INK, activeforeground=GOLDD,
                       font=F_SMALL, anchor='w', highlightthickness=0).pack(fill='x')

        section('When the game starts',
                'If you are in another window when a match finishes loading, the overlay switches you to the '
                'game. If Windows will not allow that, it puts up a banner and plays a sound instead.')
        fg_on = tk.BooleanVar(value=cfg.get('focus_game', True))
        tk.Checkbutton(outer, text='Bring the game to the front when it starts', variable=fg_on, fg=TXT, bg=INK,
                       selectcolor=PANEL, activebackground=INK, activeforeground=GOLDD,
                       font=F_SMALL, anchor='w', highlightthickness=0).pack(fill='x')
        cn_on = tk.BooleanVar(value=cfg.get('castle_note', True))
        tk.Checkbutton(outer, text='At %d minutes, remind me to check my two buildings for Castle Age' % CASTLE_NOTE_MIN,
                       variable=cn_on, fg=TXT, bg=INK, selectcolor=PANEL, activebackground=INK,
                       activeforeground=GOLDD, font=F_SMALL, anchor='w', highlightthickness=0).pack(fill='x')

        section('Score check',
                'Reads the score list in the corner of your own screen and compares your side\'s total with '
                'the other side\'s. Once you have been more than %d%% behind for %d seconds (and not in the '
                'first %d minutes) the overlay shows CONCEDE AVAILABLE. It only tells you: it never resigns '
                'or clicks for you.' % (round(CONCEDE_BEHIND * 100), CONCEDE_HOLD_S, CONCEDE_FROM_MIN))
        cf_on = tk.BooleanVar(value=cfg.get('concede_flag', True))
        tk.Checkbutton(outer, text='Flag when a game looks gone', variable=cf_on, fg=TXT, bg=INK,
                       selectcolor=PANEL, activebackground=INK, activeforeground=GOLDD,
                       font=F_SMALL, anchor='w', highlightthickness=0).pack(fill='x')

        section('Opponent\'s own openings',
                'Looks up your opponent\'s last few public games and reads how they opened in each '
                '(scouts, archers, fast castle and so on), from the recorded games the official site '
                'hands out. Past games only: nothing is read from the game you are in.')
        oo_on = tk.BooleanVar(value=cfg.get('opp_openings', True))
        tk.Checkbutton(outer, text='Show how they have been opening', variable=oo_on, fg=TXT, bg=INK,
                       selectcolor=PANEL, activebackground=INK, activeforeground=GOLDD,
                       font=F_SMALL, anchor='w', highlightthickness=0).pack(fill='x')

        section('Opponent spotted alert',
                'Says the colour out loud the first time an opponent shows up on your own minimap, '
                'and puts a line on the overlay. It reads the minimap only, which paints explored '
                'ground and nothing else, so it never tells you anything you are not already being '
                'shown. It does not flare or click for you.')
        sc_on = tk.BooleanVar(value=cfg.get('scout_alert', True))
        tk.Checkbutton(outer, text='Call out opponents', variable=sc_on, fg=TXT, bg=INK,
                       selectcolor=PANEL, activebackground=INK, activeforeground=GOLDD,
                       font=F_SMALL, anchor='w', highlightthickness=0).pack(fill='x')
        voice_row = tk.Frame(outer, bg=INK); voice_row.pack(fill='x', pady=(4, 0))
        voice_msg = tk.Label(outer, text='', fg='#b8b19f', bg=INK, font=F_TINY, anchor='w',
                             justify='left', wraplength=400)
        voice_msg.pack(fill='x', pady=(4, 0))

        def test_voice():
            voice_msg.config(text='Recording the eight colour names...', fg=MUT)
            def work():
                ok = 0
                for n in PLAYER_NAMES:
                    if make_voice('%s found' % n, os.path.join(sound_dir(), '%s.wav' % n.lower())): ok += 1
                play_voice(os.path.join(sound_dir(), '%s.wav' % PLAYER_NAMES[0].lower()))
                txt = ('Done, %d of %d recorded. You just heard the blue one.' % (ok, len(PLAYER_NAMES))
                       if ok else 'Windows would not record a voice line, so you will get two beeps instead.')
                try: win.after(0, lambda: voice_msg.config(text=txt, fg=GREEN if ok else GOLDC))
                except Exception: pass
            threading.Thread(target=work, daemon=True).start()
        flat_button(voice_row, 'Record and test the voice', test_voice).pack(side='left')

        sr3_ = Rule(outer); sr3_.configure(bg=INK); sr3_.pack(fill='x', pady=(14, 0))
        section('God Mode mod',
                'The UI mod this app is built around. It pins the resource bar and the Global Queue in place, '
                'which is what the idle Town Center alert reads. The button opens its page on the official mod '
                'site: sign in and press Subscribe, and the game downloads it the next time it starts.')
        gm_row = tk.Frame(outer, bg=INK); gm_row.pack(fill='x', pady=(2, 0))
        gm_state, gm_text = god_mode_status()
        flat_button(gm_row, 'Install God Mode' if gm_state == 'missing' else 'Open its mod page',
                    open_god_mode_page, fill=gm_state == 'missing').pack(side='left')
        tk.Label(gm_row, text=gm_text, fg=GREEN if gm_state == 'on' else GOLDC if gm_state == 'off' else REDC,
                 bg=INK, font=F_SMALL, anchor='w').pack(side='left', padx=(10, 0))

        section('Mod clashes',
                'Two enabled mods shipping the same file means only one of them is doing anything. '
                'This reads your enabled mod list in the order the game layers it and tells you which '
                'one wins. GodMode merges other mods in on purpose, so it is expected to win over its '
                'own sources.')
        clash_row = tk.Frame(outer, bg=INK); clash_row.pack(fill='x', pady=(2, 0))
        clash_out = tk.Label(outer, text='', fg='#b8b19f', bg=INK, font=F_TINY, anchor='w',
                             justify='left', wraplength=400)
        clash_out.pack(fill='x', pady=(6, 0))

        def run_clash_check():
            clash_out.config(text='Reading your mods...', fg=MUT)
            def work():
                try:
                    rows = mod_clashes()
                except Exception as e:
                    txt, col = 'Could not read the mod folders: %r' % (e,), REDC
                else:
                    if not rows:
                        txt, col = 'No clashes. Every enabled mod ships files no other one touches.', GREEN
                    else:
                        lines = ['%s beats %s on %d file%s  (%s%s)'
                                 % (w, l, n, '' if n == 1 else 's', ', '.join(ex),
                                    ', ...' if n > len(ex) else '')
                                 for w, l, n, ex in rows[:8]]
                        if len(rows) > 8: lines.append('and %d more pairs' % (len(rows) - 8))
                        txt, col = '\n'.join(lines), GOLDC
                try: win.after(0, lambda: clash_out.config(text=txt, fg=col))
                except Exception: pass
            threading.Thread(target=work, daemon=True).start()
        flat_button(clash_row, 'Check my mods', run_clash_check).pack(side='left')

        sr2_ = Rule(foot); sr2_.configure(bg=INK); sr2_.pack(fill='x', pady=(6, 0))
        def collect():
            return {'channel': ch.get().strip().lstrip('#'), 'webhook': wh.get().strip(),
                    'tc_alert': bool(tc_on.get()), 'scout_alert': bool(sc_on.get()),
                    'concede_flag': bool(cf_on.get()), 'opp_openings': bool(oo_on.get()),
                    'focus_game': bool(fg_on.get()), 'castle_note': bool(cn_on.get()),
                    'loading_panels': bool(lp_on.get()),
                    'friends': [l.strip() for l in fr.get('1.0', 'end').splitlines() if l.strip()],
                    'pings': [l.strip() for l in pg.get('1.0', 'end').splitlines() if l.strip()]}
        def save():
            c = collect()
            if c['webhook'] and not re.match(r'https://(\w+\.)?discord(app)?\.com/api/webhooks/', c['webhook']):
                msg.config(text="That doesn't look like a Discord webhook link.", fg=REDC); return
            merged = load_settings(); merged.update(c); save_settings(merged)
            tc_settings(); tc_draw()
            scorew.enabled = merged.get('concede_flag', True)
            msg.config(text='Saved.', fg=GREEN)
        def test():
            c = collect()
            if not c['webhook']: msg.config(text='Paste the webhook link first.', fg=REDC); return
            try:
                post_discord(c['webhook'], 'Test from %s. Invites will look like this:\n' % APP_NAME +
                             invite_message('aoe2de://0/123456789', '123456789', c['pings'] or c['friends']))
                msg.config(text='Sent a test message to #%s.' % (c['channel'] or 'discord'), fg=GREEN)
            except Exception as e:
                msg.config(text='Discord said no: %s' % e, fg=REDC)
        def close_win():
            st['settings_win'] = None; win.destroy()

        btns = tk.Frame(foot, bg=INK); btns.pack(fill='x', pady=(12, 0))
        flat_button(btns, 'Save', save, fill=True).pack(side='left')
        flat_button(btns, 'Send test', test).pack(side='left', padx=(8, 0))
        flat_button(btns, 'Cancel', close_win, accent=MUT, hot='#cfc8b6').pack(side='right')
        msg = tk.Label(foot, text='', fg='#b8b19f', bg=INK, font=F_SMALL, anchor='w',
                       justify='left', wraplength=400)
        msg.pack(fill='x', pady=(10, 0))
        win.update_idletasks(); fit_()
        win.update_idletasks()                             # keep the whole window on the screen
        win.geometry('+%d+%d' % (max(0, (win.winfo_screenwidth() - win.winfo_reqwidth()) // 2),
                                 max(0, (win.winfo_screenheight() - win.winfo_reqheight()) // 2 - 24)))

        win.bind('<Escape>', lambda e: close_win())        # Esc does the same as Cancel
        win.protocol('WM_DELETE_WINDOW', close_win)
        try: win.focus_force()
        except tk.TclError: pass
    st['actions'][gear] = open_settings

    def open_stats():
        """The record: filters for 1v1 / team games, time window and ranked, then your form, rating,
        best and worst civs, maps and match-ups, and the last games with their result."""
        if st.get('stats_win') is not None:
            try: st['stats_win'].lift(); return
            except tk.TclError: st['stats_win'] = None
        cfg_ = load_settings()
        st.setdefault('scope', cfg_.get('stats_mode', 'all'))
        st.setdefault('days', cfg_.get('stats_days', 0))
        st.setdefault('ranked', cfg_.get('stats_ranked', False))
        win = tk.Toplevel(root); st['stats_win'] = win
        win.title(APP_NAME + ' record'); win.configure(bg=RIM); win.attributes('-topmost', True)
        win.geometry('600x720'); win.minsize(520, 460)
        outer = tk.Frame(win, bg=INK, padx=18, pady=14)
        outer.pack(fill='both', expand=True, padx=2, pady=2)

        hd = tk.Frame(outer, bg=INK); hd.pack(fill='x')
        tk.Label(hd, text='Record', fg=GOLDC, bg=INK, font=F_HEADLINE).pack(side='left')
        rating = tk.Label(hd, text='', fg=MUT, bg=INK, font=F_SMALL)
        rating.pack(side='right')

        # filter bar: 1v1 / team games, time window, ranked only
        bar_ = tk.Frame(outer, bg=INK); bar_.pack(fill='x', pady=(10, 0))
        chips = {}

        def segment(parent, key, options):
            box = tk.Frame(parent, bg=RIM, padx=1, pady=1)
            inner_ = tk.Frame(box, bg=PANEL); inner_.pack()
            for val, text in options:
                c = tk.Label(inner_, text=text, font=(DISPLAY, 9, 'bold'), padx=11, pady=4, cursor='hand2')
                c.pack(side='left')
                c.bind('<Button-1>', lambda e, k=key, v=val: pick(k, v))
                chips.setdefault(key, []).append((val, c))
            return box

        def paint_chips():
            for key, items in chips.items():
                for val, c in items:
                    on = st.get(key) == val
                    c.config(bg=GOLDC if on else PANEL, fg=INK if on else MUT)

        def pick(key, val):
            st[key] = val
            merged = load_settings()
            merged.update({'stats_mode': st['scope'], 'stats_days': st['days'], 'stats_ranked': st['ranked']})
            save_settings(merged)
            build()

        segment(bar_, 'scope', (('all', 'All'), ('1v1', '1v1'), ('TG', 'Team games'))).pack(side='left')
        segment(bar_, 'days', ((0, 'All time'), (30, '30 days'), (7, '7 days'))).pack(side='left', padx=(10, 0))
        segment(bar_, 'ranked', ((False, 'Any'), (True, 'Ranked'))).pack(side='right')

        r0 = Rule(outer); r0.configure(bg=INK); r0.pack(fill='x', pady=(10, 2))
        summary = tk.Frame(outer, bg=INK); summary.pack(fill='x')
        board = tk.Canvas(outer, bg=INK, highlightthickness=0)
        inner = tk.Frame(board, bg=INK)
        board.create_window((0, 0), window=inner, anchor='nw', tags='inner')
        board.bind('<Configure>', lambda e: board.itemconfigure('inner', width=e.width))
        inner.bind('<Configure>', lambda e: board.configure(scrollregion=board.bbox('all')))
        board.pack(fill='both', expand=True, pady=(6, 0))
        win.bind('<MouseWheel>', lambda e: board.yview_scroll(-1 if e.delta > 0 else 1, 'units'))
        win.bind('<Button-4>', lambda e: board.yview_scroll(-1, 'units'))
        win.bind('<Button-5>', lambda e: board.yview_scroll(1, 'units'))

        def close_win():
            st['stats_win'] = None; st['stats_build'] = None; win.destroy()

        def bar(parent, frac, wide=110, high=8):
            b = tk.Frame(parent, bg=PANEL, width=wide, height=high,
                         highlightthickness=1, highlightbackground=RIM)
            b.pack_propagate(False)
            tk.Frame(b, bg=GREEN if frac >= 0.5 else REDC).place(
                x=0, y=0, relwidth=max(0.0, min(1.0, frac)), relheight=1)
            return b

        def caption(parent, text, note=''):
            row = tk.Frame(parent, bg=INK); row.pack(fill='x', pady=(14, 4))
            tk.Label(row, text=text, fg=BRONZE, bg=INK, font=(DISPLAY, 8, 'bold'), anchor='w').pack(side='left')
            if note: tk.Label(row, text=note, fg=FAINT, bg=INK, font=F_TINY).pack(side='right')

        def table(parent, rows, limit=12):
            t = tk.Frame(parent, bg=INK); t.pack(fill='x')
            t.columnconfigure(0, weight=1)
            for i, (name, played, w_, l_, unk) in enumerate(rows[:limit]):
                dec = w_ + l_
                fr = (w_ / dec) if dec else 0.0
                tk.Label(t, text=name, fg=TXT, bg=INK, font=F_BODY, anchor='w').grid(row=i, column=0, sticky='w', pady=2)
                tk.Label(t, text='%d-%d' % (w_, l_), fg=MUT, bg=INK, font=F_SMALL, width=7,
                         anchor='e').grid(row=i, column=1, sticky='e', padx=(8, 8))
                bar(t, fr).grid(row=i, column=2, padx=(0, 10))
                tk.Label(t, text=('%d%%' % round(fr * 100)) if dec else '-', fg=GOLDC if dec else FAINT,
                         bg=INK, font=F_SMALL, width=5, anchor='e').grid(row=i, column=3, sticky='e')
                tk.Label(t, text=('+%d' % unk) if unk else '', fg=FAINT, bg=INK, font=F_TINY,
                         width=3).grid(row=i, column=4, sticky='e', padx=(4, 0))
            if len(rows) > limit:
                tk.Label(parent, text='and %d more' % (len(rows) - limit), fg=FAINT, bg=INK,
                         font=F_TINY, anchor='w').pack(fill='x')

        def show_rating():
            def work():
                e = fetch_elo(me) if me else {}
                def put():
                    if not e: rating.config(text=''); return
                    team = st.get('scope') == 'TG'
                    rating.config(text=elo_text(e, team) and 'Rating  ' + elo_text(e, team))
                try: root.after(0, put)
                except Exception: pass
            threading.Thread(target=work, daemon=True).start()

        def build():
            paint_chips()
            for w in list(summary.winfo_children()) + list(inner.winfo_children()): w.destroy()
            every = load_stats()['games']
            games = filter_games(every, st['scope'], st['days'], st['ranked'])
            wins = sum(1 for g in games if g.get('result') == 'win')
            losses = sum(1 for g in games if g.get('result') == 'loss')
            decided = wins + losses
            rate = (wins / decided) if decided else 0.0

            # headline: win rate, record, streak, last 10
            left = tk.Frame(summary, bg=INK); left.pack(side='left')
            tk.Label(left, text='%d%%' % round(rate * 100) if decided else '-', fg=GOLDC, bg=INK,
                     font=(DISPLAY, 28, 'bold')).pack(anchor='w')
            tk.Label(left, text='win rate', fg=MUT, bg=INK, font=F_SMALL).pack(anchor='w')
            right = tk.Frame(summary, bg=INK); right.pack(side='right', pady=(4, 0))
            tk.Label(right, text='%d won   %d lost' % (wins, losses), fg=TXT, bg=INK, font=F_BODY).pack(anchor='e')
            extra = len(games) - decided
            tk.Label(right, text='%d games%s' % (len(games), ('   ·   %d with no result' % extra) if extra else ''),
                     fg=FAINT, bg=INK, font=F_TINY).pack(anchor='e', pady=(2, 0))
            if decided:
                bar(right, rate, wide=190, high=9).pack(anchor='e', pady=(6, 0))
            kind, n = current_streak(games)
            info = tk.Frame(right, bg=INK); info.pack(anchor='e', pady=(7, 0))
            if kind:
                tk.Label(info, text='%s streak %d' % ('Win' if kind == 'W' else 'Loss', n),
                         fg=GREEN if kind == 'W' else REDC, bg=INK, font=F_SMALL).pack(side='left', padx=(0, 10))
            form = [g.get('result') for g in games if g.get('result') in ('win', 'loss')][-10:]
            if form:
                tk.Label(info, text='last %d' % len(form), fg=FAINT, bg=INK, font=F_TINY).pack(side='left', padx=(0, 4))
                for r in form:
                    tk.Frame(info, bg=GREEN if r == 'win' else REDC, width=9, height=9).pack(side='left', padx=1)
            lens_w = [game_length(g) for g in games if g.get('result') == 'win' and game_length(g)]
            lens_l = [game_length(g) for g in games if g.get('result') == 'loss' and game_length(g)]
            if lens_w or lens_l:
                tk.Label(right, text='average game  ·  wins %s  ·  losses %s' % (
                    fmt_len(sum(lens_w) / len(lens_w)) if lens_w else '-',
                    fmt_len(sum(lens_l) / len(lens_l)) if lens_l else '-'),
                    fg=MUT, bg=INK, font=F_TINY).pack(anchor='e', pady=(5, 0))
            if st['scope'] == 'all':                                  # how the two kinds of game compare
                split = []
                for lab, key in (('1v1', '1v1'), ('TG', 'TG')):
                    w2 = sum(1 for g in games if g.get('mode') == key and g.get('result') == 'win')
                    l2 = sum(1 for g in games if g.get('mode') == key and g.get('result') == 'loss')
                    if w2 + l2: split.append('%s %d-%d (%d%%)' % (lab, w2, l2, round(100 * w2 / (w2 + l2))))
                if split:
                    tk.Label(right, text='   ·   '.join(split), fg=MUT, bg=INK, font=F_SMALL).pack(anchor='e', pady=(5, 0))

            if not games:
                tk.Label(inner, text='No games here yet. Try a wider filter, or play one and it will show up.',
                         fg=MUT, bg=INK, font=F_BODY, anchor='w').pack(fill='x', pady=(20, 0))
                return

            civs = tally_by(games, 'civ')
            maps = tally_by(games, 'map')
            opps = tally_by(games, 'opp')
            # one line of takeaways: where you win and where you struggle (3+ decided games)
            notes = []
            for label, rows in (('civ', civs), ('map', maps), ('vs', opps)):
                best, worst = best_worst(rows)
                if best and best[0] >= 0.5:
                    notes.append(('Best %s' % label if label != 'vs' else 'Easiest match-up',
                                  '%s %d%%' % (best[1][0], round(best[0] * 100)), GREEN))
                if worst and worst[0] < 0.5 and worst is not best:
                    notes.append(('Worst %s' % label if label != 'vs' else 'Hardest match-up',
                                  '%s %d%%' % (worst[1][0], round(worst[0] * 100)), REDC))
            if notes:
                caption(inner, 'AT A GLANCE', '3+ games with a result')
                grid_ = tk.Frame(inner, bg=INK); grid_.pack(fill='x')
                for i, (lab, val, col) in enumerate(notes):
                    cell = tk.Frame(grid_, bg=PANEL, highlightthickness=1, highlightbackground=EDGE, padx=8, pady=5)
                    cell.grid(row=i // 2, column=i % 2, sticky='we', padx=(0, 6), pady=3)
                    tk.Label(cell, text=lab.upper(), fg=FAINT, bg=PANEL, font=F_TINY, anchor='w').pack(fill='x')
                    tk.Label(cell, text=val, fg=col, bg=PANEL, font=F_BODY, anchor='w').pack(fill='x')
                grid_.columnconfigure(0, weight=1); grid_.columnconfigure(1, weight=1)

            bans = map_bans([g for g in games if g.get('ranked')] or games)
            if bans:
                caption(inner, 'BAN THESE MAPS', 'your worst, 4+ decided ranked games')
                table(inner, bans, limit=3)

            caption(inner, 'YOUR CIVILISATIONS')
            table(inner, civs)
            caption(inner, 'MAPS')
            table(inner, maps)
            caption(inner, 'AGAINST', 'first opponent in team games' if st['scope'] != '1v1' else '')
            table(inner, [r for r in opps if r[0] != 'Unknown'] or opps)

            caption(inner, 'RECENT GAMES')
            recent = tk.Frame(inner, bg=INK); recent.pack(fill='x')
            recent.columnconfigure(1, weight=1)
            for i, g in enumerate(reversed(games[-25:])):
                tk.Label(recent, text=g.get('at', '')[5:], fg=FAINT, bg=INK, font=F_TINY,
                         anchor='w').grid(row=i, column=0, sticky='w', padx=(0, 8), pady=2)
                vs = ('  vs  %s' % g['opp']) if g.get('opp') else ''
                tk.Label(recent, text='%s%s   ·   %s' % (g.get('civ', '?'), vs, g.get('map', '?')),
                         fg=TXT, bg=INK, font=F_SMALL, anchor='w').grid(row=i, column=1, sticky='w')
                tk.Label(recent, text=fmt_len(game_length(g)) if game_length(g) else '', fg=FAINT, bg=INK,
                         font=F_TINY, width=7, anchor='e').grid(row=i, column=2, sticky='e')
                tk.Label(recent, text=(g.get('size') or g.get('mode') or '') + ('  R' if g.get('ranked') else ''),
                         fg=MUT, bg=INK, font=F_TINY, width=9, anchor='e').grid(row=i, column=3, sticky='e', padx=(6, 0))
                res = g.get('result', '?')
                fresh = time.time() - max(g.get('started', 0), g.get('ended', 0)) < 86400
                word = {'win': 'WON', 'loss': 'LOST'}.get(res, 'waiting' if fresh else '–')
                col = {'win': GREEN, 'loss': REDC}.get(res, FAINT)
                tk.Label(recent, text=word, fg=col, bg=PANEL, font=F_TINY, padx=7, pady=2,
                         width=6, highlightthickness=1,
                         highlightbackground=RIM).grid(row=i, column=4, sticky='e', padx=(8, 0))
            show_rating()

        r1 = Rule(outer); r1.configure(bg=INK); r1.pack(fill='x', pady=(10, 0))
        btns = tk.Frame(outer, bg=INK); btns.pack(fill='x', pady=(10, 0))
        flat_button(btns, 'Close', close_win, accent=MUT, hot=TXT).pack(side='right')
        flat_button(btns, 'Check results now', lambda: (threading.Thread(
            target=lambda: (fill_results(me), root.after(0, build)), daemon=True).start())).pack(side='left')
        tk.Label(outer, text='Results come from your own online match history, so nothing is guessed. '
                 'Games the service does not cover, like skirmishes against the computer, stay blank. '
                 'R marks a ranked game.',
                 fg=FAINT, bg=INK, font=F_TINY,
                 anchor='w', justify='left', wraplength=540).pack(fill='x', pady=(8, 0))
        st['stats_build'] = build
        build()
        win.bind('<Escape>', lambda e: close_win())
        win.protocol('WM_DELETE_WINDOW', close_win)
        try: win.focus_force()
        except tk.TclError: pass
    st['actions'][stats_btn] = open_stats

    def click_through(on):
        """While a job runs the overlay stays visible but lets clicks pass through to the game."""
        try:
            import ctypes
            u = ctypes.windll.user32
            top = u.GetAncestor(root.winfo_id(), 2)
            ex = u.GetWindowLongW(top, -20)
            ex = (ex | 0x20 | 0x80000) if on else (ex & ~0x20)        # WS_EX_TRANSPARENT (+ layered)
            u.SetWindowLongW(top, -20, ex)
        except Exception:
            pass

    def host(send_only=False):
        if st.get('hosting'):                              # the button reads Stop while running
            STOP.set(); host_msg.config(text='Stopping...'); return
        cfg = load_settings()
        STOP.clear()
        st['hosting'] = True; watcher.pause = True; loadw.pause = True
        btn = host_btn
        st['btn_text'] = btn.cget('text'); btn.config(text='\u25A0 Stop', bg=RED)
        host_msg.config(text='Running... keep your hands off the mouse for a moment.')
        def say(t): root.after(0, lambda: host_msg.config(text=t))
        def done(ok):
            def fin():
                st['hosting'] = False; watcher.pause = False; loadw.pause = False
                btn.config(text=st.get('btn_text', btn.cget('text')), bg=GOLD)
            root.after(0, fin)
        job = HostInvite(strings, cfg, say, done, True) if send_only else RankedParty(strings, cfg, say, done)
        root.after(150, job.start)
    st['actions'][host_btn] = host

    def show_opponents(players):
        for w in opp_area.winfo_children(): w.destroy()
        opp_area.grid_configure(pady=(0, 0))
        mine = next((p for p in players if p['human'] and p['profile'] == me), None)
        opps = [p for p in players if p is not mine and (mine is None or p['team'] <= 1 or p['team'] != mine['team'])]
        team_game = len(players) > 2
        if opps:
            opp_area.grid_configure(pady=(10, 0))
            cap = tk.Label(opp_area, text='OPPONENT' + ('S' if len(opps) > 1 else ''), fg=BRONZE, bg=BG,
                           font=(DISPLAY, 8, 'bold'), anchor='w')
            cap.grid(row=0, column=0, sticky='w'); bind_all(cap)
        for i, p in enumerate(opps):
            name, text = civ_text(p['civ'], strings, icons)
            info = {'elo': ''}
            tone = name_colour(p.get('colour'), RED)        # their own player colour, lifted to read
            head = tk.Label(opp_area, text='', fg=tone, bg=BG, font=F_HEAD, anchor='w', cursor='hand2')
            det = tk.Label(opp_area, text=text, fg='#cfc8b6', bg=BG, font=F_SMALL, anchor='w', justify='left', wraplength=415)
            # how this player has actually been opening, filled in once their recent games are read
            opn = tk.Label(opp_area, text='', fg=FAINT, bg=BG, font=F_SMALL, anchor='w', justify='left', wraplength=415)
            head.grid(row=3 * i + 1, column=0, sticky='w', pady=(4, 1)); det.grid(row=3 * i + 3, column=0, sticky='w', padx=(14, 0))
            opn.grid(row=3 * i + 2, column=0, sticky='w', padx=(14, 0)); opn.grid_remove()
            hover(head, tone, lighten(tone, 0.35))
            det.grid_remove()                                             # starts collapsed
            def label(h=head, dt=det, nm=name, pn=p['name'], inf=info):
                arrow = '\u25BE ' if dt.winfo_manager() else '\u25B8 '
                h.config(text=arrow + '%s  (%s)%s' % (nm, pn, ('   ' + inf['elo']) if inf['elo'] else ''))
            label()
            def flip(dt=det, lb=label):
                toggle(dt); lb()
            st['actions'][head] = flip
            bind_all(head); bind_all(det)
            if p.get('human'):
                def look(pp=p, inf=info, lb=label):
                    inf['elo'] = elo_text(fetch_elo(pp.get('profile') or None, pp['name']), team_game)
                    try: root.after(0, lb)
                    except Exception: pass
                threading.Thread(target=look, daemon=True).start()
                def habits(pp=p, lab_=opn):
                    def show(txt, col):
                        try:
                            lab_.config(text=txt, fg=col); lab_.grid(); bind_all(lab_)
                        except Exception: pass                           # a new game has replaced this row
                    def post(fn):
                        for _ in range(40):
                            try: root.after(0, fn); return
                            except RuntimeError: time.sleep(0.25)        # the window is still starting up
                    try:
                        post(lambda: show('Reading their recent games...', FAINT))
                        rows = opponent_openings(pp['profile'], 'TG' if team_game else '1v1',
                                                 5 if team_game else OPEN_GAMES)
                        lines = openings_lines(rows, pp['civ'], strings)
                        post(lambda: show('\n'.join(lines) if lines else 'No recent recorded games to read.',
                                          '#e6d9b0' if lines else FAINT))
                    except Exception as e:
                        log('openings lookup failed: %r' % (e,))
                if pp_ok(p, i): threading.Thread(target=habits, daemon=True).start()

    def pp_ok(p, i):
        return bool(p.get('profile')) and i < 4 and load_settings().get('opp_openings', True)

    def refresh():
        if st['first'] is None: return
        txt = herd_line(st['first'], st['herd'], watcher.found, st['extra'])
        txt = re.sub(r'Relics (\d+(?:-\d+)?)', lambda m: 'Relics %d of %s' % (watcher.relics, m.group(1)), txt, count=1)
        if 'Relics vary' in txt and watcher.relics: txt = txt.replace('Relics vary', 'Relics %d picked up' % watcher.relics)
        if st['herd'] and watcher.status == 'setting up': txt += '\n(herd tracking: setting up, first run only)'
        elif st['herd'] and watcher.status == 'unavailable': txt += '\n(herd tracking unavailable)'
        if body.cget('text') != txt: body.config(text=txt)

    def fast():
        refresh(); hover_fade()
        try: castle_reminder()
        except Exception as e: log('reminder: %r' % (e,))
        root.after(500, fast)

    def tick():
        try:
            f = newest_replay()
            if f is not None and f == st.get('ended'): f = None     # that game is over (end screen seen)
            if f is None:
                if st['last'] is not None:
                    st['last'] = None; st['first'] = None; st['herd'] = None; watcher.active = False
                    tcw.active = False
                    scout.active = False; scout.stop_game(); score_off()
                    title.config(text=APP_NAME); idle_size(True)
                    state.config(text='WAITING', fg=MUT)
                    rec_line.config(text=''); rec_line.grid_remove(); show_footer(True)
                    stats_btn.grid()
                    show_opponents([])
            elif f != st['last']:
                lob = read_lobby(f); st['last'] = f
                if lob:
                    name, desc, herd = map_text(maps, strings, lob['selected'], lob['resolved'], lob.get('size'), len(lob['players']))
                    watcher.reset(); st['extra'] = 0
                    st['castle_note'] = False; game_started(f)
                    st['first'], st['herd'] = desc, herd
                    watcher.active = herd is not None
                    title.config(text=name); state.config(text='IN GAME', fg=GREEN)
                    idle_size(False); refresh()
                    show_footer(False)
                    show_opponents(lob['players'])
                    log_game_start(f, lob)
                    mine_p = (next((p for p in lob['players'] if p['human'] and p['profile'] == me), None)
                              or next((p for p in lob['players'] if p['human']), None))
                    try: began = os.path.getctime(f)             # when the game began, not when we noticed it
                    except OSError: began = None
                    tcw.reset(civ_name(mine_p['civ'], strings) if mine_p else None, began)
                    tc['snooze'] = False; tcw.active = mine_p is not None   # not while watching someone else
                    start_scout(lob['players'], mine_p, strings)
                    scorew.reset(([mine_p['name']] + list(mine)) if mine_p else [],
                                 [p['name'] for p in lob['players'] if p is not mine_p], len(lob['players']))
                    scorew.active = mine_p is not None                 # not while watching someone else
                    rec_line.config(text=''); rec_line.grid_remove()   # not while you are playing
                    hide_card()                                       # last game's result is history now
                    stats_btn.grid_remove()
        except Exception as e:
            body.config(text='Could not read the game settings: %s' % e)
        root.after(POLL_MS, tick)
    tick(); fast(); root.mainloop()

if __name__ == '__main__':
    main()
