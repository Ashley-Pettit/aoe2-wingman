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

VERSION = 'v165'
FROZEN = bool(getattr(sys, 'frozen', False))   # the Wingman.exe build: everything bundled, no pip, no .bat

def clean_env():
    """A copy of the environment fit to start another Wingman.exe with. The exe unpacks itself into
    a temp folder and points some variables at it (the certificate file, PyInstaller's own); a new
    exe started from this one must not inherit those, because that folder goes when this one exits."""
    env = dict(os.environ)
    tmp = getattr(sys, '_MEIPASS', None)
    for k in list(env):
        v = env[k]
        if k.upper() == 'PATH' and tmp:                  # keep the path, minus this exe's temp folder
            env[k] = os.pathsep.join(p_ for p_ in str(v).split(os.pathsep) if tmp.lower() not in p_.lower())
        elif k.startswith('_PYI') or k.startswith('_MEIPASS') or (tmp and tmp.lower() in str(v).lower()):
            env.pop(k, None)
    env['PYINSTALLER_RESET_ENVIRONMENT'] = '1'           # tell the new exe it is a fresh start, not a child
    return env

def start_fresh_exe(path_, *args):
    """Start another Wingman.exe as its own program, sharing nothing with this one. The exe's loader
    points Windows' DLL search at its temp folder, and a program started from it inherits that: the
    new copy then loads files out of the old one's temp folder, and the old one cannot clear it up
    when it closes (that is the error box after an update). So undo that first."""
    import subprocess
    try:
        import ctypes
        ctypes.windll.kernel32.SetDllDirectoryW(None)
    except Exception:
        pass
    return subprocess.Popen([path_] + list(args), close_fds=True, env=clean_env(),
                            cwd=os.path.dirname(path_) or None,
                            creationflags=0x00000008 | 0x00000200)     # DETACHED_PROCESS, new process group

if FROZEN:
    # A certificate path that points nowhere (left over from another exe's temp folder, say) makes
    # every web lookup fail with 'No such file or directory'. Drop it and use Windows' own.
    for _k in ('SSL_CERT_FILE', 'SSL_CERT_DIR', 'REQUESTS_CA_BUNDLE'):
        _v = os.environ.get(_k)
        if _v and not os.path.exists(_v): os.environ.pop(_k, None)
APP_NAME = 'AoE2 Wingman'
HOME = os.path.expanduser('~')
GAMES = os.path.join(HOME, 'Games', 'Age of Empires 2 DE')
POLL_MS = 3000
FRESH_S = 30        # a recording that has added nothing for this long is not a game in progress

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

# One short line per civ: how it opens, then what comes later. Common ranked habits, not a
# rulebook. Kept to a line you can read at a glance mid game.
OPENINGS = {
 'Britons': 'Archers into Crossbows and Longbows. Outranges you late.',
 'Franks': 'Scouts or MAA into fast Knights.',
 'Goths': 'Scouts or drush, then infantry spam. Weak early, scary late.',
 'Teutons': 'MAA or scouts, towers, then Knights and Teutonic Knights.',
 'Japanese': 'MAA into archers, or fast Castle. Strong fishing.',
 'Chinese': 'Scouts or archers. Slow first minutes, then fast.',
 'Byzantines': 'Cheap Skirms, Spears and Camels. Towers and trash.',
 'Persians': 'Scouts into Knights or Elephants. Strong TCs, TC pushes.',
 'Saracens': 'Archers or MAA, Market tricks. Camels and Mamelukes.',
 'Turks': 'Scouts or fast Castle into gunpowder. Free Hussar.',
 'Vikings': 'MAA or archers, strong eco. Infantry later.',
 'Mongols': 'Scouts into Mangudai or Cav Archers. Onagers late.',
 'Celts': 'Scouts or MAA. Woad Raiders and siege later.',
 'Spanish': 'Scouts or MAA into Conquistadors. Forward towers, castles.',
 'Aztecs': 'MAA or Eagle rush, then Monks and Jaguars. No cavalry.',
 'Maya': 'Archers or Eagle rush. Plumed Archers later. Strong eco.',
 'Huns': 'Scouts every game. Cav Archer and Tarkan raids.',
 'Koreans': 'Archers or towers. War Wagons and Onagers later.',
 'Italians': 'Archers or fast Castle. Genoese Crossbows vs cavalry.',
 'Hindustanis': 'Scouts or archers. Camels, Ghulams, Hand Cannoneers.',
 'Inca': 'Eagle or MAA rush, villagers fight back. Kamayuks, Slingers.',
 'Magyars': 'Scouts into Magyar Huszars or Cav Archers.',
 'Slavs': 'Scouts or MAA, strong farms. Boyars and siege.',
 'Portuguese': 'Archers or fast Castle. Organ Guns, strong navy.',
 'Ethiopians': 'Archers. Shotel Warriors and Torsion Engines.',
 'Malians': 'Scouts or MAA. Gbetos and Farimba cavalry.',
 'Berbers': 'Scouts or fast Castle into Camel Archers, Genitours.',
 'Khmer': 'Scouts, then fast Castle or Elephants.',
 'Malay': 'Archers or fast Imperial boom. Karambits, cheap Elephants.',
 'Burmese': 'Scouts or MAA. Arambai and Battle Elephants.',
 'Vietnamese': 'Archers, and they see where you start. Rattan Archers.',
 'Bulgarians': 'MAA or scouts, free militia upgrades. Konniks, Kreposts.',
 'Tatars': 'Scouts or archers. Keshiks and Cav Archers.',
 'Cumans': 'Scouts, often a second Feudal TC. Cav Archers, Kipchaks.',
 'Lithuanians': 'Scouts into Knights. Leitis, relic-boosted cavalry.',
 'Burgundians': 'Scouts or fast Castle, early Cavalier. Coustilliers.',
 'Sicilians': 'Scouts or MAA. Donjons and Serjeants.',
 'Poles': 'Scouts or fast Castle into Szlachta cavalry. Obuch infantry.',
 'Bohemians': 'Monks and gunpowder. Hussite Wagons, Houfnice.',
 'Dravidians': 'Archers or MAA. Urumi and Skirms. No Knights.',
 'Bengalis': 'Archers or elephants. Ratha, Elephant Archers.',
 'Gurjaras': 'Scouts or MAA. Chakrams, Shrivamsha riders, Camels.',
 'Romans': 'MAA or scouts into Legionaries, Centurions. Scorpions late.',
 'Armenians': 'MAA or archers. Composite Bowmen.',
 'Georgians': 'Scouts or MAA. Monaspa cavalry. Strong on hills.',
 'Achaemenids': None,
 'Athenians': None,
 'Spartans': None,
 'Shu': 'Archers. War Chariots and Crossbows.',
 'Wu': 'Scouts or archers. Fire Archers, strong navy.',
 'Wei': 'Scouts. Tiger Cavalry and Xianbei Raiders.',
 'Jurchens': 'Scouts or archers. Grenadiers, Iron Pagoda cavalry.',
 'Khitans': 'Pastures, not farms. Mounted Archers, Liao Dao infantry.',
 'Macedonians': None,
 'Thracians': None,
 'Puru': None,
 'Muisca': None,
 'Mapuche': None,
 'Tupi': None,
 'Saxons': 'Infantry and defence: towers, Castles, Hearth Troops.',
 'Varangians': 'Scouts into Knights and Varangian Guards. Jarls vs infantry.',
 'Danes': 'Infantry and siege: Varangian Guards, cheap Jomsvikings.',
}

# ---------------------------------------------------------------- build orders
# Villager counts and tasks taken from Hera's published strategy guide (December 2025 edition),
# which is the current standard: food first and wood later, far fewer villagers before clicking
# up than the old 22 pop builds. The steps are written out here in short form for reading mid
# game. Numbers shift with your civ, the map and your start, so this is the shape, not a script.
BUILD_SOURCE = "Hera's strategy guide, Dec 2025"
# (group, name, what it lands on, steps). Steps are (first pop, last pop, what to do). Pop is
# villagers plus the scout, plus any militia, which is how players and the in-game counter count.
BUILDS = [
 ('Scouts', 'Scouts, one stable', '19 pop, Feudal 8:50', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 9,   '2 to wood'),
   (10, 10, 'Lure the first boar'),
   (11, 11, 'Build a house, then a mill at the berries'),
   (12, 17, '6 to the boar, one lures the second'),
   (18, 18, '2 to wood. Lure deer with the scout'),
   (19, 19, 'Second one to wood. Loom, then click Feudal (up at 8:50)'),
   (20, 99, 'Barracks then stable, 3 scouts, double bit axe')]),
 ('Scouts', 'Scouts, two stables', '19 pop, Feudal 8:50', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 9,   '2 to wood'),
   (10, 10, 'Lure the first boar'),
   (11, 11, 'Build a house, then a mill at the berries'),
   (12, 17, '6 to the boar. Lure deer with the scout'),
   (18, 18, '2 to wood'),
   (19, 19, 'Second one to wood. Loom, then click Feudal (up at 8:50)'),
   (20, 99, 'Barracks, then two stables, double bit axe')]),
 ('Scouts', 'Scouts into archers', '19 pop, Feudal 8:50', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 9,   '2 to wood'),
   (10, 10, 'Lure the first boar'),
   (11, 11, '1 more to the boar'),
   (12, 12, 'Build a house, then a mill at the berries'),
   (13, 13, 'Lure the second boar'),
   (14, 18, '6 to the boar'),
   (19, 19, 'Sixth one hunts. Loom, then click Feudal (up at 8:50)'),
   (20, 99, '6 to wood until 8 on one camp, 4 berries, barracks, double bit axe')]),
 ('Archers', 'Archers, one range', '20 pop, Feudal 9:15', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 10,  '3 to wood'),
   (11, 11, 'Lure the first boar'),
   (12, 12, 'Build a house, then a mill at the berries'),
   (13, 18, '6 to the boar, one lures the second'),
   (19, 19, '2 to wood. Lure deer with the scout'),
   (20, 20, 'Second one to wood. Loom, then click Feudal (up at 9:15)'),
   (21, 99, '5 hunt to a second lumber camp, 2 berries, 3 gold, range up')]),
 ('Infantry', 'Men-at-arms', '19 pop, Feudal 8:50', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 10,  '3 to wood, one builds a house in the wall'),
   (11, 11, 'Lure the first boar. Lure 2 deer, not optional'),
   (12, 16, '5 to the boar, lure the second one'),
   (17, 17, 'Barracks, then a house at the front. No mill yet'),
   (18, 18, '2 more to the boar'),
   (19, 19, 'Second one hunts. Loom, then click Feudal (up at 8:50)'),
   (20, 99, '5 hunt to wood, 2 gold camp, 1 berries, 3 militia out')]),
 ('Infantry', 'Men-at-arms into skirms', '20 pop, Feudal 9:15', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 10,  '3 to wood'),
   (11, 11, 'Lure the first boar'),
   (12, 12, 'Build a house, then a mill at the chickens or berries and gather'),
   (13, 14, '2 more to the berries. Lure a deer or two if you can'),
   (15, 15, 'Lure the second boar'),
   (16, 17, '2 to the boar'),
   (18, 18, 'Barracks, then a house at the front'),
   (19, 19, '2 more to the boar'),
   (20, 20, 'Second one hunts. Loom, then click Feudal (up at 9:15)'),
   (21, 99, 'Militia out, skirms behind them')]),
 ('Infantry', 'Feudal drush', '19 pop, Feudal 8:50', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 10,  '3 to wood'),
   (11, 11, 'Lure the first boar'),
   (12, 12, 'House, then back to the hunt'),
   (13, 16, '4 to the boar, lure the second one'),
   (17, 17, 'Barracks out front, house beside it. No mill yet'),
   (18, 18, '1 more to the boar'),
   (19, 19, '1 to wood. Loom, then click Feudal (up at 8:50)'),
   (20, 99, 'Militia out, 1 more to the berries')]),
 ('Fast Castle', 'Fast Castle boom', '24 pop, Castle 14:00', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 10,  '3 to wood'),
   (11, 11, 'Lure the first boar'),
   (12, 12, 'Build a house, then a mill at the berries'),
   (13, 14, '2 to the boar, one lures the second. Lure 3 deer'),
   (15, 18, '4 to berries, seed 3 farms off the hunt'),
   (19, 22, '4 to wood'),
   (23, 23, '2 to gold'),
   (24, 24, 'Second one to gold. Click Feudal, no loom (up at 10:30)'),
   (25, 26, 'Feudal is in: 2 more to wood, market and blacksmith'),
   (27, 99, 'Click Castle as soon as both are up (in at 14:00)')]),
 ('Fast Castle', 'Drush into Fast Castle', '31 pop, Castle 16:05', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 11,  '4 to wood'),
   (12, 12, 'Lure the first boar'),
   (13, 13, '2 houses, then a barracks'),
   (14, 17, '1 to gold, then back to the boar. 3 militia out'),
   (18, 18, 'Lure the second boar'),
   (19, 23, '5 to berries, one builds a mill there'),
   (24, 27, '4 to wood on one camp, then loom'),
   (28, 30, '4 to gold'),
   (31, 31, 'Fourth one to gold. Click Feudal (up at 12:35)'),
   (32, 33, 'Feudal is in: 2 more to gold, range and blacksmith'),
   (34, 99, 'Click Castle, keep the militia busy (in at 16:05)')]),
 ('Fast Castle', 'Knight rush (easier)', '26 pop, Castle 16:05', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 10,  '3 to wood'),
   (11, 11, 'Lure the first boar'),
   (12, 12, 'Build 2 houses, then a mill at the berries'),
   (13, 13, '1 more to the boar'),
   (14, 14, 'Lure the second boar'),
   (15, 18, '4 to berries'),
   (19, 23, '5 to wood'),
   (24, 25, 'A house, then 3 to gold'),
   (26, 26, 'Third one to gold. Loom, then click Feudal (up at 11:45). Barracks and a house'),
   (27, 99, 'Stable and market, 4 more to gold, click Castle (in at 16:05)')]),
 ('Scouts', 'Scouts into skirms', '19 pop, Feudal 8:50', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 9,   '2 to wood'),
   (10, 10, 'Lure the first boar'),
   (11, 11, '1 more to the boar'),
   (12, 12, 'Build a house, then a mill at the berries'),
   (13, 13, 'Lure the second boar'),
   (14, 18, '6 to the boar. Lure deer with the scout'),
   (19, 19, 'Sixth one hunts. Loom, then click Feudal (up at 8:50)'),
   (20, 99, '6 to wood until 8 on one camp, 4 berries, barracks and house')]),
 ('Infantry', 'Double barracks eagles', '19 pop, Feudal 8:50', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 9,   '2 to wood'),
   (10, 10, 'Lure the first boar'),
   (11, 11, '1 more to the boar'),
   (12, 12, 'Build a house, then a mill at the berries'),
   (13, 13, 'Lure the second boar'),
   (14, 18, '6 to the boar. Lure deer with the scout'),
   (19, 19, 'Sixth one hunts. Loom if Aztecs or Incas, then click Feudal (up at 8:50)'),
   (20, 99, '5 to wood for 7 on one camp, 2 gold, barracks and house, 3 berries')]),
 ('Other', 'Tower rush, any civ', '18 pop, Feudal 8:25', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 9,   '2 to wood'),
   (10, 10, 'Lure the first boar'),
   (11, 11, '1 more to the boar'),
   (12, 12, 'Build a house, then a mill at the berries'),
   (13, 13, 'Lure the second boar'),
   (14, 17, '5 to the boar'),
   (18, 18, 'Fifth one hunts. Loom, scout them, then click Feudal (up at 8:25)'),
   (19, 99, '2 to stone with a camp, 5 forward, spears or skirms behind the towers')]),
 ('Other', 'Teuton tower rush', '18 pop, Feudal 8:25', [
   (2, 7,   '2 houses, then 6 to sheep'),
   (8, 9,   '2 to wood'),
   (10, 10, 'Lure the first boar'),
   (11, 11, '1 more to the boar'),
   (12, 12, 'Build a house, then a mill at the berries'),
   (13, 13, 'Lure the second boar'),
   (14, 17, '5 to the boar'),
   (18, 18, 'Fifth one hunts. Loom, scout them, then click Feudal (up at 8:25)'),
   (19, 99, '2 to stone with a camp, 10 forward, tower 8 tiles off their wood')]),
]

BUILD_GROUPS = ['Scouts', 'Archers', 'Infantry', 'Fast Castle', 'Other']
BUILDS.sort(key=lambda b: BUILD_GROUPS.index(b[0]) if b[0] in BUILD_GROUPS else 99)

# ---- pictures for the build steps, drawn here so they need no files
STEP_ICON_WORDS = [            # first word found in the step picks the picture
    ('click feudal', 'age'), ('click castle', 'age'),
    ('sheep', 'sheep'), ('boar', 'boar'), ('hunt', 'boar'), ('deer', 'deer'),
    ('berries', 'berries'), ('farm', 'berries'), ('mill', 'berries'),
    ('wood', 'wood'), ('gold', 'gold'), ('stone', 'stone'),
    ('house', 'house'), ('tower', 'tower'),
    ('militia', 'sword'), ('scouts', 'horse'), ('stable', 'horse'), ('knight', 'horse'),
    ('range', 'bow'), ('archer', 'bow'), ('skirm', 'bow'),
    ('barracks', 'sword'), ('loom', 'loom'), ('market', 'tower'), ('blacksmith', 'tower'),
]

def step_icon_kind(text):
    t = (text or '').lower(); best = None
    # 'Build a house, then ...': the house is a quick job on the way; the picture is for what
    # the villager ends up doing
    t = re.sub(r'^(build )?(a|\d+|\w+) houses?(,| first,)? then ', '', t)
    for word, kind in STEP_ICON_WORDS:
        if word in ('click feudal', 'click castle') and word in t: return kind
        i = t.find(word)
        if i >= 0 and (best is None or i < best[0]): best = (i, kind)
    return best[1] if best else None

def draw_build_badge(S, bg, hot=False):
    """The build order's own mark: a royal blue shield with a gold rim and a cream serif B.
    Blue so it never gets mixed up with the gold party invite button next to it."""
    from PIL import Image, ImageDraw, ImageFont
    k = 4; W = int(S * 0.86); N, M = W * k, S * k
    im = Image.new('RGBA', (N, M), bg)
    d = ImageDraw.Draw(im)
    def shield(inset):
        i = inset * k; w, h = N - 1 - i, M - 1 - i
        return [(i, i + 2 * k), (N / 2.0, i), (w, i + 2 * k), (w, h * 0.58), (N / 2.0, h), (i, h * 0.58)]
    d.polygon(shield(0), fill='#e2b84a' if hot else '#c99a2e')                 # gold rim
    d.polygon(shield(1.6), fill='#1d2f52')                                     # dark edge inside the rim
    d.polygon(shield(2.3), fill='#3d68b8' if hot else '#2f569c')               # royal blue face
    # a lighter top half for a bit of shine
    sh = shield(2.3); top = [sh[0], sh[1], sh[2], (sh[2][0], M * 0.36), (sh[0][0], M * 0.36)]
    d.polygon(top, fill='#4a7bcf' if hot else '#3a66b3')
    font = None
    for f in ('georgiab.ttf', 'timesbd.ttf', 'DejaVuSerif-Bold.ttf', 'arialbd.ttf'):
        try: font = ImageFont.truetype(f, int(M * 0.56)); break
        except Exception: continue
    if font is None: font = ImageFont.load_default()
    bb = d.textbbox((0, 0), 'B', font=font)
    tx = (N - (bb[2] - bb[0])) / 2.0 - bb[0]; ty = (M * 0.86 - (bb[3] - bb[1])) / 2.0 - bb[1]
    d.text((tx + k * 0.6, ty + k * 0.8), 'B', font=font, fill='#0f1a30')       # a soft drop shadow
    d.text((tx, ty), 'B', font=font, fill='#f4ead2')
    return im.resize((W, S), Image.LANCZOS).convert('RGB')

def draw_step_icon(kind, S, bg):
    """kind drawn in an S x S square, 4x then shrunk. Returns a PIL RGB image."""
    from PIL import Image, ImageDraw
    k = 4; N = S * k; u = N / 32.0
    im = Image.new('RGBA', (N, N), bg)
    d = ImageDraw.Draw(im)
    def P(*pts): return [(x * u, y * u) for x, y in pts]
    def E(x0, y0, x1, y1, **kw): d.ellipse((x0 * u, y0 * u, x1 * u, y1 * u), **kw)
    def R(x0, y0, x1, y1, r=0, **kw): d.rounded_rectangle((x0 * u, y0 * u, x1 * u, y1 * u), radius=r * u, **kw)
    def L(pts, w, fill): d.line(P(*pts), fill=fill, width=max(1, int(w * u)), joint='curve')
    if kind == 'sheep':                   # side on: dark face and ear, fluffy body, four legs
        wool, shade, face, leg = '#f6efdd', '#cfc3a6', '#6b5646', '#9c8a74'
        for x in (13, 18, 23, 27): R(x - 1.5, 18, x + 1.5, 30, 1.4, fill=leg)
        for x, y, r in ((13, 13, 5.2), (19, 10.5, 5.6), (25, 12, 5.2), (28.5, 17, 4.2), (24, 21.5, 5),
                        (18, 22, 5), (12.5, 19.5, 4.6), (19, 16, 7)):
            E(x - r, y - r, x + r, y + r, fill=shade)
        for x, y, r in ((13, 12.5, 4.8), (19, 10, 5.2), (25, 11.5, 4.8), (28, 16.5, 3.8), (24, 20.5, 4.6),
                        (18, 21, 4.6), (12.5, 19, 4.2), (19, 15.5, 6.6)):
            E(x - r, y - r, x + r, y + r, fill=wool)
        E(0.5, 9, 11.5, 21, fill=face); E(7, 6, 12.5, 11.5, fill=face)
        E(3.2, 12.4, 5.4, 14.6, fill=wool); E(7.5, 7.5, 13.5, 13.5, fill=wool)
    elif kind == 'boar':                  # side on, facing left: bristly back, long snout, white tusk
        body, dark, snout, ridge = '#94633f', '#4a3220', '#b07a50', '#3a281a'
        for x in (12, 16.5, 23, 27): R(x - 1.5, 21, x + 1.5, 29.5, 1, fill=dark)          # short legs
        L([(29.5, 14), (31, 12), (30.5, 10.5)], 1.2, dark)                                  # tail
        E(9, 8.5, 30.5, 25, fill=body)                                                      # barrel body
        d.polygon(P((13, 9.5), (4, 14.5), (1.5, 18), (3.5, 21.5), (14, 24)), fill=body)      # head, tapering
        d.polygon(P((10, 15.5), (3, 17), (3.5, 21.5), (12, 23)), fill=snout)                # lighter snout
        E(0.3, 16.2, 4, 21.6, fill='#c08a66')                                               # nose disc
        E(1.2, 17.6, 2.2, 18.8, fill=dark); E(1.8, 19.4, 2.8, 20.6, fill=dark)              # nostrils
        # the bristly ridge along the back
        d.polygon(P((10, 10), (12, 6.5), (14, 9), (16, 5.5), (18, 8.5), (20.5, 5.5), (22.5, 8.5),
                    (25, 6.5), (26.5, 9.5), (29, 9), (29, 12), (10, 13)), fill=ridge)
        d.polygon(P((10.5, 10.5), (12, 4.5), (15, 10)), fill=dark)                           # ear
        E(7.4, 13.2, 9.8, 15.6, fill='#1a120c'); E(8.4, 13.6, 9.2, 14.4, fill='#e8dcc0')    # eye
        d.arc((2 * u, 13 * u, 10 * u, 23 * u), 115, 220, fill='#f6efdf', width=max(1, int(2.2 * u)))       # tusk
    elif kind == 'deer':
        body, dark = '#b98a55', '#6e4f2e'
        E(8, 12, 27, 22, fill=body)
        d.polygon(P((10, 15), (6, 7), (9, 6), (13, 13)), fill=body)
        E(3, 5, 10, 10, fill=body)
        L([(7, 6), (5, 1), (3, 2)], 1.4, dark); L([(8, 6), (10, 1), (12, 2)], 1.4, dark)
        for x in (11, 15, 21, 25): R(x - 1, 20, x + 1, 29, 1, fill=dark)
    elif kind == 'berries':
        E(3, 8, 29, 29, fill='#3f6b33'); E(6, 5, 20, 19, fill='#4d7d3c')
        for x, y in ((10, 14), (17, 12), (22, 18), (13, 21), (19, 24), (25, 23), (8, 22)):
            E(x - 2.6, y - 2.6, x + 2.6, y + 2.6, fill='#c0485a')
    elif kind == 'wood':
        bark, end, ring = '#8a5c38', '#e2bb82', '#a8784a'
        for x, y in ((0, 16), (16, 16), (8, 2)):              # three big logs, ends towards you
            R(x, y, x + 16, y + 14, 6, fill=bark)
            E(x + 3, y + 0.5, x + 16, y + 13.5, fill=end)
            E(x + 6.5, y + 4, x + 12.5, y + 10, fill=ring)
            E(x + 8.5, y + 6, x + 10.5, y + 8, fill=bark)
    elif kind == 'gold':
        for pts, c in ((((3, 27), (9, 15), (17, 20), (14, 28)), '#c99a2e'),
                       (((12, 28), (17, 13), (27, 17), (29, 28)), '#e2b84a'),
                       (((8, 18), (13, 6), (21, 10), (18, 19)), '#f0d27a')):
            d.polygon(P(*pts), fill=c)
    elif kind == 'stone':
        for pts, c in ((((2, 28), (6, 16), (15, 13), (18, 28)), '#8d8a84'),
                       (((13, 28), (17, 10), (27, 12), (30, 28)), '#b3afa7'),
                       (((7, 17), (11, 7), (19, 8), (17, 16)), '#cfcac0')):
            d.polygon(P(*pts), fill=c)
    elif kind == 'house':
        d.polygon(P((3, 15), (16, 4), (29, 15)), fill='#a0503a')
        R(6, 14, 26, 29, 1, fill='#d9c39a'); R(13, 19, 19, 29, 1, fill='#5a3d28')
    elif kind == 'tower':
        R(9, 9, 23, 30, 1, fill='#b3afa7')
        for x in (8, 14, 20): R(x, 4, x + 4, 10, 0.5, fill='#b3afa7')
        R(14, 14, 18, 20, 2, fill='#3a3128')
    elif kind == 'sword':
        d.polygon(P((10, 19.5), (25.5, 4), (28.5, 3.5), (28, 6.5), (12.5, 22)), fill='#cfc9bf')   # blade
        L([(11.2, 20.8), (27, 5)], 1.0, '#f4f1ea')                                                  # its edge
        L([(6.5, 16), (16, 25.5)], 3.2, '#c99a2e')                                                  # crossguard
        L([(5, 27), (10, 22)], 3.4, '#7a5236')                                                      # grip
        E(2, 26, 6.6, 30.6, fill='#c99a2e')                                                         # pommel
    elif kind == 'bow':
        d.arc((2 * u, 3 * u, 22 * u, 29 * u), 290, 70, fill='#b98a55', width=int(3 * u))
        L([(9, 4), (9, 28)], 1, '#efe6d2'); L([(9, 16), (29, 16)], 1.6, '#d9d4cc')
        d.polygon(P((29, 16), (25, 13.5), (25, 18.5)), fill='#d9d4cc')
    elif kind == 'horse':
        body = '#9a6a45'
        E(9, 11, 28, 22, fill=body)
        d.polygon(P((12, 14), (6, 4), (10, 2), (16, 13)), fill=body)
        d.polygon(P((6, 4), (1, 9), (3, 11), (8, 8)), fill=body)
        L([(9, 3), (14, 12)], 2, '#3a3128')
        for x in (12, 16, 22, 26): R(x - 1.2, 20, x + 1.2, 29, 1, fill='#5a3d28')
    elif kind == 'loom':
        d.polygon(P((16, 3), (28, 7), (26, 19), (16, 29), (6, 19), (4, 7)), fill='#a9823c')
        d.polygon(P((16, 7), (24, 10), (22, 18), (16, 25), (10, 18), (8, 10)), fill='#d8b253')
    elif kind in ('sound_on', 'sound_off'):      # the build order's voice: a speaker, waves or a cross
        on = kind == 'sound_on'
        col = '#d8b253' if on else '#7d7466'
        R(3, 12, 10, 20, 1, fill=col)
        d.polygon(P((9, 12), (17, 5), (17, 27), (9, 20)), fill=col)
        if on:
            for r in (6, 11):
                d.arc(((17 - r) * u, (16 - r) * u, (17 + r) * u, (16 + r) * u), -48, 48,
                      fill=col, width=max(1, int(2.6 * u)))
        else:
            L([(21, 11), (29, 21)], 2.6, col); L([(29, 11), (21, 21)], 2.6, col)
    elif kind == 'age':
        E(2, 2, 30, 30, fill='#d8b253'); E(4.5, 4.5, 27.5, 27.5, fill='#2a2116')
        d.polygon(P((16, 7), (24, 16), (19, 16), (19, 25), (13, 25), (13, 16), (8, 16)), fill='#f0d796')
    return im.resize((S, S), Image.LANCZOS).convert('RGB')

STEP_ICONS = {}
def step_icon(text, S, bg, pad=6):
    """A small picture for a build step (a sheep for the sheep, logs for wood, the age arrow for
    clicking up), with `pad` of panel colour on its right so it sits off the words. None when
    nothing fits or Pillow is missing."""
    kind = step_icon_kind(text)
    if not kind: return None
    key = (kind, S, bg, pad)
    if key not in STEP_ICONS:
        try:
            from PIL import Image, ImageTk
            im = Image.new('RGB', (S + pad, S), bg)
            im.paste(draw_step_icon(kind, S, bg), (0, 0))
            STEP_ICONS[key] = ImageTk.PhotoImage(im)
        except Exception:
            STEP_ICONS[key] = None
    return STEP_ICONS[key]

_CUSTOM = {'t': 0, 'v': []}

def rows_to_steps(rows):
    """[[pop, text], ...] as typed into Settings -> the (first pop, last pop, text) steps the strip uses."""
    clean_ = sorted((int(p_), str(t_).strip()) for p_, t_ in rows if str(t_).strip())
    out = []
    for k, (p_, t_) in enumerate(clean_):
        nxt = clean_[k + 1][0] if k + 1 < len(clean_) else None
        out.append((p_, 99 if nxt is None else max(p_, nxt - 1), t_))
    return out

def custom_builds(fresh=False):
    """Your own build orders from Settings, in the same shape as the built-in ones."""
    if fresh or time.time() - _CUSTOM['t'] > 5:
        got = []
        for b in load_settings().get('custom_builds') or []:
            try:
                steps = rows_to_steps(b.get('steps') or [])
                if b.get('name') and steps:
                    got.append(('Yours', b['name'], (b.get('goal') or '').strip() or 'your build', steps))
            except Exception:
                continue
        _CUSTOM.update(t=time.time(), v=got)
    return _CUSTOM['v']

def all_builds():
    return custom_builds() + BUILDS                     # yours first, then Hera's

def build_by_name(name):
    for _g, n, pop, steps in all_builds():
        if n == name: return n, pop, steps
    return None

def build_step_at(steps, pop):
    """Which step you are up to at this pop, as an index: the last one that has started."""
    at = 0
    for i, (lo, _hi, _t) in enumerate(steps):
        if pop >= lo: at = i
    return at

# ---------------------------------------------------------------- the build order read out loud
VOICE_START_S = 7       # seconds into a game before the first step is read out, when the
                        # build leaves the opening houses unsaid (time for you to place them)

def voice_start_s(steps):
    """No wait when the first step itself says to build the houses: it can be said straight away."""
    try: first = (steps[0][2] if steps else '').lower()
    except Exception: first = ''
    return 1 if 'house' in first else VOICE_START_S
BO_DONE = 'Build order done. Now go kill your opponent.'
# Windows' own speech, in one quiet PowerShell that stays open for the whole session and reads a
# line at a time from Wingman, so each step is spoken straight away rather than after a slow start.
# An Australian voice if Windows has one, then British, then whatever the default is.
VOICE_PS = r"""
# Wingman's voice. Windows' newer voices (the ones the Narrator and Settings > Speech use) through
# the WinRT speech engine; the older desktop voices if that is not there. Lines come in on stdin
# and are read one after another, never cut off. '#voice:Name' picks a voice, '#list:path' writes
# the voices there.
$mode = 'sapi'
try {
  Add-Type -AssemblyName System.Runtime.WindowsRuntime
  $null = [Windows.Media.SpeechSynthesis.SpeechSynthesizer,Windows.Media.SpeechSynthesis,ContentType=WindowsRuntime]
  $asTask = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
      $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
      $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0].MakeGenericMethod(
      [Windows.Media.SpeechSynthesis.SpeechSynthesisStream])
  $syn = New-Object Windows.Media.SpeechSynthesis.SpeechSynthesizer
  $mode = 'winrt'
} catch { [Console]::Error.WriteLine("winrt voice not available: $_") }
if ($mode -eq 'sapi') {
  Add-Type -AssemblyName System.Speech
  $sp = New-Object System.Speech.Synthesis.SpeechSynthesizer
  try { $sp.SetOutputToDefaultAudioDevice() } catch {}
}
function Voices {
  if ($mode -eq 'winrt') { return @([Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices | ForEach-Object { "$($_.DisplayName)|$($_.Language)" }) }
  return @($sp.GetInstalledVoices() | Where-Object { $_.Enabled } | ForEach-Object { "$($_.VoiceInfo.Name)|$($_.VoiceInfo.Culture.Name)" })
}
function Pick($want) {
  $all = Voices
  $hit = $null
  if ($want) { $hit = $all | Where-Object { $_.Split('|')[0] -eq $want } | Select-Object -First 1 }
  if (-not $hit) {
    foreach ($c in 'en-AU', 'en-GB', 'en-US') {
      $hit = $all | Where-Object { $_.Split('|')[1] -eq $c -and $_ -match 'Natural|Neural' } | Select-Object -First 1
      if ($hit) { break }
    }
  }
  if (-not $hit) {
    foreach ($c in 'en-AU', 'en-GB', 'en-US') {
      $hit = $all | Where-Object { $_.Split('|')[1] -eq $c } | Select-Object -First 1
      if ($hit) { break }
    }
  }
  if (-not $hit) { return }
  $name = $hit.Split('|')[0]
  try {
    if ($mode -eq 'winrt') { $syn.Voice = [Windows.Media.SpeechSynthesis.SpeechSynthesizer]::AllVoices | Where-Object { $_.DisplayName -eq $name } | Select-Object -First 1 }
    else { $sp.SelectVoice($name) }
    [Console]::Error.WriteLine("voice: $name ($mode)")
  } catch { [Console]::Error.WriteLine("could not pick $name : $_") }
}
$cache = @{}
function Make($t) {
  $st = $asTask.Invoke($null, @($syn.SynthesizeTextToStreamAsync($t))).Result
  $ns = [System.IO.WindowsRuntimeStreamExtensions]::AsStreamForRead($st)
  $ms = New-Object System.IO.MemoryStream
  $ns.CopyTo($ms); $ns.Dispose(); $st.Dispose()
  return ,$ms.ToArray()
}
function Prep($t) {
  if ($mode -ne 'winrt' -or $cache.ContainsKey($t)) { return }
  if ($cache.Count -gt 40) { $cache.Clear() }
  $cache[$t] = Make $t
}
function Say($t) {
  if ($mode -eq 'winrt') {
    if ($cache.ContainsKey($t)) { $b = $cache[$t] } else { $b = Make $t }
    $ms = New-Object System.IO.MemoryStream(,$b)
    $pl = New-Object System.Media.SoundPlayer($ms)
    $pl.PlaySync(); $pl.Dispose(); $ms.Dispose()
  } else { $sp.Speak($t) }
}
Pick $env:WINGMAN_VOICE
while ($true) {
  $l = [Console]::In.ReadLine()
  if ($l -eq $null) { break }
  if ($l.StartsWith('#voice:')) { Pick $l.Substring(7); $cache.Clear(); continue }
  if ($l.StartsWith('#list:')) { try { Voices | Set-Content -Path $l.Substring(6) -Encoding UTF8 } catch {}; continue }
  if ($l.StartsWith('#prep:')) { try { Prep $l.Substring(6) } catch { [Console]::Error.WriteLine("prep failed: $_") }; continue }
  if ($l.Trim()) { try { Say $l } catch { [Console]::Error.WriteLine("say failed: $_") } }
}
"""

def spoken_step(text):
    """A build step as something to say: '6 to sheep' becomes 'Send 6 to sheep',
    '5 hunt to wood' becomes 'Move 5 from hunt to wood', and so on."""
    t = text or ''
    for pat, to in ((r'^(\d+) (more )?hunts? to ', r'Move \1 \2from hunt to '),
                    (r'^(\d+) (more )?hunts?\b', r'Send \1 \2to hunt'),
                    (r'^(\d+) (more )?to ', r'Send \1 \2to '),
                    (r'^(\d+) houses\b', r'Build \1 houses')):
        t2 = re.sub(pat, to, t)
        if t2 != t: t = t2; break
    t = re.sub(r'\bthen (\d+) (more )?to ', r'then send \1 \2to ', t)
    t = re.sub(r'\s*\((?:up|in) at [\d:]+\)', '', t)         # the clock times are for reading, not for hearing
    t = re.sub(r'\bTC\b', 'town centre', t)
    t = re.sub(r'\bMAA\b', 'men at arms', t)
    t = re.sub(r'\b([Ll])ure(s|d)?\b', lambda m: ('Loor' if m.group(1) == 'L' else 'loor') + (m.group(2) or ''), t)   # said the way players say it
    t = re.sub(r'\s*\(', ', ', t).replace(')', '')
    return t.strip()

class Voice:
    """Reads lines out one after another, in order, never cutting one off. One quiet PowerShell for
    the whole session; it comes back by itself if it ever stops."""
    VOICE_LOG = os.path.join(GAMES if os.path.isdir(GAMES) else tempfile.gettempdir(), 'wingman_voice.log')
    def __init__(self):
        import queue
        self.p = None
        self.q = queue.Queue()
        self.worker = None
        self.lock = threading.Lock()
    def _start(self):
        import subprocess, base64
        ps = os.path.join(os.environ.get('SystemRoot', r'C:\Windows'), 'System32', 'WindowsPowerShell',
                          'v1.0', 'powershell.exe')
        if not os.path.exists(ps): ps = 'powershell'
        enc = base64.b64encode(VOICE_PS.encode('utf-16-le')).decode('ascii')
        env = clean_env(); env['WINGMAN_VOICE'] = str(load_settings().get('voice_name') or '')
        try:
            if getattr(self, 'err', None): self.err.close()
        except Exception: pass
        try:
            mode_ = 'a' if os.path.exists(self.VOICE_LOG) and os.path.getsize(self.VOICE_LOG) < 200000 else 'w'
            err = self.err = open(self.VOICE_LOG, mode_, encoding='utf-8')
        except OSError: err = subprocess.DEVNULL
        self.p = subprocess.Popen([ps, '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                                   '-EncodedCommand', enc], stdin=subprocess.PIPE,
                                  stdout=subprocess.DEVNULL, stderr=err,
                                  creationflags=0x08000000, env=env)
        log('voice: started')
    def _run(self):
        while True:
            line = self.q.get()
            for _ in range(2):
                try:
                    if self.p is None or self.p.poll() is not None: self._start()
                    if line is not None:
                        self.p.stdin.write((line + '\n').encode('ascii', 'replace')); self.p.stdin.flush()
                    break
                except Exception as e:
                    log('voice: %r' % (e,)); self.p = None
    def _put(self, line):
        with self.lock:                                # one reader for the queue, never two talking at once
            if self.worker is None or not self.worker.is_alive():
                self.worker = threading.Thread(target=self._run, daemon=True); self.worker.start()
        self.q.put(line)
    def say(self, text):
        line = re.sub(r'\s+', ' ', str(text or '')).strip()
        if line: self._put(line)
    def warm(self):
        """Start the speech engine ahead of time, so the first line is not late."""
        self._put(None)
    def prep(self, text):
        """Have a line spoken into memory ahead of time, so when it is said it plays at once."""
        line = re.sub(r'\s+', ' ', str(text or '')).strip()
        if line: self._put('#prep:' + line)
    def stop(self):
        pass                                   # lines are short; the one being read just finishes
    def set_voice(self, name):
        self._put('#voice:' + (name or ''))
    def voices(self, wait=8.0):
        """[(name, language)] of the voices this PC has, or [] if they could not be read."""
        path = os.path.join(tempfile.gettempdir(), 'wingman_voices.txt')
        try: os.remove(path)
        except OSError: pass
        self._put('#list:' + path)
        end = time.time() + wait
        while time.time() < end:
            time.sleep(0.2)
            try:
                rows = [l_.strip().lstrip('\ufeff') for l_ in open(path, encoding='utf-8-sig') if '|' in l_]
                if rows: return [tuple(r_.split('|', 1)) for r_ in rows]
            except OSError:
                continue
        return []

VOICE = Voice()

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

TIDY_DAYS = 90
TIDY_DIR = 'Older recordings'

def recordings_count(days=TIDY_DAYS):
    """(all recorded games, ones older than `days`) across your profiles' savegame folders."""
    cut = time.time() - days * 86400
    ent = _replay_entries()
    return len(ent), sum(1 for _p, t in ent if t < cut)

def tidy_recordings(days=TIDY_DAYS):
    """Move recorded games older than `days` into a subfolder of the same savegame folder. Nothing is
    deleted: they are a folder away, and the game's list and Wingman's look-ups stay quick."""
    cut = time.time() - days * 86400
    moved = 0
    for path_, t in _replay_entries():
        if t >= cut: continue
        dest = os.path.join(os.path.dirname(path_), TIDY_DIR)
        try:
            os.makedirs(dest, exist_ok=True)
            target = os.path.join(dest, os.path.basename(path_))
            if not os.path.exists(target): shutil.move(path_, target); moved += 1
        except OSError as e:
            log('tidy recordings: %r' % (e,))
    log('moved %d old recordings aside' % moved)
    return moved

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

def recording_growing(path, wait=1.5):
    """True if the game is still writing this recording. It adds to it several times a second for
    as long as the match is running, so nothing added over a second or two means the match has
    stopped. This is the one thing about a game being over that cannot be misread off the screen."""
    try:
        size = os.path.getsize(path)
        end = time.time() + wait
        while time.time() < end:
            time.sleep(0.25)
            if os.path.getsize(path) != size: return True
    except OSError:
        pass
    return False

def called_over_too_soon(st, f, now=None):
    """A game the overlay called over, whose recording then keeps on growing, was not over.
    The first 15 seconds are left out (a game writes its last few lines as it closes), and it
    takes growth seen on two separate looks, so one late write never brings a finished game back."""
    now = now or time.time()
    if now - st.get('ended_t', 0) < 15 or LIVE['path'] != f: return False
    if LIVE['size'] > st.get('ended_size', LIVE['size']): st['ended_hits'] = st.get('ended_hits', 0) + 1
    st['ended_size'] = LIVE['size']
    return st.get('ended_hits', 0) >= 2

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

# The hunt comes in many skins from map to map. For reading at a glance they are two things: what runs
# away (deer) and what fights back (boar). Herdables (sheep, cows and the rest) are left exactly as they are.
HUNT_KIND = {}
for _w in ('deer', 'zebra', 'zebras', 'ostrich', 'ostriches', 'ibex', 'gazelle', 'gazelles', 'chicken',
           'chickens', 'wild camel', 'wild camels', 'camel', 'camels'):
    HUNT_KIND[_w] = 'Deer'
for _w in ('boar', 'boars', 'wild boar', 'javelina', 'javelinas', 'elephant', 'elephants', 'wild elephant',
           'wild elephants', 'rhino', 'rhinos', 'rhinoceros', 'rhinoceroses', 'hippo', 'hippos',
           'hippopotamus'):
    HUNT_KIND[_w] = 'Boar'

def _hunt_bit(t):
    """('Deer', lo, hi) for 'Zebra 3-4' or '4 Ostriches', else None."""
    t = t.strip()
    m = re.fullmatch(r'([A-Za-z][A-Za-z ]*?)\s+(\d+)(?:\s*-\s*(\d+))?', t)
    if m: name, lo, hi = m.group(1), int(m.group(2)), int(m.group(3) or m.group(2))
    else:
        m = re.fullmatch(r'(\d+)(?:\s*-\s*(\d+))?\s+([A-Za-z][A-Za-z ]*)', t)
        if not m: return None
        name, lo, hi = m.group(3), int(m.group(1)), int(m.group(2) or m.group(1))
    kind = HUNT_KIND.get(name.strip().lower())
    return (kind, lo, hi) if kind else None

def merge_hunt(chips):
    """'Chickens 6-8 OR Deer 3-4' -> 'Deer 3-8'; 'Deer 2', 'Zebra 2' -> 'Deer 4'. Anything that is
    not deer or boar like (sheep, cows, relics...) comes back untouched, in its place."""
    out, at = [], {}
    def span(lo, hi): return '%d' % lo if lo == hi else '%d-%d' % (lo, hi)
    for ch in chips:
        alts = [a_.strip() for a_ in re.split(r'\s+OR\s+', ch)]
        got = [_hunt_bit(a_) for a_ in alts]
        if not all(got) or len({g[0] for g in got}) != 1:
            out.append(ch); continue
        kind = got[0][0]; lo = min(g[1] for g in got); hi = max(g[2] for g in got)
        num_first = alts[0][:1].isdigit()                # keep '4 Boar' or 'Boar 4', whichever it was
        fmt = (lambda k_, sp: '%s %s' % (sp, k_)) if num_first else (lambda k_, sp: '%s %s' % (k_, sp))
        if kind in at:                                   # a second lot of the same kind: add them up
            k_, plo, phi, f_ = at[kind]
            at[kind] = (k_, plo + lo, phi + hi, f_); out[k_] = f_(kind, span(plo + lo, phi + hi))
        else:
            at[kind] = (len(out), lo, hi, fmt); out.append(fmt(kind, span(lo, hi)))
    return out

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

_OCR_IMPORT = threading.Lock()

def _load_ocr():
    with _OCR_IMPORT:                     # one thread at a time: see warm_imports
        return _load_ocr_locked()

def _load_ocr_locked():
    try:
        import winrt.runtime
        from winrt.windows.media.ocr import OcrEngine
        from winrt.windows.graphics.imaging import SoftwareBitmap, BitmapPixelFormat
    except ImportError as e_:
        import subprocess, importlib, site
        if FROZEN: raise RuntimeError('the text reader did not load in the exe: %r' % (e_,))
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
# How much spare pop is left before the warning shows, per stage of the game. Editable in
# Settings; these are the starting values.
HOUSE_BANDS = [(10, 2), (20, 4), (30, 8), (40, 10), (999, 15)]
HOUSE_CAP20 = 1                           # the 20 pop exception: nothing at 18/20, 13/15 still warns

def house_room(mins, cap, cfg=None):
    """Spare population at which 'Build a house' starts showing, for this point in the game."""
    c = cfg if cfg is not None else load_settings()
    bands = c.get('house_bands') or HOUSE_BANDS
    room = bands[-1][1]
    for upto, spare in bands:
        if mins < upto: room = spare; break
    if cap == 20:
        room = min(room, c.get('house_cap20', HOUSE_CAP20))
    return room
CASTLE_NOTE_MIN = 13                      # Castle reminder: not before this game minute...
CASTLE_NOTE_FOOD = 500                    # ...and once your food reaches this (what Castle Age costs)
CASTLE_NOTE_LATE = 17                     # if the food can't be read, fall back to this minute
FEUDAL_NOTE_POP = 18                      # population for the 'two buildings for Feudal Age?' reminder
# both are only where they start: Settings has a box for each

def typed_number(value, fallback, low, high):
    """A number someone typed into a settings box, kept inside sensible limits. The fallback
    when the box does not hold a number."""
    try: return max(low, min(high, float(str(value).strip())))
    except (TypeError, ValueError): return fallback
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
        if FROZEN: raise RuntimeError('the exe has this built in already')
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
        self.pop = self.pop_last = None; self.pop_t = 0
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
            self.food = self.food_last = None; self.food_t = 0
            self.debugged = set(); self.clock_miss = 0; self.food_miss = 0
        self.set('off')

    def needs_house(self, mins, now):
        """Warn before you get housed: how close to the limit depends on how far into the game you are."""
        if not self.pop: return False
        if now - getattr(self, 'cfg_t', 0) > 5:
            self.cfg_c, self.cfg_t = load_settings(), now
        cfg = self.cfg_c
        room = house_room(mins, self.pop[1], cfg)
        grace = cfg.get('house_grace', HOUSE_GRACE_MIN)
        return (self.pop[1] < 200 and self.pop[1] - self.pop[0] <= room
                and mins >= grace                     # you start 4/5: no nagging in the opening,
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
            time.sleep(0.3)                  # quick: the build order moves the moment a villager starts
            r = getattr(self, 'rect', None)
            # The pop counter is read whenever the game is in front, game seen or not: the build order
            # follows it, and that should not hang on the recording being found and read.
            on_screen = time.time() - getattr(self, 'fg_t', 0) < 3
            if not r or not (self.active or on_screen): continue
            try:
                x, y, w, hh = r; s = hh / 2160.0; now = time.time()
                a = dict(px=x + w / 2.0, cy=y + 81 * s, s=s,
                         box=(int(x + w / 2.0 - 20 * s), int(y + 51 * s), int(320 * s), int(60 * s)))
                p = self.read_pop(read, grab, a)
                if p and self.pop_ok(p):
                    # one more villager than last time, same cap: that is the next one starting, take
                    # it at once. Anything else has to read the same twice running first.
                    step_up = bool(self.pop) and p[0] == self.pop[0] + 1 and p[1] == self.pop[1]
                    if p == self.pop_last or step_up:
                        if p != self.pop and (self.pop is None or abs(p[0] - self.pop[0]) > 0):
                            if not getattr(self, 'pop_logged', 0) or now - self.pop_logged > 60:
                                self.pop_logged = now; log('pop %d/%d' % p)
                        changed_ = p != self.pop
                        self.pop = p; self.pop_t = now
                        if changed_ and getattr(self, 'on_pop', None):
                            try: self.on_pop()
                            except Exception: pass
                    self.pop_last = p
                if not self.active: continue                     # the rest is for a game we know about
                if now - self.clock_t > 3:
                    self.clock_t = now
                    g = self.read_clock(read, grab, x, y, w, s)
                    if g is not None:
                        if self.clock and now > self.clock[1] + 1 and g > self.clock[0]:
                            sp = (g - self.clock[0]) / (now - self.clock[1])
                            if 0.5 < sp < 3: self.speed = sp
                        self.clock_prev, self.clock = self.clock, (g, now)
                if now - getattr(self, 'food_t', 0) > 3 and self.game_minutes(now) >= CASTLE_NOTE_MIN - 0.5:
                    self.food_t = now
                    fd = self.read_food(read, grab, x, y, w, s)
                    if fd is not None:
                        last_ = getattr(self, 'food_last', None)
                        if last_ is not None and abs(fd - last_) < 400: self.food = fd   # two sane reads running
                        self.food_last = fd
                if now - self.age_t > 4:
                    self.age_t = now
                    ag = self.read_age(read, grab, x, y, w, s)
                    if ag and ag > self.age: self.age = ag; log('age %d' % ag)
            except Exception as e:
                log('pop / clock read: %r' % (e,)); time.sleep(2)

    def debug_band(self, name, shot, lines):
        """Once a game for each kind: keep the picture that would not read, and what was read off it,
        so the reading can be tuned to what is really on your screen."""
        done = getattr(self, 'debugged', None)
        if done is None: done = self.debugged = set()
        if name in done: return
        done.add(name)
        try:
            from PIL import Image
            buf, gw, gh = shot
            os.makedirs(TC_DEBUG, exist_ok=True)
            Image.frombuffer('RGBA', (gw, gh), buf, 'raw', 'BGRA', 0, 1).convert('RGB').save(
                os.path.join(TC_DEBUG, '%s_%s.png' % (name, time.strftime('%H%M%S'))))
            log('%s did not read: %s' % (name, ' | '.join(str(l_) for l_ in lines)[:200] or 'nothing'))
        except Exception as e:
            log('debug band %s: %r' % (name, e))

    def read_clock(self, read, grab, x, y, w, s):
        """In-game seconds off the game timer ('00:02:19 (Fast - 2.0)') under the resource bar."""
        cx = x + w / 2.0
        k = 2 if s < 0.7 else 1
        shot = grab((int(cx - 450 * s), int(y + 240 * s), int(900 * s), int(80 * s), k))
        lines = read(*shot)
        for t in lines:
            m = re.search(r'(\d{1,2})\s*[:.]\s*(\d{2})\s*[:.]\s*(\d{2})', t)
            if m: return int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3))
        self.clock_miss = getattr(self, 'clock_miss', 0) + 1
        if self.clock_miss == 20: self.debug_band('clock', shot, lines)
        return None

    def timer_stopped(self):
        """True if the game timer read the same on its last two readings (paused), False if it
        moved, None if there are no fresh readings to go by."""
        a, b = getattr(self, 'clock_prev', None), self.clock
        if not a or not b: return None
        if time.time() - b[1] > 6 or b[1] - a[1] > 8: return None
        return a[0] == b[0]

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

    def read_food(self, read, grab, x, y, w, s):
        """Your food, off the resource bar (wood, food, gold, stone, then the pop counter). The four
        amounts are the big numbers on that bar, left to right; the small worker counts are not."""
        px, cy = x + w / 2.0, y + 81 * s
        k = 3 if s < 0.7 else 2
        band = (int(px - (SPAN + 80) * s), int(cy - 34 * s), int((SPAN + 60) * s), int(68 * s), k)
        nums = []
        shot = grab(band)
        got = read(*shot, words=True)
        for _, ws in got:
            for t, wx, wy, ww, wh in ws:
                t = t.replace('O', '0').replace('o', '0').replace(',', '')
                if re.fullmatch(r'\d{1,6}', t): nums.append((wx, wh, int(t)))
        tall = max([h for _, h, _ in nums] or [0])
        big = sorted((x_, v) for x_, h, v in nums if h >= 0.7 * tall)
        if len(big) >= 4: return big[1][1]
        self.food_miss = getattr(self, 'food_miss', 0) + 1
        if self.food_miss == 5: self.debug_band('food', shot, [t for t, _ in got])
        return None

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
        try:
            from PIL import Image
        except Exception as e:
            log('idle TC alert and pop reading off, no Pillow: %r' % (e,)); return
        ctypes, wintypes, u, _ = _win()
        threading.Thread(target=self.slow_loop, daemon=True).start()
        last_shot = 0
        last_fg = 0
        while True:
            time.sleep(0.08)                       # as fast as before: an idle TC alert is only useful if it is quick
            now_ = time.time()
            if now_ - last_fg > 0.8:                     # where the game is, for the pop reader, game seen or not
                last_fg = now_
                try:
                    fg_ = u.GetForegroundWindow()
                    pid_ = wintypes.DWORD(); u.GetWindowThreadProcessId(fg_, ctypes.byref(pid_))
                    if fg_ and _proc_name(pid_.value).startswith('aoe2de') and not self.pause:
                        r_ = client_rect(fg_)
                        if r_[2] >= 400 and r_[3] >= 300: self.rect = r_; self.fg_t = now_
                except Exception:
                    pass
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

def read_scores(lines, mine, others=(), players=2, allies=()):
    """Score list text -> (your side's number, the best opposing one), or None when your side
    could not be picked out. Every line reads 'Name: score/side', and the second number is the
    same for everyone on a side. In a team game it is the side's average, so it can be lower
    than a player's own score. Your side is found from your own line, or failing that an
    ally's, or failing that by ruling out the lines that are clearly the other side's."""
    rows = []
    for t in lines:
        hits = [m for m in SCORE_PAIR.finditer(t) if re.search(r'\d', m.group(1)) and re.search(r'\d', m.group(2))]
        if not hits: continue
        m = hits[-1]
        a, b = [int(re.sub(r'\s', '', v).replace('O', '0').replace('o', '0')) for v in m.groups()]
        if b < 10 or b * 8 < a: continue                      # a side's number that far under a score is a misread
        if players == 2 and a != b: continue                  # one against one, the two numbers are the same
        rows.append((t[:m.start()], a, b))
    if len(rows) < 2: return None

    def side_of(names):
        """The side number on the line that clearly belongs to one of these names, or None."""
        if not names: return None
        scored = sorted(((_score_name(r[0], names), i) for i, r in enumerate(rows)), reverse=True)
        if scored[0][0] and (scored[0][0] > scored[1][0] or rows[scored[0][1]][2] == rows[scored[1][1]][2]):
            return rows[scored[0][1]][2]
        return None

    side = side_of(mine)
    if side is None: side = side_of(allies)
    if side is None:
        foes = [n for n in others if n not in allies]
        theirs = set(r[2] for r in rows if foes and _score_name(r[0], foes))
        rest = set(r[2] for r in rows) - theirs
        if len(theirs) == 1 and len(rest) <= 1:               # every other line is one side: yours
            side = rest.pop() if rest else next(iter(theirs))
    if side is None: return None
    rest = [r[2] for r in rows if r[2] != side]
    return side, (max(rest) if rest else side)

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

    def reset(self, mine=(), others=(), players=2, allies=()):
        with self.lock:
            self.mine, self.others, self.players = list(mine), list(others), players
            self.allies = list(allies)
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
                    got = read_scores(lines, self.mine, self.others, self.players, self.allies)
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
    try:
        with open(SETTINGS, encoding='utf-8') as fh: return json.load(fh)
    except Exception: return {'webhook': '', 'friends': [], 'channel': 'wesley'}

_SAVE_LOCK = threading.Lock()

def save_settings(cfg):
    """Written to a new file that then takes the old one's place, so a read at the same moment
    never sees half a file (which used to fall back to the defaults)."""
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    with _SAVE_LOCK:
        tmp = SETTINGS + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as fh: json.dump(cfg, fh, indent=2)
        for i in range(5):
            try: os.replace(tmp, SETTINGS); return
            except PermissionError: time.sleep(0.05 * (i + 1))   # someone reading it right now
        os.replace(tmp, SETTINGS)

STATS = os.path.join(os.path.dirname(SETTINGS), 'stats.json')
PIDFILE = os.path.join(os.path.dirname(SETTINGS), 'overlay.pid')

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
            for k, v in entry.items():
                if v in (None, ''): continue
                # the row written when a game starts says 'no result yet' and 'no end time yet'.
                # Written again later (the game picked up a second time) it must not wipe what is known
                if k == 'result' and v == '?' and g.get('result') in ('win', 'loss'): continue
                if k == 'ended' and not v: continue
                g[k] = v
            save_stats(d); return g
    d['games'].append(entry)
    d['games'] = d['games'][-2000:]
    save_stats(d); return entry

def civ_name(cid, strings):
    return STOCK.get(str(10270 + cid)) or strings.get(str(10270 + cid), 'Civ %d' % cid)

MATCH_URL = ('https://aoe-api.worldsedgelink.com/community/leaderboard/'
             'getRecentMatchHistory?title=age2&profile_ids=[%d]')

# which ladder each of the service's match types is played on
LADDERS = {6: '1v1 Random Map', 7: 'Team Random Map', 8: 'Team Random Map', 9: 'Team Random Map',
           26: '1v1 Empire Wars', 27: 'Team Empire Wars', 28: 'Team Empire Wars', 29: 'Team Empire Wars'}
PAIR_S = 90                 # a game and its line in the match history start within seconds of each other
COMPANION_URL = 'https://data.aoe2companion.com/api/matches?profile_ids=%d&page=%d&per_page=50'
COMPANION_AT = [0.0]        # when the older history was last asked for

def online_game(g):
    """False for a game against the computer. Those have no match history and never get a result."""
    return not str(g.get('id', '')).startswith('SP ')

def companion_matches(profile, since, pages=10):
    """Your older games, from aoe2companion.com. The game's own service only keeps the last ten
    games of each kind, so anything older than that has dropped off it; this community site
    keeps the same public match history for good. Only your profile number is sent, the same
    one on the public ladder. Same shape as relic_matches; reads back as far as `since`."""
    out = []
    if not profile: return out
    import urllib.request, calendar
    def when(s):
        return calendar.timegm(time.strptime(str(s)[:19], '%Y-%m-%dT%H:%M:%S'))
    for page in range(1, pages + 1):
        try:
            req = urllib.request.Request(COMPANION_URL % (int(profile), page),
                                         headers={'User-Agent': 'AoE2Wingman/1.0', 'Accept': 'application/json'})
            with urllib.request.urlopen(req, timeout=12) as r:
                rows = json.loads(r.read().decode('utf-8')).get('matches') or []
        except Exception as e:
            log('older match history lookup failed: %r' % (e,)); break
        oldest = None
        for x in rows:
            try: start = when(x.get('started'))
            except Exception: continue
            oldest = start if oldest is None else min(oldest, start)
            teams = x.get('teams') or []
            mine = next((p for t in teams for p in (t.get('players') or []) if p.get('profileId') == int(profile)), None)
            if not mine or mine.get('won') not in (True, False): continue
            try: end = when(x.get('finished'))
            except Exception: end = 0
            sizes = sorted((len(t.get('players') or []) for t in teams), reverse=True)
            old, diff = mine.get('rating'), mine.get('ratingDiff')
            out.append(dict(match=x.get('matchId'), start=start, end=end, src='companion',
                            result='win' if mine['won'] else 'loss',
                            mode='1v1' if sum(sizes) == 2 else 'TG',
                            size='v'.join(str(n) for n in sizes) if len(sizes) > 1 else '%d players' % sum(sizes),
                            ranked=x.get('leaderboardId') not in (None, '', 'unranked'),
                            ladder=x.get('leaderboardName') or '',
                            rating=old if isinstance(old, int) else None,
                            rating_after=(old + diff) if isinstance(old, int) and isinstance(diff, int) else None))
        if len(rows) < 50 or (oldest is not None and oldest < since): break
    return out

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
        mem = next((x for x in (m.get('matchhistorymember') or []) if x.get('profile_id') == int(profile)), {})
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
                        ladder=LADDERS.get(m.get('matchtype_id'), ''), src='service',
                        rating=(mem.get('oldrating') or None), rating_after=(mem.get('newrating') or None),
                        # whose recorded game the service still holds for this match
                        replays=[u.get('profile_id') for u in (m.get('matchurls') or [])
                                 if isinstance(u, dict) and u.get('profile_id')
                                 and str(u.get('size', '0')).lstrip('-').isdigit() and int(u.get('size', 0)) > 0]))
    return out

def _mapkey(name):
    """'Arabia.rms' and 'Arabia' come out the same; '' when there is nothing to compare."""
    return re.sub(r'[^a-z]', '', re.sub(r'\.rms\d*$', '', (name or '').lower()))

def fill_results(profile, days=60, force=False):
    """Write in the result for every recent game the match history knows about. Only the match
    history sets a result: it cannot be misread, and a wrong win in the record is worse than no
    result at all. The game's own service is asked first. It only keeps the last ten games of
    each kind, so what it no longer lists is looked up on aoe2companion.com (at most every
    half hour, or when asked to with force)."""
    cut = time.time() - days * 86400
    def waiting():
        return [g for g in load_stats()['games'] if (g.get('started') or 0) > cut and online_game(g)
                and g.get('result') not in ('win', 'loss')]
    if not waiting() and not force: return 0
    n = 0
    matches = relic_matches(profile)       # the slow bit, so no lock is held while it runs
    if matches:
        with STATS_LOCK: n += _fill_results(matches, cut)
    left = waiting()
    if left and load_settings().get('companion_results', True) and (force or time.time() - COMPANION_AT[0] > 1800):
        COMPANION_AT[0] = time.time()
        older = companion_matches(profile, min(g['started'] for g in left) - 600)
        if older:
            with STATS_LOCK: n += _fill_results(older, cut)
    return n

def _fill_results(matches, cut):
    """Pair games with lines of the match history by when they started, which agrees to within
    seconds, and write the result in. The map name is not used for this: the one the service
    gives is often not the map that was played, which used to leave real matches unpaired. A
    result already in the record is put right if the line that starts with the game disagrees."""
    d = load_stats()
    games = [g for g in d['games'] if (g.get('started') or 0) > cut and online_game(g)]
    if not games or not matches: return 0
    changed, dirty, owner = 0, False, {}
    for m in matches:
        g = min(games, key=lambda x: abs(x['started'] - m['start']))
        if abs(g['started'] - m['start']) > PAIR_S: continue
        if min(matches, key=lambda x: abs(x['start'] - g['started'])) is not m: continue   # each the other's closest
        owner[m['match']] = g
        extras = {k: m[k] for k in ('rating', 'rating_after', 'ladder') if m.get(k)}
        if not g.get('ended') and m.get('end'): extras['ended'] = m['end']
        source = m.get('src', 'service')
        # the ratings an older version noted itself (looked up before and after a game) were often
        # the same number twice. The match history's are right, so they replace those once
        own = not g.get('rated') or g.get('src') == source
        if g.get('match') == m['match'] and g.get('result') == m['result']:
            new = {k: v for k, v in extras.items() if (g.get(k) != v) if (own or not g.get(k))}   # already paired
        else:
            new = dict(extras, result=m['result'], src=source, match=m['match'], ranked=m['ranked'])
        if extras.get('rating_after') and not g.get('rated'): new['rated'] = True
        if not new: continue
        if 'result' in new:
            if g.get('result') in ('win', 'loss') and g['result'] != new['result']:
                log('record put right: %s on %s was down as a %s, the match history says %s'
                    % (g.get('at'), g.get('map'), g['result'], new['result']))
            if g.get('result') != new['result']: changed += 1
        g.update(new); dirty = True
        if m.get('civ_id') is not None and g.get('civ'):
            d.setdefault('civmap', {})[str(m['civ_id'])] = g['civ']       # learn their civ numbering
    # a line of the match history belongs to one game. Another game still holding the same line
    # was paired with it by mistake, so its result goes back to unknown
    for g in d['games']:
        mid = g.get('match')
        if mid in owner and owner[mid] is not g:
            log('record put right: %s on %s had been given another game\'s result' % (g.get('at'), g.get('map')))
            g.pop('match', None); g.pop('src', None); g['result'] = '?'; dirty = True
    if dirty:
        save_stats(d)
        if changed: log('filled in %d result(s) from the match history' % changed)
    return changed

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

def rating_line(games):
    """Your rating after each rated game, on whichever ladder most of these games were played:
    (the ladder's name, [rating, ...] oldest first, the change across them)."""
    by = {}
    for g in games:
        if g.get('rating_after') and g.get('ladder'): by.setdefault(g['ladder'], []).append(g)
    if not by: return '', [], 0
    name, rows = max(sorted(by.items()), key=lambda kv: len(kv[1]))
    rows = sorted(rows, key=lambda g: g.get('started', 0))
    pts = [g['rating_after'] for g in rows]
    return name, pts, pts[-1] - (rows[0].get('rating') or pts[0])

def rating_change(g):
    """'+15' or '-16' for a rated game, '' when it is not known."""
    a, b = g.get('rating'), g.get('rating_after')
    return ('%+d' % (b - a)) if a and b else ''

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

# ---------------------------------------------------------------- the public releases
# Wingman.exe and AoE2 Wingman.bat are published together on the repo's Releases page (tags
# like exe-v114). The exe cannot update itself from git the way the .bat does, so it checks
# that page instead and swaps itself for the newer one.
NUDGE_AFTER = 20                           # seconds after start before checking for a release
RELEASES_API = 'https://api.github.com/repos/%s/releases?per_page=8' % REPO
DOWNLOAD_PAGE = 'https://ashley-pettit.github.io/aoe2-wingman/'
_REL = {}

def ver_num(v):
    m = re.search(r'(\d+)', str(v or ''))
    return int(m.group(1)) if m else 0

def latest_release(fresh=False):
    """The newest public release: {'ver': 'v115', 'exe': url, 'bat': url, 'page': url}, or None."""
    if not fresh and _REL.get('t', 0) > time.time() - 600: return _REL.get('rel')
    rel = None
    try:
        import urllib.request
        req = urllib.request.Request(RELEASES_API, headers={'User-Agent': 'AoE2-Wingman',
                                                            'Accept': 'application/vnd.github+json'})
        got = json.loads(urllib.request.urlopen(req, timeout=15).read().decode('utf-8'))
        # The newest release that has its Wingman.exe up. Each publish makes the release first and
        # the exe lands a couple of minutes later, so the very newest one can still be empty.
        best = None
        for d in (got if isinstance(got, list) else [got]):
            if d.get('draft'): continue
            assets = {a.get('name', ''): a.get('browser_download_url') for a in d.get('assets', [])}
            if not assets.get('Wingman.exe'): continue
            if best is None or ver_num(d.get('tag_name')) > ver_num(best[0].get('tag_name')): best = (d, assets)
        if best:
            d, assets = best
            rel = {'ver': 'v%d' % ver_num(d.get('tag_name')), 'tag': d.get('tag_name'),
                   'exe': assets.get('Wingman.exe'),
                   'bat': next((u for n, u in assets.items() if n.lower().endswith('.bat')), None),
                   'page': d.get('html_url')}
    except Exception as e:
        log('release check: %r' % (e,))
        if FROZEN and not _REL.get('traced'):           # once: where it broke, to fix the exe build by
            _REL['traced'] = True
            try:
                import traceback
                log('release check trace: %s | SSL_CERT_FILE=%r' % (
                    traceback.format_exc().strip().replace('\n', ' | ')[-700:], os.environ.get('SSL_CERT_FILE')))
            except Exception: pass
    _REL.update(t=time.time(), rel=rel)
    return rel

def newer_release():
    """The release if it is newer than this copy, else None."""
    rel = latest_release()
    return rel if rel and ver_num(rel['ver']) > ver_num(VERSION) else None

def update_exe(rel, progress=lambda t: None):
    """Swap this Wingman.exe for the release's one. Windows lets a running exe be renamed but
    not overwritten, so the running one steps aside as Wingman.old.exe (cleared next start)
    and the new one takes its name. Returns the path to start."""
    import urllib.request
    me = sys.executable
    here = os.path.dirname(me)
    new = os.path.join(here, 'Wingman.new.exe')
    old = os.path.join(here, 'Wingman.old.exe')
    progress('Downloading %s...' % rel['ver'])
    req = urllib.request.Request(rel['exe'], headers={'User-Agent': 'AoE2-Wingman'})
    with urllib.request.urlopen(req, timeout=120) as r, open(new, 'wb') as fh:
        shutil.copyfileobj(r, fh)
    with open(new, 'rb') as fh:
        if fh.read(2) != b'MZ' or os.path.getsize(new) < 1000000:
            raise RuntimeError('the download was not a working Wingman.exe')
    try:
        if os.path.exists(old): os.remove(old)
    except OSError:                                    # the last old one is still closing: pick another name
        old = os.path.join(here, 'Wingman.old.%d.exe' % int(time.time()))
    os.replace(me, old)
    try:
        os.replace(new, me)
    except OSError:                                    # could not put the new one in: the old one goes back
        os.replace(old, me)
        raise
    log('updated the exe to %s' % rel['ver'])
    return me

def clear_old_exe():
    """Tidy away the exe this one replaced. The old copy is usually still closing when the new one
    starts (and Windows won't delete a running exe), so keep trying for a minute in the background."""
    if not FROZEN: return
    here = os.path.dirname(sys.executable)
    olds = glob.glob(os.path.join(here, 'Wingman.old*.exe')) + glob.glob(os.path.join(here, 'Wingman.new.exe'))
    if not olds: return
    def work():
        left = list(olds)
        for _ in range(40):
            for old in list(left):
                try:
                    os.remove(old); log('removed %s' % os.path.basename(old)); left.remove(old)
                except FileNotFoundError:
                    left.remove(old)
                except OSError:
                    pass
            if not left: return
            time.sleep(2)
        log('could not remove %s yet, will try next start' % ', '.join(os.path.basename(o) for o in left))
    threading.Thread(target=work, daemon=True).start()

APP_ICON_PNG = (  # the Wingman crest (64 and 32 px PNG), for the title bars and the taskbar
    'iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAYAAACqaXHeAAAVYklEQVR42u2ae4zc13Xfv/f+3jOzM/vgPkkul6RI8SWSelJv'
    'ypYd17bSoGnUBnVbNEgKo0BQ+48CKZoWlgOkfzhu2qJBU7eN0RYJioiw45imZEWSLZISRVIklxK5D+5yd2d3Zx8zu/Oe3/ve'
    'e/rHzFKULEoUyZUcVBcYkAR/v51zPvd8zz33nAU+W5+tz9b/z4t9kt9FBDz3HNje0WfZSKHARnuOEwDsKRxme3t6aGTPEXru'
    'ORBrWkV/GwGwb30LbHQU7Fk8izUnjxwBAVAf82fxZ58FW4NzBEewZw/ouW+D2B2E87EBEMCe+2An1Q12jQFIPrano7Or3epJ'
    '2PpmjdOgpmlDjLCVcTClKKskslKqOV+K+XwjzL85XCkBcG8Ajj37LPidgHNTAL71LfDRUbAjRyBv8IiWyaDtvru6uzocvc9y'
    'tM0G41sYx1YObOGMbeIaejXGO21b0xKWBsfWkLI1gAGuL+GFEn4g4YVSSanKirBMRAtENKsIM0LSbBjJ+dW6WLo4vVKsVlEH'
    'IG5kLwB8+9sfHXU3A0BvfZG+sz/VPjTUtiFj8wFb55s1jQ0xhiEObAHDRs54j6axdtvS4JgabEtDwuZI2hoSFkPC4kjYUI7B'
    'yDI5mabBACCKYwojxfyImB+CeyHBDRS8QMILFfxQIggl/FBCKFUlhQKBFqEwqxhlhaRsFKr5RqAWJoqN1atXGxUA8XW23xqA'
    'w4cP68ePH6ff+vKWb6YS/O/5gepnDL26xpOWwWG1nHQsDUmbI2FrSNoMSYspx2LKMhgMjTPdMJhu2sxykrCTGeak2mElM+Bm'
    'CmCACl2EXhVBo4LArVLgNSDigEQUk5CKgpjgR8S9gLgbvAtnDUwQK4SRRCyUR6BCwtKW3FD+9fePzX338GGw48dvDEH/0L3P'
    'ZnUADERf6kpbj6X7daQSOlK2Rm0OU7bFyDYYdA1M0zTGNYMZls1MJ8XtZIY3HW2HbiWhmAk3UCiWXUwsVDC3MI+Z7DKUImwd'
    '6sPgpm4M9O7Eht4E63M0aBQzGTYQelX49QoCt4rQb0BEPkkRk5SKpKQmnJBYPSDu+jLR8MRQzRNDjUWvAeC/ILtFAbO3BiCU'
    'kgFI1TxRSyd0+SuHelQYCZ0xzjTD0cxEG+xkBom2DtipDHQzCckMeIFEsezi6kIZc/NZZOfzmMsVsLRcQqlch+eHkEKCcQ4A'
    'UEpB1zgcx0JHexsG+jqxeVMPhgZ7m2D6dmBDXwJJW4fGYiZCjwVuFX69jKBRQejXIeMAUJJMUxd/c7rAa56oAUiGUjY+St8f'
    'eRwFkfSEJM3zQnRufYD1br4LXNPRCCRKZRfTuTJm5q4iO7eMufkVLOdLKFXq8LwQQkowxqBrGgxDh65rSCUTYOzdYwUMIGqC'
    'WC3WsJQv48z5CRApaJqGhGOhoz2F/t6Oa2C2DvZioH8bNvSlkHJ0KCVQmL/KitNvcSFJCyLpAc1keMsALE0jACoSVIkFQUqJ'
    'Db39OPbzcfzoJydRqblYLdbheQFiqcAZg6ZpMAyt6WjKAWMMBICIAGr+qZRa8/t6Bk2DDB2GqYMxBoYmGKkUVlpgzl6YhCKC'
    'rnEkEhY2dKaRSSfwa195DF99cgiFSYlYECJBFQCq5cOtAVgwZgmA8kJRCCKFSCjGIXDu4gRePzOG7u52MDAkW46i5Si1HJWK'
    'PrSgow/6e+v9979nGDrMFpi171GKsFKsYWR8DoOb+/CrT25CJBQLIgUvFAUAquXDrQHIZJrFTbkWL9Q8QX4guYoDdHVmkEzY'
    'MHQdUkpISeteuRLRL2BjDNB1HcmEja7ODFQcwA8kr3mCyrV4AQC1fLixvj/sP8+fbwJYXvEWvEDUw0hCRh51tKcglWrGJzXD'
    '90afmylEbvX5lrYglUJHewoy8iiMJLxA1JdXvAUA1PLhlpOg6uiAKpXlqhvIJTeQaRG51NmeZKQIUipI+eHFFmPs3YT3Aasp'
    'k+t2hH84hvc/DwCkCJ3tSYjIJTeQzA3kUsmTqx0dUOXy7QFAD+9SZRQrNU9MVl11t1cv00DvdqTTSZiGDtLpQ7UtpIRS9IG7'
    'SwBsy2huZysTRpF4T1K8/lnOGSxDf48EGIB0OomB3jS8+hRVXYWaJyYBVFq243YAUIfjCAB+pR6Pl+vxM65PbPfdG/GXf/ov'
    'IST9wu4SNQ0lIrSlHPzRfz2KF39+Eek251q0aJyj1vDwzBfvxzd/58uo1X0AQLotged//Ca+9+evIJNOvOf5uuvj8CN78G+/'
    '8etwvQCcMyhJIAC6xtDV1YGlK1dZuR6jUo/HAfgt2+m2IqCWzkkAYrEYjqyUQ1V1Bdr9MEqnHObYpqGI3hfygBBKxULITDoJ'
    'Xdc0IuLUShlrkACGpx7Zg/7uDBKOCQaGhGPiqUd34//84CSkUNcsJwJIAZrGVWd7UlqmBsYYM3VNBwOCIIp9P6SaK/RCOVSL'
    'xXAEgGjZftuXIQ1AO4BdX//VoSN3bU4lXr0sTi+tNvh//P1/cP+DB4Y6642AOGeMiMixTTaTW3W/9o3/eRagSIPar2voVwrE'
    'WPMUE0KhPZPA//rjr78nMgBA0zi+/nvfx+jkAhK2CdU8FokzMEG0oqBfjCNB3/jtL+74+m99YevzPzy18J3vvTTStyFFT+/T'
    'H7463/C+dzT7LIBxABUA8pZPgbVEuK2jQwDIz68EZxKGSP+P33/k8D/59ceeOPrKucgyNRApxkBgDCwII2zqbU9uG0g/4buN'
    'z3NGvQCBseZVnTOGIIywf9dm9HS1IY4FGAgMzUIr6Zh48MBWxHEMxpvqX3uXEXWpOHiKZPi53dt6hhAL+qtjZ/g//Y3Hn/rv'
    '/+bhwwlDpOdXgjMA8i2bP/I6fDMAKEqWIwBevhRcKNYU8+tF64mHttmXxxe0SsWNdY1BtWJcComEY+DJQ3frGueGrnOu1HuT'
    'GRHh4fu2gzECKdUqnpoQ4jjGoYPbYJkG1HUZv6l1zjljxq67BoyDuzez+flCMD2/ah0+tN306yWrWFMsXwouAPBaNtOdAIBc'
    'DjEAMZGrDy8Vo+p8Ls+29lnQTdsemch5jmVASUWkmk2hOIpx//4hGIbWKpJaOiYgFhIdmRQO7NmMIIiug6DAAPh+hJ3berF5'
    'oAtBKFqX0VbeYAx+EOPgnkHq6Erh1PlJv70j7Qz2msjl8mypGFUncvVhAKJlM+4IAABqMJOJ656cWSiG5xbyDViqog7s2+r8'
    '7NRoaBocSsqWEwQ/iHD31l4MDnQhDEXzPkBohn8QY9f2fmzqbYcfhESKQFDXIMQiRqbNxr37tiAM42vvNi9LBMPQcOjgNqak'
    'xMsnL8cP3bfTNkRJLRYaWCiG5+qenBnMZOKb7UHeLACKE9UQQG0u75+cK8Qo5nN48tB2/a23Z+F6geQcbC2U41ggnbJw374t'
    'CKL4Wv0OxiCEwgP7h6gjk8DpCzP5samlUtI2IKUkankqhcTDB7dC0/i1EpgxhjASGOjtwP5dAyjky+Hl8UXtc4/sYMXlBcwW'
    'Yszl/ZMAai1b6Y4CWFpCBCAam6mfzi6HhexMjh/c0Q7JdGtyetmzTR1KSgI1ZSClxKGDW6FpWjOTAxBSIZWycf++QSaEwNFX'
    '3xavvXklMnQOpRSwJoMgwt4d/ejtziCMJcAYGGcIQoH9uzfRQG8GZ9+e8exk0tm/PYPZbI5nl8PC2Ez9NICoZesdBbAmgyiU'
    'MjtXCE5M52pwVInuvWerc/zMROBYOpSSIPWuDPbu6EN/dxpRJKBxhiCMsX1wA3YOdWMpXw5HJhaSF0ZmDdcLBWdgzRyiEEUx'
    'NnQkcWDXRgRhDM6aiZNz4NCBIaZxhpdfH40eeeBux1KraiZXw1whOBFKmR3MZKKP04L/WABYe9UH4I7N1l69kgvV4uwUvvTk'
    'TvPC6ILyg0g1hx/NMI6iGF3tCexvOaFxhjgSuH/vIHVkHFy+suCVK64zO79qzuZWfdvUIJVq5oRWFB06ONScpgCII4Huzjbc'
    'u2cTVlaq8cjEMn/m87v4QnaKjedCNTZbexWA27JxXQBgdhZxMolovuCfzy6HFyemltg9W0zYyaR5NZsPHFNrRgE1wxlEePjg'
    '0LVLjGUbeGD/IFNS4o3zUxEYLNeP7LfemQ0M/fpE2pTBgV0b0dmRgpQKQSSwd0c/DW3swPlLWb+rp8vaO2hiYmqJZZfDi/MF'
    '/3wyiWh29uay/y0BAKASCXgAVkdn60fHsg1E1Xk8+uBdzvlLs75t6ZBSUXMHgSCIsP/uAXR3tqHhhRgc6MTubb1YKdXj0xez'
    '3DJ1puvcOHluSkWRUAzEmu8qhGGE/u427L6rD0HU7Gk+tH8LbFPHiXNTwdOP704E5Tkaz7oYna0fBbDask2tJwBaWUGYSCAY'
    'mam+NjYfTl+5MkNP3ttjFupCNBoeMRCDIjAihFGMvu427N3Rh0otwH17NlFvVxITMwVvJle0dV2DZeq4dGXRzK9UfdPQoKQC'
    'VLM20DjDof1bEIQCHZkk7t+3mS0VyrLkKjz9YL9+ZXwaY/Ph9MhM9bVEAsHKCm46+98qAAAQfVaHB2BhYt49dmmyzNKsxHds'
    '26TnlsqhZWrNnh8pKCWhc+DBewbBGMOD92wGZ8Dpi9kwjKTDWj3EUtVzhsdygWVyKClprZ4IwwgP7NsE09CxfbALO4e6cGk8'
    '59+zd6uV5iW8c7XMJubdYwAWWjaJj+vMrQCg6XLZdwB/eKLy00szwdLs1UnavyNjVT3pcSgoteYEEEYx9u3oxc6hbuze1sNK'
    'VVeeGs7CMnRdtU5NjXPr5FtTQgpJuCYDQhDG2DLQjqGNnbhnZz+ZOkOhGvuPH+yxpq5cocvZYGl4ovJTB/Cny2X/VvpytwIA'
    'AER3Bm4k5fQ7M/UfDo+vMjtetGNmxL4fgrHWaQBCFAn0dCbxD79ygLraHcwtlLyJmYLl2DoUKVJKUcLW2YWxBb1YdsO1mmCt'
    'e6xzhi88ehfu37uRFVarqqunW7XzVfPC6Ap7Z7r+w0jK6e4M3FvZ/dsBoOaq8Gwb7oWJ0rHzk42l0nJON+CxqhtHOkeztFUK'
    'UkoYOsffeXwndM5w7vJ80PBCR2u2vhiBmGFoKKzUndGpZc8y+LV7BQOh4QV45vAu7NnWjeWiH7RZkZ7PZfnwlLt0YaJ0zLbh'
    'zlU/fvK7XQAAEFsWGlJiZniy9vzFK0Xo4YJdrAWexgG1Ft+tD2PEwjhWJ87PKFPXTKnoWo3f6q06r5/LxgCBSLG196SUcGyd'
    'DJ2hVI98M1p0LoyuYvhq43kpMWNZaLQGofikAahqFa5twx2erB49dbk65VZKbbVSPhCCQETX7gZKKZg6R36lHlyeyJu2pUNd'
    '10pSSpFjGezMpXmtVvcjnTMoRVgrqkgp5vmC/MZKVC/mE29crkwNT5SP2jbcavWGv0Ow7gAAQFgW6gByp0bLfzEx77LQLbJa'
    'IxTXZEAKUiqyDA0Xxxf9Us1zNF0DAWxtmqAIzDA15PIVe3J21bNMfi2RKqVg6AyVehDKxrI+Ml3HmdHyXwDItb5b3I4DtwtA'
    'VatwHcdpTM7XXzo7Vj2fX6l01V23oXEG1SptQYpJKen14VmhcW69Oz1698PAEAty3hiei5oSUoxU80ThjKFWrzWKZbfrjcvl'
    '85ML7kuO4zRud/fvBAAAEImEXzOBlddHS9+fnKuJ+VxeKEUkhCAhBHEGKlXdYHh0SXcsg0lJ9AH9frJNXTv99jwabhiDFAkp'
    'SUlJUSRpeTmvJnJ18fo7pT8zgZVEwq/d7u7fKQBULMLPJBL13LL/5vis++LwWC5haIx1t9u8vc1i/RuS7MpMMcyv1h1D5wAR'
    'e38IkFKwTQ1X54r2YqEW9W9IsvaUxXo6EpxIyotji20j040XF4v+6UwiUS8WcUvn/gd1fO/I6M6LY2lZ0JeK0WpXm3ZfIHhj'
    'aqFWvjyxUCnXw9KRl0aCXKG+Qdc5u4HZrNn0kJqQat40tMqZi7PVmaVGaXhssT4yOV89/k7lP4DJ2VoQr95O5l8PAABAySRQ'
    'dykkKdnV7OLOOKqVco1k+HvffbGxWva600mzTTaz/we24xWBbFPX3rq85P7Zj97O927aGC3NTdROX8zaC8Xo+dll7+eJBIpR'
    'dPvaXw8ACEPIDts25kv+6hMHej73j57uO/S7/+zwQEMkN42MTads24JS1OyQ0QdMKAiMaxxxFGV+52tPb/pP/+qhgYQsbL66'
    'GF195XzhTzpse6XqidJH9fo/NQAAKBBCmib4+Hwjp4Ef7jLL9pe+9IR6+dQMK5drzDB00A2UyzmD70fYtKmXvvuvv6xGzr6G'
    '//vyYukHJxa+zThNuqFYAT7+je8TBQBAOQ6Y55EXRCQyDnv8niGOffc9xH/0wjmYhnbdrB+/MFYLQoE//oOvsQ2Ywk9em+Ev'
    'nCn+yWIxeMVxsBpFaNzJ3V8PAM1BSgTRYdv6fNHN27a1vU1ztz792HYZG938+OuX0JZyIK+bGBMAQ9ewWqzhX/z2V/EbT2bk'
    '37x8VvvpuerxU5eL/63DtvO1ZuiLO23segBYk4IwTfDZJX8ulbAf7zLL6b/7lcfVhfEim55dgtOa+63NA6t1D4ce2I0//OZT'
    '6sIbP9OOniov/eSNpT/gGk27zV93uaOhv+4AWlIgz6ew2pC1hMUPD3U02Bd+5XN44edjzPcDaJoGxhiiSKA9k8af/vvfpNrc'
    'afz4xKI69ubKd1aq4RuOg5X1CP31BnBNCp2Ooy1VvBXG9A5Hi/Y9cHdS7dh3H//rF8/BsgwAgOuF+O5z/xg72vPq2Ktj2kvn'
    'Kj94e6ry552Os5b1xXoZuZ4AAIB8IeK0ZemTi7Ws49j7Uqw28MXHtyty+tiJU5cRhDF+958/g998ql29+spp7YW3qhdfOrv8'
    'R2nLWqwEQQG4+SHHLyUAACqUUpomaGbRnU0lnScyKCb//q89Rpem6mxoSx/+8BuP0pnXfsaPna2s/ujkwnOM07gXyTxw642O'
    'XxYAaxCEbYM8n7xaQ1RtUz/cnyjjq898EZ9/dAeWxk7QT94o0IunC9/Jl8MTto1CHKO6Xrr/pAE0h6sxhG2DF8pRIZbMcHR1'
    '747eWJG/TC+dzGovnC3970sz1b+0bRR8H+uq+08DAACQEIjTlqVNL9eniWmDXQm5fXGpyv/q9ZWfnXxn9T+nLWvZDeW66/5T'
    'A9DKB3HKNPnkYm087VgPTy8FlR+fWvx3ScPM1aMoD8Bfb92//wrySS89DaRrwIaN3c4+DWBzK/6lNLBaA2qfVOh/mgAAwACQ'
    'AmC3/h0At9fd/dsGgAHgW5ogMNt0XH1Suv9lWuxT3ITP1mcLwP8DNRP3wgzZqrYAAAAASUVORK5CYII=',
    'iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAYAAABzenr0AAAHjklEQVR42s2XXWwU1xXH/+fOzH55P+z1t3eNjU2ArKF8pE1C'
    'aeRSqNSkAlEpi6pWUV9QpbZR33itcSv1qRVVRBulqsRDUKRgIuWhJYHSOgYMBlyC7Njmy/Yua6937fXsrnd3dmdn5t4+sE4J'
    'ssGEpuqRRhpp7pz/75577jn3As9mVHmeycGaxvT0gMbHQWGEAQDhUEiwX/dyAOC/6mF94+MEAH3oQygE0dsLUflfPDVUT3e3'
    'fCoclkQPGNGXnwQRIHrAToXDUk93t7zS2LVEQHK7m/ybArypxs1aPU60u+yiw+1g630uuV0QKKdZkbxmTRd0TOVKiORyIhbJ'
    'UiKZTKoAzLXSEwDxo73rOmw2Osgts8NhE+vddqnV7ZKafFX22sY6F2us86DW74HX64HicAEgGHoBuaU8FtUlJFN5JFMFnsmX'
    '1ZxmJrSSiJVMmmaMTWkl/uH7/bHJZS0AkJfVw2Gwvj5Y6Zz+6qG9Lb/vbPWirq4GVW4PZJsLZaFgqQi+kDX4SDKP6KdpisxE'
    'SAigPegXbYFqEWxswZb1NrbLCWYjo46XtbpCPr8llVIxGVvC+/1xHcDxZa0vAIRCD4jiKa1Q7bGZbV27+PmrcWl2TqXo7CTF'
    'kxmo6hLLF4rMMAxACMgyAwBcvsoBEBRFQVWVE7V+j2huqEFbwC8CLX6x76VNVirbz+LzWv5hrS8ALNvsgpYslIQ0cishHf3d'
    'B+RxySBGUGQJsizB5ZABp/KfBGEEIoLFOTgXMMolzM5qFIvNYei6oJxmouE3YVYoCswuaMlH9T4H6O2FIACpnBVbTGvZQKeo'
    'liSJcy6YsATKZQumyYXX7SBZliAAWBZHQSsBAFxOOxRZAiMGwYCCVhayRCRJEvc4BJtOa5lUzopRRWvFCBAjCC7iM/NLkYOB'
    'mu1HfrafZbNZMMbAiFDtc9Hpv11DYj4DAKj3e/DjH+wGkxjOXxzF7JwKIkJ9rRc//8l3KZPVUOV2s45ADc6cWYoAiFc0sBKA'
    'sCxORJSZV42RweHJdd/YsaP09a5Ai2Fw5Iu6efbCZzMW581EZC9oOl55+Xkc+cV+gAgSIxw/cQ4etwMglJ0u18z+fTuD95NL'
    'qUvDNx0J1RgBkKlofE7AVtiVfPi2ekHoi95PBm86piJJM51dQrGgSX86cbYhGkspiiJBkhhe3NYOdTGL1LyKF7a2welQwBhD'
    'PJGWf/vWB413p+ZwfuCGg5VVz/CEegEAf7T0sEcrFxEwdl8fKhT1pfZGh38qlirbJILP46AD+7a7hADTdRPNDdUIbWiGaRgw'
    'DAMb2urRFqiHrhswDIsd2Lu9Sjcss63J4S9oem5iRh9a9r8qAABwLgjAvX+NzvXXeTiis2kD3EKppGNHKAi7XUFe07FrZyfm'
    'kunc2J1YwSYRXHYZO7euQ6lswRLA9lAronHVaPQJXB+N9wO4V/H9WABRCZF+bijxYT6jQnBdVrN5yyiX8Vx7PVqba1DSTXS/'
    'uAFn+kdw/tKEsCmEclnHS9vaQADqa9wINvpMXS/KxVwWHw0lPgSgV3yLx0aACGCMML3I+0duxSea/XDG53M6wYK3SsGW55pR'
    '43WiI1hjXrkxJd+ciEnFYsnSS2U839GIap8LmzsaIEB6o0+4Rm/FJ+4v8n7GCCs1NrZCfxCWJQhA/OPBmZMKzzMQmUbZALcs'
    'bNnYhBe2rkOuUDSmZ1UlOpOWozOLBoGjxmNHaEMTNq1vgKzIlpMK9NGl2EkA8YpPsRaASjKSuDSRP31jZPq+26Y7S7pp6aUS'
    'Nq+vww9f247B4SluGJZU0HTp+kjUssmEkq7j1Vc2oWtji+l1GM6bY9H7lybyp4lIrNbW2SpdUnDOCcC9s1fiJ6JTdxVuWeVy'
    '2UB9jQvbNjXyf165A5siEWPEBm9MwTQNXigU8fLXgtjYXluOTN5Rzl2ZOfEg+TitdjBhqx8mSDAiPjCafXdweHI8rSbsFuec'
    'EReRmUXjdiQlK7IERZEwdjcpJeYzBgMXlsV5JpWwD1y7OzEwmnuXEfGHC8+aAQDA4oJ6gOm/Ds798bNbM5ZDJlbrtdOn47NW'
    'Nq8rxAgSY1jIaMrI7YRV53OQIoGNTkTEmcuJ40Jgylph663YjFbJBSGEQC/R6XNXot9rbmnudjtsxf6rU05FZmy5psuMSX+/'
    'fLfcGfTl1GzRdf5a7MJYtHgaEHjc7J8IsLwUQogFh0x/WNeodFX5g7YLN2LVDX4XDPNBZXW7bPh4cNq+oaMhV1BntTOX48eE'
    'EAtPEn/iEjzcI3QLlycm1dMHv1Uf3PPNzUo6o0FiBIkI6YyG7+ze7Diwu751/N5iX0G3Bp/xtL7CthA9DEDLmwdbB4bee0OE'
    'OpvNjhav6GjxilBnszn03hvizYOtAwAClbH/fas47n77yI6FU8cOiYbqKquhuso6deyQePvIjgUA3U8rTk8HAOrqCilLiVs/'
    '/cvRvW99Ms45AHw7xNjho//4pbdp85/HxsYNoqe/jKwdoqeHAfDt2Vr1zvWTr4vrJ18Xe7Z63gHgq3z76q0iFDz8WuDi4e8H'
    'LgIIfmXrvpqFw5AAhACEKu//c6Mvm0v/V/ZvlsG3a7nIekkAAAAASUVORK5CYII=')

CREST_20_PNG = 'iVBORw0KGgoAAAANSUhEUgAAABQAAAAUCAYAAACNiR0NAAAD5klEQVR42p1UXUybZRR+zvv15+tHgZaWn8IEGQwmNEwxQy9MRDEuWbLswo3pxRK92YXJLszMXKKxNHqDi8TEeDN3MROjUZbFH9RlY7Fsc4mGDRhScLQF1lGghdCW8rWl/d7XCz5GEzVze5I3Oe97znlyzptzHkIBPB6wVv9hmmiJUieAztYKIR05r3Gx6WcEaN8cknwTUfIBgA9A5xD3esHxkHDo54GgLePYsaeN90buthbL6bodFaU7y8usDWV2pb7YqtRaLHI1EaCmM5G1VDq8Gl8PRZdTwchSYkblltlKd+3EmTM3cwBAHg+Y1wveUmttefOVxvGO9gamwYhMDlhO5BCJqbi7kAQR4TFXMVwOC5ylJlhMgIQ8/rgV4J+dn26bDK9PeDxgBIABxAHR8P3HL4/8HhLKpV/9PLORIzWdhcTAiED5vAYiJoxGgzCZjIIxJvZ3udkzO0k9eOLSUwAFAcEMAARjAOdYiCczEYmzZsHzVOsqYZwLRFeSkBiD3WZFaj1DajoLW4kZnANMyyGe5BEACzqHYACEpr3PAKiTodjIvufbUj988bb49IM3Nhrrq9fiCRXNDdW4cPYtHDnwLFYT6ygpVtIfvvNqfP+Le1R/cOkWAFXnEAwA+ru9BADzCytD09N3lEw6mzcbYRzzzyq5PMdze3ehyGLA3j2Pw15ahKlAxDw2OWeanQlZ5sLLVws5GAB094MTEXxj0csZNZWcmVs0OG0W6mirl4oUMxw2JTtyO7ixu74cVeU2VDpLWZ2rRE4k4snf/CuXiQjd/ZuzyPSpEZxzCscQvDcfu5jfSErpdDbvbqpC2+4a/BWIiIHBUW63yXA3uVDjsudLFcHmwku/hGMIcs4JgAAAaXskvWxoCCKTTsU73NWvVVY4ySQRsypmfnU4KMKRVTr4Qgtlszly2ku4YlC1z78dPrG4qs1s5QKA4T6dF1wIQUTkGx0PXnQ31R2oLrfyXM6hfXIuKkkSw1Qgoj35RBXUddXQP3BtYCSU9ek591ePFa5NTw8REWlf/Tz50fDYHbXSLrPxqXm+puZYYi3LRv1hXuNQ2O2JafXLH//sJSKtp4eokMNQeNmskhMRXf/pWuis01H2+ndXJslkYGYB4MKgP7ujQskODAXPhWK4rsfy/yQEACKC3kavu9G2zySbdm3kNA4AxCTrzfFA4OvBmV495h/iwP5FMITeesQ/vfjeoa46kmVZyLIsDr9UR/7A4rtEFNFbFf9br4TwMAA4dbS5r+9kl+g72SVOHW3uK/Q9LEgIQQCU08fbb5w+3n4DgKK/ER4RW/9UC6BWtx+ZbFuEt2t6INnfINDIdW9GrLUAAAAASUVORK5CYII='  # the crest, header size

SHORTCUT_PS = r"""
$s = New-Object -ComObject WScript.Shell
$made = @()
foreach ($d in @([Environment]::GetFolderPath('Programs'), [Environment]::GetFolderPath('Desktop'))) {
  if (-not $d) { continue }
  $p = Join-Path $d 'AoE2 Wingman.lnk'
  if ($env:WM_ONLY_FIX -eq '1') {
    if (-not (Test-Path $p)) { continue }
    if ($s.CreateShortcut($p).TargetPath -eq $env:WM_EXE) { continue }
  }
  $l = $s.CreateShortcut($p)
  $l.TargetPath = $env:WM_EXE
  $l.WorkingDirectory = Split-Path $env:WM_EXE
  $l.IconLocation = $env:WM_EXE + ',0'
  $l.Description = 'AoE2 Wingman: build orders and scouting on top of Age of Empires II'
  $l.Save()
  $made += $p
}
$made -join '|'
"""

def make_shortcuts(only_fix=False):
    """Start menu and Desktop shortcuts to the exe, so it is easy to find again and can be pinned
    (Windows does not let a program pin itself to the taskbar; the Start menu entry is what you
    right-click to pin it). only_fix just repoints shortcuts that already exist at this exe, for
    when it has been moved. Returns the shortcuts written."""
    if not FROZEN or os.name != 'nt': return []
    import subprocess
    env = dict(os.environ, WM_EXE=os.path.abspath(sys.executable), WM_ONLY_FIX='1' if only_fix else '0')
    try:
        r = subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
                            '-Command', SHORTCUT_PS], env=env, capture_output=True, text=True,
                           timeout=30, creationflags=0x08000000)
        made = [x for x in (r.stdout or '').strip().split('|') if x]
        if made: log('shortcuts: %s' % ', '.join(made))
        if r.returncode: log('shortcuts: %s' % (r.stderr or '').strip()[-300:])
        return made
    except Exception as e:
        log('shortcuts: %r' % (e,))
        return []

def restart_app(bat):
    """Start the given copy. The caller closes this one straight after."""
    import subprocess
    log('restarting from %s' % bat)
    # --wait-turn: the new copy waits for this one to close instead of seeing it still running and
    # bowing out (which is what left 'Update from dev' closed with nothing coming back)
    subprocess.Popen(['cmd', '/c', bat, '--wait-turn'], cwd=os.path.dirname(bat),
                     creationflags=0x08000000, close_fds=True)

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

def tag_parts(entry):
    """A saved Discord tag: 'Name|123456789012345678', a bare user ID, or just a name.
    Returns (name to show, user ID or '')."""
    n = (entry or '').strip()
    if '|' in n:
        nm, uid = n.split('|', 1); return nm.strip(), re.sub(r'\D', '', uid)
    if re.fullmatch(r'<@!?\d+>', n) or re.fullmatch(r'\d{15,21}', n):
        uid = re.sub(r'\D', '', n); return 'Discord user \u2026' + uid[-4:], uid
    return n.lstrip('@'), ''

def mention(name):
    n = name.strip()
    if '|' in n:                                                      # 'Name|ID' from Settings
        nm, uid = tag_parts(n)
        return '<@%s>' % uid if uid else '@' + nm
    if re.fullmatch(r'\d{15,21}', n): return '<@%s>' % n            # a Discord user ID pings them
    if re.fullmatch(r'<@!?\d+>', n): return n
    return '@' + n.lstrip('@')

def discord_tags(cfg, only=None):
    """Who to tag in Discord: each friend on the party list with a Discord ID (or name) set, or just
    the ones in `only`. Older settings kept a separate tag list; that is used if no friend has one."""
    dmap = {k.lower(): v for k, v in (cfg.get('friend_discord') or {}).items() if str(v).strip()}
    names = [f for f in (only if only is not None else cfg.get('friends', [])) if f.strip()]
    tags = [dmap[f.lower()] for f in names if f.lower() in dmap]
    if not dmap and only is None: tags = [p_ for p_ in cfg.get('pings', []) if p_.strip()]
    return tags

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

def pid_elevated(pid):
    """True if that process runs as administrator. A process we cannot even look at counts as elevated."""
    ctypes, wintypes, u, k = _win()
    a = ctypes.windll.advapi32
    k.OpenProcess.restype = ctypes.c_void_p; k.CloseHandle.argtypes = [ctypes.c_void_p]
    a.OpenProcessToken.argtypes = [ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(ctypes.c_void_p)]
    a.GetTokenInformation.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD)]
    hp = k.OpenProcess(0x1000, False, pid)
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

def window_elevated(h):
    """True if the game runs as administrator. Windows then blocks clicks from normal programs."""
    ctypes, wintypes, u, k = _win()
    pid = wintypes.DWORD(); u.GetWindowThreadProcessId(h, ctypes.byref(pid))
    return pid_elevated(pid.value)

def overlay_is_admin():
    try:
        import ctypes
        return bool(ctypes.windll.shell32.IsUserAnAdmin())
    except Exception:
        return False

def game_needs_admin():
    """The game's window if it runs as administrator and this app does not, so our clicks would be
    thrown away. None when the clicks will get through (or there is no game to click)."""
    if overlay_is_admin(): return None
    h = find_game_window()
    return h if h and window_elevated(h) else None

# ---- why the game runs as administrator, and undoing it
# The game only needs admin because something asked for it: a "Run this program as an administrator"
# tick on the game or on Steam (the game inherits Steam's), or Steam having been started that way.
# The ticks live in the registry. Your own ones (HKCU) can be cleared without admin. Ticked
# "for all users" ones (HKLM) need admin, so for those the app says where to untick them.
LAYERS = r'Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers'
ADMIN_EXES = ('aoe2de_s.exe', 'aoe2de.exe', 'steam.exe')

def admin_flags():
    """[(hive, program path, flags)] for each run-as-admin tick on the game or Steam."""
    import winreg
    out = []
    for hive in (winreg.HKEY_CURRENT_USER, winreg.HKEY_LOCAL_MACHINE):
        try: key = winreg.OpenKey(hive, LAYERS, 0, winreg.KEY_READ | winreg.KEY_WOW64_64KEY)
        except OSError: continue
        with key:
            i = 0
            while True:
                try: name, data, _ = winreg.EnumValue(key, i)
                except OSError: break
                i += 1
                if os.path.basename(name).lower() in ADMIN_EXES and 'RUNASADMIN' in str(data).upper().split():
                    out.append((hive, name, str(data)))
    return out

def clear_admin_flags():
    """Untick run-as-admin on the game and Steam for this Windows user. Leaves any other
    compatibility settings on those programs alone. Returns (cleared, left) program paths;
    'left' are the all-users ticks that need admin to change."""
    import winreg
    cleared, left = [], []
    for hive, name, data in admin_flags():
        if hive != winreg.HKEY_CURRENT_USER and not overlay_is_admin():
            left.append(name); continue
        rest = [t for t in data.split() if t.upper() != 'RUNASADMIN']
        try:
            with winreg.OpenKey(hive, LAYERS, 0, winreg.KEY_SET_VALUE | winreg.KEY_WOW64_64KEY) as key:
                if [t for t in rest if t not in ('~', '$')]: winreg.SetValueEx(key, name, 0, winreg.REG_SZ, ' '.join(rest))
                else: winreg.DeleteValue(key, name)
            cleared.append(name); log('cleared run-as-admin on %s' % name)
        except OSError as e:
            log('could not clear run-as-admin on %s: %r' % (name, e)); left.append(name)
    return cleared, left

def _pids_named(exe):
    ctypes, wintypes, u, k = _win()
    arr = (wintypes.DWORD * 4096)(); got = wintypes.DWORD()
    if not ctypes.windll.psapi.EnumProcesses(arr, ctypes.sizeof(arr), ctypes.byref(got)): return []
    return [p for p in arr[:got.value // 4] if p and _proc_name(p) == exe]

def why_game_is_admin():
    """(one line on why, whether 'Fix it' can clear it without admin)."""
    import winreg
    try: flags = admin_flags()
    except Exception as e: log('admin flag check: %r' % (e,)); flags = []
    mine = [n for h, n, _ in flags if h == winreg.HKEY_CURRENT_USER]
    whose = lambda names: 'Steam' if any(os.path.basename(n).lower() == 'steam.exe' for n in names) else 'the game'
    if mine:
        return ('Windows is set to always run %s as administrator.' % whose(mine), True)
    if flags:
        return ('Windows is set to always run %s as administrator, for every user on this PC. To stop that, right '
                'click it, choose Properties > Compatibility > Change settings for all users, and untick '
                '"Run this program as an administrator".' % whose([n for _, n, _ in flags]), False)
    try: steam_up = any(pid_elevated(p) for p in _pids_named('steam.exe'))
    except Exception: steam_up = False
    if steam_up:
        return ('Steam was started as administrator, so the game was too. Close Steam fully and open it '
                'normally next time.', False)
    return ('The game is running as administrator.', False)

def relaunch_as_admin(resume=''):
    """Start this copy again as administrator (Windows asks you first), then carry on with 'resume'.
    True once you said yes; the caller closes this copy straight after."""
    import ctypes
    exe = sys.executable
    if FROZEN:                                   # Wingman.exe starts itself, no Python in front of it
        args = '--wait-turn' + (' --resume %s' % resume if resume else '')
    else:
        w = os.path.join(os.path.dirname(exe), 'pythonw.exe')
        if os.path.isfile(w): exe = w
        args = '-x "%s" --wait-turn' % self_path() + (' --resume %s' % resume if resume else '')
    old_env = None
    if FROZEN:
        # The new copy picks up this one's environment. Left as it is, it would run out of this copy's
        # temp folder, and this one could not clear that folder when it closes ('Failed to remove
        # temporary directory'). We are about to close anyway, so clean our own environment first.
        # (Worked out before clearing, or there would be nothing left to clean; put back if you say no.)
        old_env, new_env = dict(os.environ), clean_env()
        os.environ.clear(); os.environ.update(new_env)
        try: ctypes.windll.kernel32.SetDllDirectoryW(None)
        except Exception: pass
    se = ctypes.windll.shell32.ShellExecuteW
    se.restype = ctypes.c_void_p
    se.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_int]
    r = se(None, 'runas', exe, args, os.path.dirname(self_path()), 1) or 0
    log('restart as admin: %s' % ('ok' if r > 32 else 'declined or failed (%d)' % r))
    if r <= 32 and old_env is not None:                  # staying: our own environment back as it was
        os.environ.clear(); os.environ.update(old_env)
    return r > 32

ADMIN_MSG = ("The game runs as administrator, so Windows won't let Wingman click it. "
             "Press the button again and Wingman will offer to restart as admin.")

def focus_window(h):
    """Bring the game to the front. Windows blocks this unless we look like the user, so tap Alt first."""
    ctypes, wintypes, u, _ = _win()
    if u.IsIconic(h): u.ShowWindow(h, 9)
    for _ in range(3):
        u.keybd_event(0x12, 0, 0, 0); u.keybd_event(0x12, 0, 2, 0)          # Alt down/up
        u.ShowWindow(h, 5); u.BringWindowToTop(h); u.SetForegroundWindow(h)
        for _i in range(8):                                                 # up to 0.4s, but no longer than it takes
            time.sleep(0.05)
            if u.GetForegroundWindow() == h: return True
    log('could not bring a window to the front')
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

# ---------------------------------------------------------------- Go Live
# One button for "hang on, let me stream this": pause, say sorry in chat, put the game up on
# Discord, come back and say thanks. It only runs when you press it. In the game it sends the
# pause key and two lines of chat, nothing else; everything else happens in Discord.
KEY_NAMES = dict([('F%d' % i, 0x6F + i) for i in range(1, 13)] +
                 [('PAUSE', 0x13), ('ENTER', 0x0D), ('ESC', 0x1B), ('SPACE', 0x20),
                  ('CTRL', 0x11), ('CONTROL', 0x11), ('CTL', 0x11),
                  ('SHIFT', 0x10), ('ALT', 0x12)])
MODIFIERS = (0x10, 0x11, 0x12)
LIVE_DEFAULTS = {'live_pause_key': 'CTRL+F3', 'live_before': 'Sorry 1 sec', 'live_after': 'Thanks 14?'}
DISCORD_EXES = ('discord.exe', 'discordptb.exe', 'discordcanary.exe')

def _send_keys(events):
    """events: (vk, scan, flags) tuples, sent as one batch so nothing can land in between."""
    ctypes, wintypes, u, _ = _win()
    class KI(ctypes.Structure):
        _fields_ = [('wVk', wintypes.WORD), ('wScan', wintypes.WORD), ('dwFlags', wintypes.DWORD),
                    ('time', wintypes.DWORD), ('dwExtraInfo', ctypes.c_size_t)]
    class INP(ctypes.Structure):
        class _U(ctypes.Union):
            _fields_ = [('ki', KI), ('pad', ctypes.c_byte * 32)]
        _anonymous_ = ('u',)
        _fields_ = [('type', wintypes.DWORD), ('u', _U)]
    arr = (INP * len(events))()
    for i, (vk, scan, fl) in enumerate(events):
        arr[i].type = 1; arr[i].ki = KI(vk, scan, fl, 0, 0)
    return u.SendInput(len(events), arr, ctypes.sizeof(INP))

def tap_key(vk):
    """A key press the way a keyboard sends it, by scan code, which is what games listen to."""
    ctypes, wintypes, u, _ = _win()
    scan = u.MapVirtualKeyW(vk, 0)
    _send_keys([(vk, scan, 0x0008), (vk, scan, 0x0008 | 0x0002)])
    time.sleep(0.06)

def combo_ok(spec):
    """True when every part of 'CTRL+F3' style text is a key this knows."""
    parts = [p.strip().upper() for p in re.split(r'[+\s]+', str(spec)) if p.strip()]
    return bool(parts) and all(p in KEY_NAMES or (len(p) == 1 and p.isalnum()) for p in parts)

def tap_combo(spec):
    """'CTRL+F3' and the like: hold the modifiers, tap the key, let go in reverse order."""
    ctypes, wintypes, u, _ = _win()
    parts = [p.strip().upper() for p in re.split(r'[+\s]+', str(spec)) if p.strip()]
    vks = [KEY_NAMES[p] if p in KEY_NAMES else (ord(p) if len(p) == 1 and p.isalnum() else None)
           for p in parts]
    if not vks or None in vks:
        log('go live: did not understand the pause key %r, using Ctrl+F3' % (spec,))
        vks = [0x11, 0x72]
    mods = [v for v in vks if v in MODIFIERS]; keys = [v for v in vks if v not in MODIFIERS] or [0x72]
    ev = lambda v, up: (v, u.MapVirtualKeyW(v, 0), 0x0008 | (0x0002 if up else 0))
    _send_keys([ev(m, False) for m in mods]); time.sleep(0.04)
    for k_ in keys:
        _send_keys([ev(k_, False)]); time.sleep(0.04); _send_keys([ev(k_, True)])
    time.sleep(0.04); _send_keys([ev(m, True) for m in reversed(mods)])
    time.sleep(0.06)

def type_text(text):
    for ch in text:
        _send_keys([(0, ord(ch), 0x0004), (0, ord(ch), 0x0004 | 0x0002)])
        time.sleep(0.018)

def game_chat(text):
    """Enter, the line, Enter: the same as typing it yourself."""
    if not text.strip(): return
    tap_key(0x0D); time.sleep(0.25)
    type_text(text); time.sleep(0.12)
    tap_key(0x0D); time.sleep(0.2)

def find_discord_window():
    """Discord's main window. Not its in-game overlay, which is also a Discord window, sits over
    the whole game and is the biggest one it has, but is see-through and has no share button."""
    ctypes, wintypes, u, _ = _win()
    u.GetWindowLongW.restype = ctypes.c_long
    hits = []
    proto = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(h, l):
        if not u.GetWindow(h, 4) and (u.IsWindowVisible(h) or u.IsIconic(h)):
            pid = wintypes.DWORD(); u.GetWindowThreadProcessId(h, ctypes.byref(pid))
            if _proc_name(pid.value) in DISCORD_EXES:
                n = u.GetWindowTextLengthW(h)
                b = ctypes.create_unicode_buffer(n + 1); u.GetWindowTextW(h, b, n + 1)
                title = b.value.strip()
                ex = u.GetWindowLongW(h, -20)                      # extended style
                if not title or 'overlay' in title.lower() or 'updater' in title.lower(): return True
                if ex & 0x80 or ex & 0x20: return True             # tool window, or click-through
                r = wintypes.RECT(); u.GetWindowRect(h, ctypes.byref(r))
                main = title == 'Discord' or title.endswith(' - Discord')
                hits.append((main, (r.right - r.left) * (r.bottom - r.top), h, title))
        return True
    u.EnumWindows(proto(cb), 0)
    if not hits: return None
    best = max(hits)
    log('go live: Discord window "%s"' % best[3])
    return best[2]

def ensure_pkg(mod, pip_name=None, why=''):
    """Import a module, installing it for this user the first time if it is missing."""
    import importlib
    try: return importlib.import_module(mod)
    except ImportError: pass
    try:
        import subprocess, site
        exe = sys.executable
        if exe.lower().endswith('pythonw.exe'): exe = exe[:-11] + 'python.exe'
        log('installing %s%s' % (pip_name or mod, (' for ' + why) if why else ''))
        if FROZEN: raise RuntimeError('the exe has this built in already')
        subprocess.run([exe, '-m', 'pip', 'install', '--user', '--disable-pip-version-check', '-q',
                        pip_name or mod], creationflags=0x08000000, timeout=600, capture_output=True)
        usp = site.getusersitepackages()
        if usp not in sys.path: sys.path.append(usp)
        importlib.invalidate_caches()
        return importlib.import_module(mod)
    except Exception as e:
        log('could not get %s: %r' % (mod, e))
        return None

class LiveFail(Exception): pass

LIVE_CANCEL = threading.Event()          # set when Go Live gives up, so a slow Discord step stops clicking

def front_is(names):
    """True if the window in front belongs to a program whose name starts with one of names."""
    try:
        ctypes, wintypes, u, _ = _win()
        fg = u.GetForegroundWindow()
        pid = wintypes.DWORD(); u.GetWindowThreadProcessId(fg, ctypes.byref(pid))
        n_ = _proc_name(pid.value).lower()
        return any(n_.startswith(x) for x in names)
    except Exception:
        return False

def _uia_find(auto, root, match, wait=6.0, depth=60):
    """The first control under root that match(control) likes. Discord is a Chromium app: its
    controls only show up to Windows' accessibility once something asks, so the first look can
    come back nearly empty. Keep looking for a few seconds."""
    seen, end = [], time.time() + wait
    while True:
        seen = []
        try:
            for c, _d in auto.WalkControl(root, maxDepth=depth):
                try: name = c.Name or ''
                except Exception: continue
                if name: seen.append(name)
                try:
                    if match(c, name): return c, seen
                except Exception: pass
        except Exception as e:
            log('go live, looking through Discord: %r' % (e,))
        if time.time() > end: return None, seen
        time.sleep(0.4)

def _uia_press(c):
    for how in ('GetInvokePattern', 'GetSelectionItemPattern', 'GetLegacyIAccessiblePattern'):
        try:
            p = getattr(c, how)()
            if not p: continue
            if how == 'GetInvokePattern': p.Invoke()
            elif how == 'GetSelectionItemPattern': p.Select()
            else: p.DoDefaultAction()
            return True
        except Exception:
            continue
    try:
        c.Click(simulateMove=False); return True
    except Exception:
        return False

def _discord_windows():
    """Every top-level Discord window that is showing: the main one, and any picker or pop-out it
    opens in a window of its own. The in-game overlay is left out."""
    ctypes, wintypes, u, _ = _win()
    out = []
    proto = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    def cb(h, l):
        if u.IsWindowVisible(h):
            pid = wintypes.DWORD(); u.GetWindowThreadProcessId(h, ctypes.byref(pid))
            if _proc_name(pid.value) in DISCORD_EXES:
                n = u.GetWindowTextLengthW(h)
                b = ctypes.create_unicode_buffer(n + 1); u.GetWindowTextW(h, b, n + 1)
                if 'overlay' not in b.value.lower(): out.append((h, b.value))
        return True
    u.EnumWindows(proto(cb), 0)
    return out

def _uia_all(auto, depth=60):
    """(control, name) for everything in every Discord window."""
    out = []
    for h, _t in _discord_windows():
        try: root = auto.ControlFromHandle(h)
        except Exception: continue
        try:
            for c, _d in auto.WalkControl(root, maxDepth=depth):
                try: out.append((c, c.Name or ''))
                except Exception: pass
        except Exception as e:
            log('go live, reading Discord: %r' % (e,))
    return out

def _uia_names(auto, root=None, depth=60):
    return [n for _c, n in _uia_all(auto, depth) if n]

def _uia_wait(auto, match, wait=6.0):
    """Keep looking through Discord's windows until match(control, name) likes one."""
    end = time.time() + wait
    while True:
        for c, n in _uia_all(auto):
            try:
                if match(c, n): return c
            except Exception: pass
        if time.time() > end: return None
        time.sleep(0.4)

def _uia_fast(auto, names):
    """The first control in any Discord window whose name is exactly one of names. Asks Windows
    to do the search itself in one go, which is many times quicker than walking Discord's whole
    window from Python (its chat history alone is thousands of entries). None if not there."""
    try:
        import importlib
        core = importlib.import_module(auto.__name__ + '.uiautomation')   # the private bits live in here
        ia = core._AutomationClient.instance().IUIAutomation
        conds = [ia.CreatePropertyCondition(30005, n) for n in names]      # 30005: the name
        cond = conds[0]
        for c_ in conds[1:]: cond = ia.CreateOrCondition(cond, c_)
        for h, _t in _discord_windows():
            root = ia.ElementFromHandle(h)
            el = root.FindFirst(4, cond)                                      # 4: everything under it
            if el:
                c = core.Control.CreateControlFromElement(el)
                if c and _visible(c): return c
    except Exception as e:
        log('go live, quick search: %r' % (e,))
    return None

def _uia_fast_wait(auto, names, wait=4.0):
    end = time.time() + wait
    while True:
        c = _uia_fast(auto, names)
        if c or time.time() > end: return c
        time.sleep(0.12)

def _uia_click(c):
    """A real left click in the middle of the control, for when asking it nicely does nothing."""
    try:
        # only ever a click on Discord itself: never if Go Live has given up, or the game is in front
        if LIVE_CANCEL.is_set() or not front_is(('discord',)):
            log('go live: Discord is not in front, so no click'); return False
        r = c.BoundingRectangle
        if r.right - r.left < 2 or r.bottom - r.top < 2: return False
        x, y = (r.left + r.right) // 2, (r.top + r.bottom) // 2
        _move_to(x, y)
        _send_mouse(0x0002); time.sleep(0.05); _send_mouse(0x0004)
        return True
    except Exception as e:
        log('go live, click: %r' % (e,))
        return False

def _bg_click(top, c):
    """Click a control in Discord without bringing Discord to the front: the click is posted
    straight to the part of the window Chromium draws into, so the game keeps the screen."""
    try:
        ctypes, wintypes, u, _ = _win()
        r = c.BoundingRectangle
        if r.right - r.left < 2 or r.bottom - r.top < 2: return False
        pt = wintypes.POINT((r.left + r.right) // 2, (r.top + r.bottom) // 2)
        kids = []
        proto = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        def cb(h, l):
            b = ctypes.create_unicode_buffer(64); u.GetClassNameW(h, b, 64)
            if b.value == 'Chrome_RenderWidgetHostHWND': kids.append(h)
            return True
        u.EnumChildWindows(top, proto(cb), 0)
        target = kids[0] if kids else top
        u.ScreenToClient(target, ctypes.byref(pt))
        lp = (pt.y & 0xFFFF) << 16 | (pt.x & 0xFFFF)
        u.PostMessageW.argtypes = [wintypes.HWND, wintypes.UINT, wintypes.WPARAM, wintypes.LPARAM]
        u.PostMessageW(target, 0x0200, 0, lp)                 # move
        time.sleep(0.03)
        u.PostMessageW(target, 0x0201, 1, lp)                 # left down
        time.sleep(0.05)
        u.PostMessageW(target, 0x0202, 0, lp)                 # left up
        return True
    except Exception as e:
        log('go live, background click: %r' % (e,))
        return False

def _keep_behind(h):
    """Un-minimise a window without it taking focus or coming over the game."""
    try:
        ctypes, wintypes, u, _ = _win()
        if u.IsIconic(h): u.ShowWindow(h, 4)                  # restore, no activate
        u.SetWindowPos(h, 1, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010)   # to the bottom, keep size, no activate
    except Exception as e:
        log('go live, keep behind: %r' % (e,))

def _rid(c):
    """Something that tells one control from another with the same name."""
    try:
        r = c.GetRuntimeId()
        if r: return tuple(r)
    except Exception: pass
    try:
        b = c.BoundingRectangle
        return (c.Name, c.ControlTypeName, b.left, b.top, b.right, b.bottom)
    except Exception:
        return (id(c),)

def _visible(c):
    try:
        if c.IsOffscreen: return False
        r = c.BoundingRectangle
        return r.right - r.left > 2 and r.bottom - r.top > 2
    except Exception:
        return True

def discord_channel_link(text):
    """(server, channel) from a Discord channel link, or None."""
    m = re.search(r'channels/(\d{5,25})/(\d{5,25})', str(text or ''))
    return (m.group(1), m.group(2)) if m else None

def discord_join_channel(auto):
    """Not in a call? Join the voice channel picked in Settings, so there is something to stream to.
    In a call already (Discord shows a Disconnect button), or no channel picked: leave it be."""
    want = str(load_settings().get('live_channel') or '').strip()
    if not want: return False
    link = discord_channel_link(want)
    if _uia_fast_wait(auto, ['Disconnect'], wait=1.5):
        log('go live: already in a call, not joining the set channel'); return False
    log('go live: not in a call, joining the set voice channel')
    if link:
        try:
            os.startfile('discord://-/channels/%s/%s' % link)      # Discord opens the channel itself
        except Exception as e:
            log('go live, open channel: %r' % (e,)); return False
    else:
        # by name: the voice channel in the server list on screen ('Name (voice channel), 2 users')
        nm = want.lstrip('#').strip().lower()
        hit = None
        for c, n in _uia_all(auto):
            l_ = n.strip().lower()
            if (l_ == nm or l_.startswith(nm + ' ') or l_.startswith(nm + ',')) and 'voice' in l_:
                hit = c; break
        if hit is not None:
            for fn in (_uia_click, _uia_press):
                try:
                    if fn(hit): break
                except Exception as e:
                    log('go live, channel click: %r' % (e,))
        else:
            # Not on screen (Discord is on your friends list, say): Discord's own quick switcher.
            # Ctrl+K, then '!' and the name lists only voice channels, and Enter joins the top one.
            log('go live: "%s" is not on screen, using the quick switcher' % want)
            try:
                d_ = find_discord_window()
                if d_: focus_window(d_); time.sleep(0.2)
                if LIVE_CANCEL.is_set() or not front_is(('discord',)):
                    log('go live: Discord did not come to the front, so nothing was typed'); return False
                tap_combo('CTRL+K'); time.sleep(0.7)
                if not front_is(('discord',)): return False
                type_text('!' + want.lstrip('#!').strip()); time.sleep(1.2)
                if not front_is(('discord',)): return False
                tap_key(0x0D)
            except Exception as e:
                log('go live, quick switcher: %r' % (e,)); return False
    joined = _uia_fast_wait(auto, ['Disconnect'], wait=3)           # some versions join straight away
    if not joined:
        btn = _uia_fast_wait(auto, ['Join Voice', 'Join Voice Channel', 'Join Call'], wait=6)
        if btn:
            for fn in (_uia_click, _uia_press):
                try:
                    if fn(btn) and _uia_fast_wait(auto, ['Disconnect'], wait=4): joined = True; break
                except Exception as e:
                    log('go live, join: %r' % (e,))
    log('go live: %s the voice channel' % ('joined' if joined else 'could not join'))
    if joined: time.sleep(1.0)                                    # the call panel and its buttons settle
    return bool(joined)

def discord_share_game():
    """In Discord: Share Your Screen, the Applications tab, Age of Empires II, Go Live. Works off
    the call you are already in, whether that is a server voice channel or a DM call; Discord
    keeps the share button for it in the panel at the bottom left."""
    auto = ensure_pkg('uiautomation', why='the Go Live button')
    if not auto: raise LiveFail('could not load the Windows accessibility helper (pip install uiautomation)')
    d = find_discord_window()
    if not d:
        # closed to the tray: starting Discord again just brings its window back
        up = os.path.join(os.environ.get('LOCALAPPDATA', ''), 'Discord', 'Update.exe')
        if os.path.isfile(up):
            import subprocess
            subprocess.Popen([up, '--processStart', 'Discord.exe'], creationflags=0x08000000)
            for _ in range(20):
                time.sleep(0.4); d = find_discord_window()
                if d: break
    if not d: raise LiveFail('could not find the Discord window. Open Discord and join a call first.')
    # Try it all without leaving the game first: Discord stays behind and gets its clicks posted
    # to it. Only if Discord will not take them that way does it come to the front for a moment.
    # The game sits over everything while it is full screen, so Discord can be told to come to
    # the front and still not be seen. Do what Alt+Tab does instead: put the game down to the
    # taskbar, bring Discord up, and once it is streaming put the game straight back.
    g = find_game_window()
    if g and not _win()[2].IsIconic(g):
        _win()[2].ShowWindow(g, 6)                         # minimise
        time.sleep(0.25)
    focus_window(d)
    mode = {'bg': False}
    def click(c):
        if mode['bg']: return _bg_click(d, c)
        return _uia_click(c)
    BUTTONS = ('ButtonControl', 'TabItemControl', 'ListItemControl', 'HyperlinkControl',
               'RadioButtonControl', 'MenuItemControl')
    def named(*want):
        w = [x.lower() for x in want]
        return lambda c, n: n.strip().lower() in w and c.ControlTypeName in BUTTONS

    GO_NAMES = ('Go Live', 'Go live', 'Stream')
    try:
        game_title = 'Age of Empires II: Definitive Edition'
        gw = find_game_window()
        if gw:
            u_ = _win()[2]; n_ = u_.GetWindowTextLengthW(gw)
            import ctypes as _ct
            b_ = _ct.create_unicode_buffer(n_ + 1); u_.GetWindowTextW(gw, b_, n_ + 1)
            if b_.value.strip(): game_title = b_.value.strip()
    except Exception:
        pass
    discord_join_channel(auto)
    # the quick way: Discord's own button for streaming the game, by its exact name
    if _uia_fast(auto, ['Stop Streaming']):
        log('go live: already streaming, nothing to start'); return
    t_ = time.time()
    quick = _uia_fast(auto, ['Stream ' + game_title, 'Stream ' + game_title.split(':')[0]])
    if quick:
        log('go live: found "%s" in %.1fs' % (quick.Name, time.time() - t_))
        def press(ctrl, until, label):
            """Press it, and if nothing happens, press it another way: a real click, then
            Windows' own 'press this', then a click sent straight to Discord. Discord does not
            always answer the first."""
            for how, fn in (('click', _uia_click), ('invoke', _uia_press), ('direct', lambda c: _bg_click(d, c))):
                try:
                    if not fn(ctrl): continue
                except Exception as e:
                    log('go live, %s %s: %r' % (how, label, e)); continue
                got = _uia_fast_wait(auto, until, wait=1.5)
                if got:
                    log('go live: %s took (%s)' % (label, how)); return got
            return None
        got = press(quick, list(GO_NAMES) + ['Stop Streaming'], 'the game stream button')
        if got and got.Name != 'Stop Streaming':
            got = press(got, ['Stop Streaming'], 'Stream')
        if got:
            log('go live: sharing Age of Empires II on Discord (quick way, %.1fs)' % (time.time() - t_)); return
        log('go live: the quick way did not start a stream, looking the slow way')
        try:
            n_ = discord_dump(os.path.join(os.path.dirname(LOG), 'discord_dump.txt'))
            log('go live: wrote what Discord showed (%d controls) to discord_dump.txt' % n_)
        except Exception as e:
            log('go live, dump: %r' % (e,))

    everything = _uia_all(auto)
    if any(n.strip().lower() == 'stop streaming' for _c, n in everything):
        log('go live: already streaming, nothing to start')
        return
    # Discord knows AoE2 as a game, and when it is running the call panel has its own button to
    # stream it straight away. That skips the picker altogether.
    def game_stream(c, n):
        l = n.strip().lower()
        return l.startswith('stream') and 'age of empires' in l and c.ControlTypeName in BUTTONS
    gs = [c for c, n in everything if game_stream(c, n)]
    live_now = lambda c, n: n.strip().lower() == 'stop streaming'
    go_live_btn = named(*GO_NAMES)                        # Discord labels it either way

    def front():
        """Discord did not take it from behind (it can stop drawing while the game covers it):
        bring it up for the rest of the steps."""
        if mode['bg']:
            log('go live: Discord did not react from behind the game, bringing it up')
            mode['bg'] = False
        focus_window(d); time.sleep(0.4)

    def press_go_live(wait=5):
        """Find Go Live and press it, from behind first and then up front. True once live."""
        go = _uia_wait(auto, go_live_btn, wait=wait)
        if not go and mode['bg']:
            front(); go = _uia_wait(auto, go_live_btn, wait=4)
        if not go: return False
        if not click(go): _uia_press(go)
        if _uia_wait(auto, live_now, wait=3): return True
        if mode['bg']:
            front()
            go = _uia_wait(auto, go_live_btn, wait=3)
            if go and (_uia_click(go) or _uia_press(go)):
                return bool(_uia_wait(auto, live_now, wait=4))
        return False

    # a Go Live button already up (a stream window left open by an earlier try): just press it
    if any(go_live_btn(c, n) for c, n in everything):
        log('go live: a Go Live button was already open, pressing it')
        if press_go_live(wait=1):
            log('go live: sharing Age of Empires II on Discord'); return

    if gs:
        log('go live: using Discord\'s own "%s" button' % gs[0].Name)
        if not click(gs[0]): _uia_press(gs[0])
        if not _uia_wait(auto, lambda c, n: go_live_btn(c, n) or live_now(c, n), wait=4) and mode['bg']:
            front()
            g2 = [c for c, n in _uia_all(auto) if game_stream(c, n)]
            if g2 and not _uia_wait(auto, go_live_btn, wait=1):
                _uia_click(g2[0]) or _uia_press(g2[0])
        if _uia_wait(auto, live_now, wait=1) or press_go_live(wait=5):
            log('go live: sharing Age of Empires II on Discord (%s)'
                % ('stayed in the game' if mode['bg'] else 'Discord came up')); return
        log('go live: the game stream button did not start a stream, trying the picker')

    # the share button: there can be more than one (the call view and the panel at the bottom
    # left), and some may be out of sight. Try the ones on screen first.
    share_names = named('Share Your Screen', 'Share Screen', 'Share your screen')
    _uia_wait(auto, share_names, wait=8)                  # wakes Discord's accessibility up
    cands = [c for c, n in _uia_all(auto) if share_names(c, n)]
    cands.sort(key=lambda c: not _visible(c))
    if not cands:
        log('go live: no share button. Names Discord showed: %s' % ' | '.join(_uia_names(auto)[:400]))
        raise LiveFail('no Share Your Screen button in Discord. Join a voice channel or call first'
                       + ('.' if str(load_settings().get('live_channel') or '').strip()
                          else ', or pick a channel to join in Settings.'))
    for c in cands:
        try: r = c.BoundingRectangle; where = '%d,%d %dx%d' % (r.left, r.top, r.right - r.left, r.bottom - r.top)
        except Exception: where = '?'
        log('go live: share button %s at %s, on screen %s' % (c.ControlTypeName, where, _visible(c)))

    # Everything already on screen before the click. A friend playing AoE2 shows up in the DM list
    # with the game's name in it, and that is not the thing to click; the game's tile in the
    # picker is new after the click, and its name starts with the game's own window title.
    before = set(_uia_names(auto))
    # the same goes by control, not name: a friend's 'Age of Empires II: Definitive Edition'
    # line is the very same text as the game's tile, so only a control that was not there
    # before the click can be the tile
    aoe_before = set(_rid(c) for c, n in _uia_all(auto) if 'age of empires' in n.lower())
    wins_before = set(h for h, _t in _discord_windows())
    def opened():
        return (set(h for h, _t in _discord_windows()) - wins_before) or \
               [n for n in _uia_names(auto) if n not in before]
    picked = False
    for c in cands[:3]:
        for how in (('background', 'click', 'invoke') if mode['bg'] else ('click', 'invoke')):
            if how == 'background':
                done_ = _bg_click(d, c)
            else:
                if mode['bg']: log('go live: Discord did not take a background click, bringing it up')
                mode['bg'] = False
                focus_window(d); time.sleep(0.3)
                done_ = _uia_click(c) if how == 'click' else _uia_press(c)
            if not done_: continue
            end = time.time() + 3
            while time.time() < end and not opened(): time.sleep(0.3)
            if opened():
                log('go live: share picker opened (%s)' % how); picked = True; break
        if picked: break
    if not picked:
        log('go live: pressing Share changed nothing. Discord windows: %s'
            % ' | '.join(t for _h, t in _discord_windows()))
        raise LiveFail('pressed Share Your Screen but no picker came up.')
    time.sleep(0.6)
    def fresh():
        return [n for n in _uia_names(auto) if n not in before]
    tab = _uia_wait(auto, named('Applications', 'Windows', 'Apps'), wait=2.5)
    if tab and (click(tab) or _uia_press(tab)): time.sleep(0.7)
    def game(c, n):
        l = n.strip().lower()
        return ('age of empires ii' in l and not l.startswith(('stream', 'playing'))
                and c.ControlTypeName != 'WindowControl' and _rid(c) not in aoe_before)
    tile = _uia_wait(auto, game, wait=6)
    if tile:
        # the tile itself if it is there, before the text label inside it
        rank = {'ButtonControl': 0, 'ListItemControl': 0, 'RadioButtonControl': 0, 'GroupControl': 1}
        cands = [c for c, n in _uia_all(auto) if game(c, n)]
        cands.sort(key=lambda c: rank.get(c.ControlTypeName, 2))
        tile = cands[0] if cands else tile
    if not tile:
        log('go live: no AoE2 tile. New in Discord after Share: %s' % ' | '.join(fresh()[:300]))
        try: discord_dump(os.path.join(os.path.dirname(LOG), 'discord_dump.txt'))
        except Exception: pass
        raise LiveFail('Discord did not list Age of Empires II to share.')
    log('go live: picking "%s" (%s)' % (tile.Name, tile.ControlTypeName))
    if not click(tile): _uia_press(tile)
    time.sleep(1.0)
    go = _uia_wait(auto, go_live_btn, wait=6)
    if not go:
        log('go live: no Go Live button. New in Discord after Share: %s' % ' | '.join(fresh()[:300]))
        raise LiveFail('no Go Live button after picking the game.')
    if not click(go): _uia_press(go)
    time.sleep(0.8)
    if mode['bg'] and not _uia_wait(auto, lambda c, n: n.strip().lower() == 'stop streaming', wait=2):
        log('go live: Go Live did not take in the background, pressing it up front')
        focus_window(d); time.sleep(0.3)
        if not _uia_click(go): _uia_press(go)
        time.sleep(0.8)
    log('go live: sharing Age of Empires II on Discord (%s)' % ('stayed in the game' if mode['bg'] else 'Discord came up'))

def discord_dump(path):
    """Write down everything Discord shows to accessibility tools, with type and place, for
    working out what to click when something changes on Discord's side."""
    auto = ensure_pkg('uiautomation', why='the Go Live button')
    if not auto: return 0
    rows = []
    for c, n in _uia_all(auto):
        try:
            r = c.BoundingRectangle
            rows.append('%s\t%s\t%d,%d,%d,%d\t%s' % (c.ControlTypeName, n.replace('\n', ' ')[:200],
                        r.left, r.top, r.right, r.bottom, 'off' if c.IsOffscreen else 'on'))
        except Exception:
            rows.append('?\t%s' % n[:200])
    with open(path, 'w', encoding='utf-8') as fh:
        fh.write('Discord windows: %s\n' % ' | '.join(t for _h, t in _discord_windows()))
        fh.write('\n'.join(rows))
    return len(rows)

def discord_stop():
    """Stop Streaming, for tests."""
    auto = ensure_pkg('uiautomation', why='the Go Live button')
    if not auto: return False
    stop = _uia_wait(auto, lambda c, n: n.strip().lower() == 'stop streaming', wait=3)
    if not stop: return False
    d = find_discord_window()
    if d: focus_window(d); time.sleep(0.3)
    return _uia_click(stop) or _uia_press(stop)

# The game's own cheat codes, typed into chat for you. The game only takes them in single player
# or in a lobby with cheats switched on; ranked turns them off, so this cannot be used there.
CHEATS = [
    ('Resources', [('+1000 food', 'cheese steak jimmy\'s'), ('+1000 wood', 'lumberjack'),
                   ('+1000 gold', 'robin hood'), ('+1000 stone', 'rock on'),
                   ('+100k of everything', 'ninjalui')]),
    ('Map', [('Reveal the map', 'marco'), ('No fog of war', 'polo')]),
    ('Speed', [('Instant build, train, gather', 'aegis')]),
    ('Units', [('Cobra car', 'how do you turn this on'), ('Saboteur', 'to smithereens'),
               ('Monkey boy', 'furious the monkey boy'), ('VDML', 'i love the monkey head'),
               ('Alfred the alpaca', 'alfred the alpaca')]),
    ('End it', [('Win now', 'i r winner'), ('Kill all enemies', 'black death'),
                ('Destroy yourself', 'wimpywimpywimpy')]),
]
GODMODE_WORD = 'GODMODE'

def send_cheat(code):
    """Type one cheat code into the game's chat, the same as you typing it."""
    g = find_game_window()
    if not g: return 'The game is not running.'
    if game_needs_admin(): return 'The game runs as admin: restart Wingman as admin first.'
    focus_window(g); time.sleep(0.2)
    game_chat(code)
    log('godmode: sent "%s"' % code)
    return 'Sent: %s' % code

def game_paused(timer=None):
    """True if the game is paused, False if it is running, None if that could not be told.
    timer() is the Town Center watcher's own say (the game timer it already reads every few
    seconds stops while paused). If it has nothing fresh, the recording is the back-up."""
    try:
        t = timer() if timer else None
        if t is not None:
            log('go live: the game timer is %s' % ('stopped' if t else 'running'))
            return t
    except Exception as e:
        log('go live, timer: %r' % (e,))
    f = LIVE.get('path')
    if f and os.path.isfile(f):
        growing = recording_growing(f, wait=1.5)
        log('go live: no fresh timer reading, the recording is %s' % ('growing' if growing else 'still'))
        return not growing
    return None

def go_live(cfg, in_game=True, status=lambda t: None, timer=None):
    """The whole thing, start to finish. in_game False is the Settings test: Discord only."""
    c = dict(LIVE_DEFAULTS); c.update({k: v for k, v in cfg.items() if k in LIVE_DEFAULTS and v is not None})
    if not combo_ok(c['live_pause_key']):                   # a bad saved value: put the default back for good
        c['live_pause_key'] = LIVE_DEFAULTS['live_pause_key']
        try:
            s_ = load_settings(); s_['live_pause_key'] = c['live_pause_key']; save_settings(s_)
        except Exception: pass
    g = find_game_window()
    LIVE_CANCEL.clear()
    def game_front():
        try: return _win()[2].GetForegroundWindow() == g
        except Exception: return False
    if in_game:
        if not g: raise LiveFail('the game is not running')
        if game_needs_admin(): raise LiveFail(ADMIN_MSG)
        status('pausing'); focus_window(g); time.sleep(0.3)
        if not game_front():
            focus_window(g); time.sleep(0.4)
            if not game_front():                              # keys only ever go to the game
                raise LiveFail('the game would not come to the front, so nothing was pressed')
        # the pause key toggles, so pressing it on a paused game would set it going again
        if game_paused(timer):
            log('go live: the game is already paused, so pause was not pressed')
        else:
            tap_combo(c['live_pause_key']); time.sleep(0.35)
        game_chat(c['live_before'])
    status('Discord')
    try:
        # in a thread of its own: Windows' accessibility helper wants a thread nothing else
        # has set up, and the screen reader can leave this one set the other way
        box = {}
        def run_():
            try: discord_share_game()
            except BaseException as e: box['e'] = e
        th = threading.Thread(target=run_, daemon=True); th.start(); th.join(90)
        if th.is_alive():
            LIVE_CANCEL.set()                                 # whatever it was doing, it stops clicking now
            raise LiveFail('Discord took too long to answer')
        if 'e' in box: raise box['e']
    finally:
        if g and _win()[2].GetForegroundWindow() != g:
            status('back'); time.sleep(0.2); focus_window(g); time.sleep(0.5)
    if in_game:
        if game_front(): game_chat(c['live_after'])
        else: log('go live: the game is not in front, so the second chat line was not sent')

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
                who = ' '.join(mention(f) for f in discord_tags(self.cfg))
                post_discord(url, (who + ' ' if who else '') + 'Jumping on ranked now, come online and accept my party invite.')
                self.say('Ranked has no lobby link, so I posted a heads-up to #%s instead.' % (self.cfg.get('channel') or 'discord'))
                return True
            self.say("Couldn't reach the lobby. Get to the main menu and try again."); return False
        log('lobby %s link %s' % (gid, link))
        url = self.cfg.get('webhook', '').strip()
        if not url:
            self.say('Lobby %s is up. Add your Discord link in settings to post it.' % gid); return True
        post_discord(url, invite_message(link, gid, discord_tags(self.cfg)))
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

BUTTON_WORDS = re.compile(r'(?i)\b(?:i\s*n\s*v\s*i\s*t\s*e|r\s*e\s*t\s*r\s*a\s*c\s*t|c\s*a\s*n\s*c\s*e\s*l)\b')

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
    """Main menu > Multiplayer > Ranked > Invite To Party > Invite each friend on your list who is online.
    Pressed on the screen a finished game leaves you on, it goes back to the main menu first."""
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
        self.l_back, self.l_menu = st(170300, 'Return to Main Menu'), st(9446, 'Main Menu')
        self.l_quit = st(9283, 'Quit to Main Menu')             # the pause menu's one: never clicked
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
                # the strip runs through the row's button too: 'Taizi I NVITE' has to come out as
                # 'Taizi', or the name never matches and the friend is wrongly called offline
                txt = BUTTON_WORDS.sub(' ', txt).replace('\u2022', ' ').strip(' .,|-')
                txt = re.sub(r'\s+', ' ', txt)
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

    def way_back(self, lines):
        """Where to click to get from the end of a game back to the main menu: the game's own
        'Return to Main Menu' button, or one that says just 'Main Menu'. None if neither is up.
        Never the pause menu's 'Quit to Main Menu': with that on screen a game may still be on,
        and clicking it would throw the game away."""
        if find_phrase(lines, self.l_quit): return None
        p = find_phrase(lines, self.l_back)
        if p: return p
        plain = _norm(self.l_menu)
        for t, ws in lines:                                   # a button on its own, not those words inside a sentence
            if ws and _norm(t) == plain:
                return ((min(w[1] for w in ws) + max(w[1] + w[3] for w in ws)) / 2,
                        (min(w[2] for w in ws) + max(w[2] + w[4] for w in ws)) / 2)
        return None

    def wait_menu(self, read, grab, h, clicked, timeout=15.0):
        """After a click on the way back, read the screen until a menu shows. Also stops when a
        different way back turns up (the stats screen has a button of its own), when the same
        one is plainly still sitting there, or when time runs out."""
        t0 = time.time()
        time.sleep(0.25)
        while True:
            check_stop()
            got = self.ocr(read, grab, h)
            if self.state(got[1]) is not None: return got
            p, waited = self.way_back(got[1]), time.time() - t0
            moved = p and abs(p[0] - clicked[0]) + abs(p[1] - clicked[1]) > 40
            if (moved and waited > 1.0) or (p and waited > 4.0) or waited > timeout: return got
            time.sleep(0.1)

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
        unknown, backs = 0, 0
        for step in range(15):
            state = self.state(lines)
            back = self.way_back(lines) if state is None and backs < 3 else None
            if back:                                       # no menu here, but a way back to it: the end of a game
                backs += 1
                log('screen %d (end of game): %s' % (step, ' | '.join(t for t, _ in lines)[:300]))
                self.say('Going back to the main menu...'); log('click at %s' % (back,))
                click(x + back[0] / k, y + back[1] / k)
                (x, y, k), lines = self.wait_menu(read, grab, h, back)     # the menu takes a moment to load
                continue
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
        seen, same, row_names = None, 0, []
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
                    if p:
                        # only on one of the list's rows, left of its buttons: the same name in your
                        # party at the side, or anywhere else on screen, says nothing about them
                        rh_ = rows[0][2] if rows else 30
                        if not rows or p[0] > col or not any(abs(r[0] - p[1]) < max(p[2] or 0, rh_) * 1.2 for r in rows):
                            log('%s: name seen at %s, not on a row of the list, so not used' % (name, (int(p[0]), int(p[1]))))
                            p = None
                if not p: continue
                nx, ny, nh = p
                nh = nh or (rows[0][2] if rows else 30)
                near = [r for r in rows if abs(r[0] - ny) < nh * 1.2]
                status = min(near, key=lambda r: abs(r[0] - ny))[1] if near else 'on'
                missing.remove(name)
                if status == 'off':
                    log('%s is on an offline row (y %d)' % (name, int(ny))); offline.append(name); continue
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
        if offline: parts.append('offline: ' + ', '.join(offline))
        if missing:
            parts.append("couldn't spot " + ', '.join(missing) + ' in the list')
            log('invite: not found in the list: %s (online rows read: %s)' % (', '.join(missing), ' | '.join(
                t for _, t, s_ in row_names if s_ == 'on')))
        self.say(('; '.join(parts) or 'Nobody to invite') + '.')
        url = self.cfg.get('webhook', '').strip()
        if url and invited:
            who = ' '.join(mention(f) for f in discord_tags(self.cfg, only=invited))
            try: post_discord(url, ('%s ' % who if who else '') + 'Ranked party invite sent in game, accept it in AoE2.')
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

SCOUT_DEBUG = os.path.join(GAMES if os.path.isdir(GAMES) else tempfile.gettempdir(), 'scout_debug')

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
    MASK_LOOKS = 3         # the first looks only learn what is always there: the frame, the buttons
    SETTLE = 2.5           # seconds to wait after the game comes back to the front before trusting the picture
    # The game draws markers of its own on the minimap in pure red and yellow, which are player
    # colours too: the blinking cross when something of yours or an ally's is attacked (a boar
    # will do it), and flares. A player's units and buildings sit there solidly; those markers
    # blink and go. So nothing is called until it has been watched for a few seconds.
    # Only red and yellow need that. Every other colour (blue, green, aqua, purple, grey, orange)
    # is never used by the game for a marker, so for those a dot that is there on a few looks in
    # a row is the player. Scouts walk in and out of sight, and making them hold still for
    # seconds was turning real finds away (a green scout sat beside yours for two minutes
    # before the old check let it through).
    BURST = 4              # red and yellow: quick looks in a row, it has to be there on every one
    BURST_GAP = 0.2        # seconds between those looks
    HOLD = 0.8             # then this long again, and it has to still be there
    AFTER = 1              # on this many looks
    SNOOZE = 3             # after a red or yellow came and went, leave that colour alone for this long
    LOOK = 0.3             # seconds between looks at the whole map
    # Only buildings are called, not scouts. A unit is a small dot that walks about; a building is
    # a bigger patch that never moves. So a hit has to be at least building sized and sit in the
    # same spot on a few looks in a row. A scout wandering past is left alone; a house, a camp or a
    # Town Center coming into view is called inside a second or so.
    SEEN = 2               # other colours: the same spot on this many looks in a row (LOOK apart)
    BUILDING = 12          # pixels for the smallest building, on a minimap 616 wide (scaled to yours);
                           # a scout's dot is 4 to 9, so this still leaves scouts alone
    STILL = 3              # how far its middle may drift between looks and still be not moving
    MARKERS = ((254, 0, 0), (255, 255, 1), (255, 0, 0), (255, 255, 0))
    # The minimap is a diamond inside the box that is read. The corners of that box are not map:
    # the game writes its messages there ('Not enough food.' in red, hints in yellow), and those
    # are player colours too. So only what is inside the diamond can be a player, and while a line
    # of writing in a colour is up beside the map, that colour is left alone altogether.
    INSET = 0.97           # how much of the diamond counts: a hair inside its gold edge
    PAD = 0.06             # the slack minimap_rect adds round the map, taken off again here
    BAND, WORDS = 18, 30   # this many pixels of one colour within a strip this tall is a line of writing
    WIDE, TOP = 70, 0.4    # ...or, across the top of the map where the messages run on: this wide, this far down
    EARLY = 15             # seconds: a building's worth of colour this soon was on the map from the start

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
        self.mask_n, self.mask_rect, self.settle = 0, None, 0
        self.snooze, self.hist = {}, {}
        self.diamond, self.area, self.area_for = None, None, None
        self.rec, self.rec_size, self.begun = None, -1, True

    def start_game(self, targets, voices=True, keep=False, recording=None):
        """targets: {colour index: 'Blue'} for the opponents in this game, nobody else.
        keep: the same game carrying on, so colours already called are not called again.
        recording: the game's replay file. It only starts to grow once the match is actually
        running, so until then the loading screen (which shows a little map of its own, with
        every player marked on it) is not looked at."""
        with self.lock:
            self.targets = dict(targets)
            self.found = (self.found & set(targets)) if keep else set()
            self.near, self.mask, self.rect = {}, None, None
            self.mask_n = 0
            self.snooze, self.hist = {}, {}
            self.colours = minimap_colours()
            self.t0 = time.time()
            self.rec = recording
            try: self.rec_size = os.path.getsize(recording) if recording else -1
            except OSError: self.rec_size = -1
            self.begun = bool(keep) or not recording
        if voices and targets:
            def record():
                for name in sorted(set(targets.values())):
                    make_voice('%s found' % name, os.path.join(sound_dir(), '%s.wav' % name.lower()))
            threading.Thread(target=record, daemon=True).start()

    def stop_game(self):
        with self.lock:
            self.targets, self.near = {}, {}                # found is kept: the game may carry on
            self.mask, self.rect = None, None
            self.mask_n = 0

    @staticmethod
    def game_window_in_front():
        """The game's window, but only while it is the one in front. This reads a patch of the
        screen, so with anything else in front (another program, the desktop, the taskbar) that
        patch is not the minimap, and its colours would be taken for players."""
        ctypes, wintypes, u, _ = _win()
        fg = u.GetForegroundWindow()
        if not fg: return None
        pid = wintypes.DWORD(); u.GetWindowThreadProcessId(fg, ctypes.byref(pid))
        return fg if _proc_name(pid.value).startswith('aoe2de') else None

    @staticmethod
    def own_windows():
        """Screen rectangles of this app's own windows that a screen read would pick up. The
        ones Windows is already hiding from screen reads are left out: they cannot be seen
        anyway, and the minimap underneath them still can."""
        ctypes, wintypes, u, _ = _win()
        u.GetWindowDisplayAffinity.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
        mine, out = os.getpid(), []
        proto = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
        def cb(h, l):
            if u.IsWindowVisible(h):
                pid = wintypes.DWORD(); u.GetWindowThreadProcessId(h, ctypes.byref(pid))
                if pid.value == mine:
                    aff = wintypes.DWORD(0)
                    hidden = u.GetWindowDisplayAffinity(h, ctypes.byref(aff)) and aff.value == 0x11
                    r = wintypes.RECT()
                    if not hidden and u.GetWindowRect(h, ctypes.byref(r)):
                        out.append((r.left, r.top, r.right, r.bottom))
            return True
        u.EnumWindows(proto(cb), 0)
        return out

    def own_mask(self, np, w, h):
        """True wherever one of this app's own windows covers the patch being read. Whatever
        the overlay draws there is never a player, even when it is in a player's exact colour."""
        m = np.zeros((h, w), dtype=bool)
        try:
            rx, ry = self.rect[0], self.rect[1]
            for l_, t_, r_, b_ in self.own_windows():
                x0, y0, x1, y1 = max(0, l_ - rx), max(0, t_ - ry), min(w, r_ - rx), min(h, b_ - ry)
                if x1 > x0 and y1 > y0: m[y0:y1, x0:x1] = True
        except Exception as e:
            log('minimap watch, own windows: %r' % (e,))
        return m

    def look_at(self, np, idx, cx, cy, r=28):
        """A fresh look at one spot on the minimap: how many pixels there are in this colour,
        and where their middle is now (a scout moves)."""
        raw, w, h = self.grab(self.rect)
        bgr = np.frombuffer(raw, dtype=np.uint8).reshape(h, w, 4)[:, :, :3].astype(np.int16)
        col = self.colours[idx]
        m = (np.abs(bgr - np.array([col[2], col[1], col[0]], dtype=np.int16)).sum(axis=2) <= self.TOL)
        m &= ~self.own_mask(np, w, h)
        base = (self.mask or {}).get(idx)
        if base is not None and base.shape == m.shape: m &= ~base
        area = self.map_area(np, w, h)
        if self.writing(np, m, area): return 0, cx, cy            # a message in this colour came up over the map
        m &= area
        x0, y0 = max(0, cx - r), max(0, cy - r)
        patch = m[y0:cy + r, x0:cx + r]
        n = int(patch.sum())
        if n:
            ys, xs = np.nonzero(patch)
            cx, cy = int(x0 + xs.mean()), int(y0 + ys.mean())
        return n, cx, cy

    def marker_colour(self, idx):
        """True for the two colours the game also paints its own minimap markers in."""
        col = self.colours.get(idx)
        return bool(col) and any(sum(abs(a - b) for a, b in zip(col, m)) <= self.TOL for m in self.MARKERS)

    def steady(self, np, idx, cx, cy):
        """Watch a hit for a few seconds before believing it. Returns (it stayed, the pixel
        counts seen). It has to be there on every look, about the same size each time, and
        still there after a pause. A marker that blinks, pulses or fades fails one of those."""
        seen = []
        for i in range(self.BURST + self.AFTER):
            time.sleep(self.HOLD if i == self.BURST else self.BURST_GAP)
            if not self.game_window_in_front() or self.pause_fn(): return False, seen
            n, cx, cy = self.look_at(np, idx, cx, cy)
            seen.append(n)
            if n < self.NEED - 2: return False, seen             # it went out
        burst = seen[:self.BURST]
        return min(burst) * 2 >= max(burst), seen                 # and it did not pulse

    def picture(self, np, bgr, cx, cy, name):
        """Keeps a close-up of what was just called or ignored (the last 40), so that a wrong
        call can be looked at afterwards instead of guessed at."""
        try:
            from PIL import Image
            r = 40
            x0, y0 = max(0, cx - r), max(0, cy - r)
            crop = np.ascontiguousarray(bgr[y0:cy + r, x0:cx + r, ::-1].astype(np.uint8))
            os.makedirs(SCOUT_DEBUG, exist_ok=True)
            Image.fromarray(crop).resize((crop.shape[1] * 4, crop.shape[0] * 4), Image.NEAREST).save(
                os.path.join(SCOUT_DEBUG, 'm_%s_%s.png' % (time.strftime('%H%M%S'), name)))
            for f in sorted(glob.glob(os.path.join(SCOUT_DEBUG, 'm_*.png')))[:-40]: os.remove(f)
        except Exception as e:
            log('minimap picture: %r' % (e,))

    def map_area(self, np, w, h):
        """True inside the minimap's diamond, False in the corners of the box round it."""
        if not self.diamond: return np.ones((h, w), dtype=bool)
        if self.area_for != (w, h, self.diamond):
            cx, cy, a, b = self.diamond
            ys, xs = np.mgrid[0:h, 0:w]
            self.area = (np.abs(xs - cx) / float(a) + np.abs(ys - cy) / float(b)) <= self.INSET
            self.area_for = (w, h, self.diamond)
        return self.area

    def writing(self, np, m, area):
        """True when this colour is up as a line of the game's own message text. Beside the map
        (outside the diamond) enough of it in one strip is all it takes: a player is never
        drawn out there. The messages also run on across the top of the map, so up there a
        strip counts when it is long, low and broken up the way letters are, which a scout or
        a building coming into view is not."""
        def line(part, lettered):
            rows = part.sum(axis=1)
            if int(rows.sum()) < self.WORDS: return False
            top = 0
            if len(rows) > self.BAND:
                c = np.cumsum(np.concatenate(([0], rows)))
                sums = c[self.BAND:] - c[:-self.BAND]
                top = int(sums.argmax())
                if int(sums[top]) < self.WORDS: return False
            if not lettered: return True
            cols = np.nonzero(part[top:top + self.BAND].any(axis=0))[0]
            return len(cols) > 0 and int(cols[-1] - cols[0]) >= self.WIDE and len(set((cols // 14).tolist())) >= 5
        if line(m & ~area, False): return True
        return line(m[:int(m.shape[0] * self.TOP)], True)

    def _region(self, h=None):
        h = h or find_game_window()
        if not h: return None
        x, y, w, hh = client_rect(h)
        box = minimap_rect(w, hh)
        if not box: return None
        bx, by, bw, bh = box
        mid = (bx + bw / 2.0, by + bh / 2.0)                      # the map's middle, before the box is cut to the screen
        half = (bw / (2 * (1 + 2 * self.PAD)), bh / (2 * (1 + 2 * self.PAD)))
        bx, by = max(0, bx), max(0, by)
        bw, bh = min(bw, w - bx), min(bh, hh - by)
        if bw < 40 or bh < 20: return None
        self.diamond = (mid[0] - bx, mid[1] - by, half[0], half[1])
        return (x + bx, y + by, bw, bh, 1)

    def run(self):
        if not ensure_numpy():
            log('no numpy, so the opponent spotted alert is off'); return
        import numpy as np
        while True:
            try:
                time.sleep(self.LOOK)
                with self.lock:
                    targets = dict(self.targets)
                    left = [i for i in targets if i not in self.found]
                fg = self.game_window_in_front() if (self.active and left) else None
                if not fg or self.pause_fn():
                    # not looking at the game (or it is loading): whatever is on screen is not the
                    # minimap. Start the confirm count again and give the picture time to settle after.
                    self.near, self.hist = {}, {}; self.settle = time.time() + self.SETTLE
                    continue
                if time.time() < self.settle: continue
                if not self.begun:
                    # the replay has not started to grow, so this is still the loading screen
                    # (four minutes at the outside, in case a recording never grows)
                    try: grown = os.path.getsize(self.rec) > self.rec_size
                    except OSError: grown = True
                    if not grown and time.time() - self.t0 < 240: continue
                    self.begun = True
                    self.mask, self.mask_n, self.near, self.hist = None, 0, {}, {}   # learn the real screen, not the loading one
                    self.t0 = time.time(); self.settle = time.time() + self.SETTLE
                    continue
                if self.grab is None: self.grab = _grabber()
                if self.rect is None:
                    self.rect = self._region(fg)
                    if self.rect is None: continue
                if self.rect != self.mask_rect:           # the window moved or changed size: learn it again
                    self.mask, self.mask_n, self.mask_rect = None, 0, self.rect
                raw, w, h = self.grab(self.rect)
                a = np.frombuffer(raw, dtype=np.uint8).reshape(h, w, 4)[:, :, :3].astype(np.int16)
                bgr = a                                   # the grab hands back B, G, R
                ours = self.own_mask(np, w, h)            # the overlay is never a player
                area = self.map_area(np, w, h)            # nor is anything outside the map's own diamond
                hits = {}
                for idx in left:
                    col = self.colours.get(idx)
                    if not col: continue
                    want = np.array([col[2], col[1], col[0]], dtype=np.int16)
                    m = (np.abs(bgr - want).sum(axis=2) <= self.TOL)
                    hits[idx] = m & ~ours
                if self.mask_n < self.MASK_LOOKS:         # the first few looks: anything already showing
                    if self.mask is None: self.mask = {}  # is part of the UI, not a player
                    for i, m in hits.items():
                        old = self.mask.get(i)
                        self.mask[i] = (old | m) if old is not None and old.shape == m.shape else m.copy()
                    self.mask_n += 1
                    continue
                for idx, m in hits.items():
                    base = self.mask.get(idx)
                    if base is not None and base.shape == m.shape: m = m & ~base
                    if self.writing(np, m, area):         # one of the game's messages, in this colour, over the map
                        self.near[idx] = 0; self.hist[idx] = []; self.snooze[idx] = time.time() + 2
                        continue
                    m = m & area
                    big, cx, cy = self._cluster(np, m)
                    hist = self.hist.setdefault(idx, [])
                    hist.append((big, cx, cy) if big >= self.NEED else None); del hist[:-self.SEEN]
                    bsize = max(self.NEED + 4, int(round(self.BUILDING * (w / 616.0) ** 2)))
                    if big < self.NEED or time.time() < self.snooze.get(idx, 0):
                        self.near[idx] = 0
                        continue
                    self.near[idx] = self.near.get(idx, 0) + 1
                    name = targets.get(idx, idx)
                    if big < bsize: continue                      # a unit's dot, not a building
                    if self.marker_colour(idx):
                        # the game's own markers blink and fade; a building does not
                        if self.near[idx] < self.CONFIRM: continue
                        stayed, seen = self.steady(np, idx, cx, cy)
                        if stayed and sorted(seen)[len(seen) // 2] < bsize * 0.8: stayed = False
                    else:
                        if len(hist) < self.SEEN or any(x is None or x[0] < bsize for x in hist): continue
                        xs = [x[1] for x in hist]; ys = [x[2] for x in hist]
                        if max(xs) - min(xs) > self.STILL or max(ys) - min(ys) > self.STILL: continue
                        stayed, seen = True, [x[0] for x in hist]
                    self.picture(np, a, cx, cy, '%s_%s' % ('found' if stayed else 'ignored', name))
                    if not stayed:
                        self.near[idx] = 0; self.snooze[idx] = time.time() + self.SNOOZE
                        log('minimap: %s showed up but did not stay put (%s pixels on %d looks), so it was not called'
                            % (name, '/'.join(str(n) for n in seen), len(seen)))
                        continue
                    if big >= self.SURE and time.time() - self.t0 < self.EARLY:
                        # a whole building in the first seconds was not scouted: it was on the map from
                        # the start (a revealed map, or a picture that is not the game). That spot is
                        # passed over from now on, and nothing is called for it
                        old = self.mask.get(idx)
                        spot = np.zeros((h, w), dtype=bool)
                        spot[max(0, cy - 14):cy + 14, max(0, cx - 14):cx + 14] = True
                        self.mask[idx] = (old | spot) if old is not None and old.shape == spot.shape else spot
                        self.near[idx] = 0
                        log('minimap: %s was already on the map %ds in (%d pixels), so it was not called'
                            % (name, time.time() - self.t0, big))
                        continue
                    with self.lock: self.found.add(idx)
                    log('minimap: %s found (%d pixels together at %d,%d of %dx%d, steady on %d looks, %ds into watching)'
                        % (name, big, cx, cy, w, h, len(seen), time.time() - self.t0))
                    self.notify(idx, targets.get(idx, ''),
                                self.rect[0] + cx, self.rect[1] + cy)
                self.fail = 0
                self.look += 1
                if self.look % 40 == 0: self.rect = None     # in case the window has moved
            except Exception as e:
                self.fail += 1
                if self.fail < 4: log('minimap watch: %r' % (e,))
                self.rect = None
                time.sleep(2)

    def _cluster(self, np, m):
        """The biggest bunch of matching pixels, and where it is. One stray pixel off a
        compression artefact scores 1; a scout scores a handful; a building scores plenty.
        Returns (count, x, y) with the middle of the winning patch in layer pixels."""
        total = int(m.sum())
        if total < self.NEED: return 0, 0, 0
        best, bx, by, b = 0, 0, 0, self.BLOCK
        for y in range(0, m.shape[0] - 1, b):
            row = m[y:y + b]
            if int(row.sum()) <= best: continue
            for x in range(0, m.shape[1] - 1, b):
                n = int(row[:, x:x + b].sum())
                if n > best: best, bx, by = n, x, y
        if not best: return 0, 0, 0
        patch = m[by:by + b, bx:bx + b]
        ys, xs = np.nonzero(patch)                    # the middle of the pixels, not of the block
        return best, int(bx + xs.mean()), int(by + ys.mean())

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
        if FROZEN: raise RuntimeError('the exe has this built in already')
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

# The game's own player colours, the same hex values it uses. It keeps two per player: the solid
# colour it paints them in on the minimap, and the lighter one it writes their name in on the
# score list. Both are read from the game's UIColors.json, so a colour mod is followed too;
# these are the stock values, for when that file cannot be read.
PLAYER_COLOURS = ['#0000ff', '#fe0000', '#00ff00', '#ffff01',    # blue red green yellow
                  '#00ffe1', '#ff00ff', '#434343', '#ff8201']   # cyan purple grey orange
PLAYER_TEXT = ['#6ea6eb', '#ff6464', '#00ff00', '#ffff00',
               '#00ffe1', '#f16ce8', '#acacac', '#ffb415']
PLAYER_NAMES = ['Blue', 'Red', 'Green', 'Yellow', 'Cyan', 'Purple', 'Grey', 'Orange']
GAME_COLOURS = []

def game_colours():
    """(solid colours, name colours) for the eight players, straight from the game's own file."""
    if not GAME_COLOURS:
        solid, text = list(PLAYER_COLOURS), list(PLAYER_TEXT)
        try:
            tabs = (ui_json('UIColors.json') or {}).get('ColorTables', {})
            for i, n in enumerate(MINIMAP_ORDER):
                for key, into in (('MiniMap', solid), ('Text', text)):
                    c = (tabs.get(n) or {}).get(key)
                    if isinstance(c, list) and len(c) >= 3:
                        into[i] = '#%02x%02x%02x' % (int(c[0]), int(c[1]), int(c[2]))
        except Exception as e:
            log('could not read the player colours, using the stock ones: %r' % (e,))
        GAME_COLOURS.append((solid, text))
    return GAME_COLOURS[0]

def player_colour(idx):
    """The solid colour this player has in the game, or None when it is not known."""
    try: return game_colours()[0][int(idx) % 8], PLAYER_NAMES[int(idx) % 8]
    except Exception: return None, None

def lighten(hex_colour, amount=0.42):
    """Mix a colour towards white. Used to light a name up while the mouse is over it."""
    try:
        r, g, b = (int(hex_colour[i:i + 2], 16) for i in (1, 3, 5))
        mix = lambda c: int(round(c + (255 - c) * amount))
        return '#%02x%02x%02x' % (mix(r), mix(g), mix(b))
    except Exception:
        return hex_colour

def name_colour(idx, fallback):
    """The colour to write a player's name in: the one the game itself writes it in."""
    try: return game_colours()[1][int(idx) % 8]
    except Exception: return fallback

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

# The two openings each civ is usually played with on open maps. Common ranked habits, the kind
# of thing you would say out loud in the lobby, not a rulebook. Shown until the opponent's own
# recent games have been read, and when they have none to read.
CIV_OPEN = {
 'Britons': ('Archers', 'Fast Castle'),      'Franks': ('Scouts', 'MAA'),
 'Goths': ('Scouts', 'Drush'),               'Teutons': ('MAA', 'Scouts'),
 'Japanese': ('MAA', 'Archers'),             'Chinese': ('Scouts', 'Archers'),
 'Byzantines': ('Archers', 'Skirms'),        'Persians': ('Scouts', 'Fast Castle'),
 'Saracens': ('Archers', 'MAA'),             'Turks': ('Scouts', 'Fast Castle'),
 'Vikings': ('MAA', 'Archers'),              'Mongols': ('Scouts', 'Cav Archers'),
 'Celts': ('Scouts', 'MAA'),                 'Spanish': ('Scouts', 'MAA'),
 'Aztecs': ('MAA', 'Eagles'),                'Maya': ('Archers', 'Eagles'),
 'Huns': ('Scouts', 'Cav Archers'),          'Koreans': ('Archers', 'Towers'),
 'Italians': ('Archers', 'Fast Castle'),     'Hindustanis': ('Scouts', 'Archers'),
 'Inca': ('Eagles', 'MAA'),                  'Magyars': ('Scouts', 'Cav Archers'),
 'Slavs': ('Scouts', 'MAA'),                 'Portuguese': ('Archers', 'Fast Castle'),
 'Ethiopians': ('Archers', 'Fast Castle'),   'Malians': ('Scouts', 'MAA'),
 'Berbers': ('Scouts', 'Fast Castle'),       'Khmer': ('Scouts', 'Fast Castle'),
 'Malay': ('Archers', 'Fast Castle'),        'Burmese': ('Scouts', 'MAA'),
 'Vietnamese': ('Archers', 'Skirms'),        'Bulgarians': ('MAA', 'Scouts'),
 'Tatars': ('Scouts', 'Archers'),            'Cumans': ('Scouts', 'Feudal TC'),
 'Lithuanians': ('Scouts', 'Knights'),       'Burgundians': ('Scouts', 'Fast Castle'),
 'Sicilians': ('Scouts', 'MAA'),             'Poles': ('Scouts', 'Fast Castle'),
 'Bohemians': ('Archers', 'Monks'),          'Dravidians': ('Archers', 'MAA'),
 'Bengalis': ('Archers', 'Elephants'),       'Gurjaras': ('Scouts', 'MAA'),
 'Romans': ('MAA', 'Scouts'),                'Armenians': ('MAA', 'Archers'),
 'Georgians': ('Scouts', 'MAA'),             'Shu': ('Archers', 'Scouts'),
 'Wu': ('Scouts', 'Archers'),                'Wei': ('Scouts', 'Archers'),
 'Jurchens': ('Scouts', 'Archers'),          'Khitans': ('Scouts', 'Mounted Archers'),
 'Saxons': ('MAA', 'Towers'),                'Varangians': ('Scouts', 'Knights'),
 'Danes': ('MAA', 'Scouts'),
}

def civ_typical(name, n=2):
    """How this civ is usually opened, short enough to sit in a chip."""
    return list(CIV_OPEN.get(name, ()))[:n]

def uu_counter(civ, strings, icons, n=3):
    """('Mangudai', 'Skirmishers, Knights') for a civ: their unique unit and the short answer
    to it. The one thing worth reading mid game, so it is kept to one line."""
    blurb = strings.get(str(120149 + civ), '')
    for uu in unique_units(blurb):
        v = next((strings[k] for k in strings
                  if k.startswith('26') and strings[k].startswith('Create <b>%s<b>' % uu)), None)
        if not v: continue
        m = re.search(r'<AQUA>Countered by:(.*?)<DEFAULT>', v)
        if not m: continue
        beats = icon_names(m.group(1), icons)[:n]
        if beats: return uu, ', '.join(beats)
    return (unique_units(blurb) or [None])[0], ''

def uu_facts(name, strings, icons):
    """(strong against, countered by, sometimes countered by) for a unique unit, from the game's
    own description of it. None when the game has no description for that unit."""
    key = next((k for k, v in strings.items() if k.startswith('26') and v.startswith('Create <b>%s<b>' % name)), None)
    if not key: return None
    v = strings[key]
    strong = re.search(r'<GREEN>Strong vs (.*?)<DEFAULT>', v)
    counter = re.search(r'<AQUA>Countered by:(.*?)<DEFAULT>', v)
    situ = re.search(r'<ORANGE>Situationally countered by:(.*?)<DEFAULT>', v)
    return (clean(strong.group(1)) if strong else '',
            icon_names(counter.group(1), icons) if counter else [],
            icon_names(situ.group(1), icons) if situ else [])

def uu_info(name, strings, icons):
    facts = uu_facts(name, strings, icons)
    if facts is None: return None
    strong, counter, situ = facts
    lines = []
    if strong: lines.append('Strong vs ' + strong)
    if counter: lines.append('Counter with: ' + ', '.join(counter))
    if situ: lines.append('Sometimes: ' + ', '.join(situ))
    return lines

def civ_text(civ, strings, icons):
    """The lines behind an opponent's name, kept to what is not on the panel already: what kind
    of civ it is and how it plays in one line, then one line for each unique unit."""
    name = STOCK.get(str(10270 + civ)) or strings.get(str(10270 + civ), 'Civ %d' % civ)
    note = OPENINGS.get(name)
    blurb = strings.get(str(120149 + civ), '')
    kind = re.sub(r'\s*civili[sz]ation\s*$', ' civ', clean(blurb.split('\\n')[0]), flags=re.I) if blurb else ''
    lines = []
    if kind or note: lines.append('. '.join(x.rstrip('.') for x in (kind, note) if x) + '.')
    if blurb and not note:
        for b in [clean(b).lstrip('• ') for b in blurb.split('\\n') if b.strip().startswith('•')][:2]:
            lines.append(b if len(b) <= 80 else b[:79].rstrip() + '\u2026')
    shown = uu_counter(civ, strings, icons)[0]         # its first three counters are on the panel already
    for uu in unique_units(blurb):
        if uu == shown: continue                       # already on its own line above, with what beats it
        strong, beat, maybe = uu_facts(uu, strings, icons) or ('', [], [])
        more = ((beat[3:] if uu == shown else beat) + maybe)[:3]
        strong = strong.split(';')[0].strip()
        bits = []
        if strong: bits.append('strong vs ' + strong[:1].lower() + strong[1:].rstrip('.'))
        if more: bits.append(('also ' if uu == shown and beat else '') + 'beaten by ' + ', '.join(more))
        if bits: lines.append('%s: %s.' % (uu, '. '.join([bits[0]] + [b[:1].upper() + b[1:] for b in bits[1:]])))
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

SHORT_OPEN = [('Fast Castle into a boom', 'FC boom'), ('Men-at-arms', 'MAA'), ('Cavalry Archers', 'Cav Archers'),
              ('Fast Castle into ', 'FC '), ('Fast Castle', 'Fast Castle'),
              ('Steppe Lancers', 'Lancers'), ('Battle Elephants', 'Elephants'),
              ('Skirmishers', 'Skirms'), ('Light Cavalry', 'Scouts'),
              ('No early army', 'Nothing early')]

def short_opening(label, parts=2, cap=20):
    """'Men-at-arms > Archers > Towers' -> 'MAA > Archers'. Short enough to read at a glance
    mid game, which is the whole point of putting it on screen."""
    for long_, small in SHORT_OPEN: label = label.replace(long_, small)
    bits = [b.strip() for b in label.split('>') if b.strip()][:parts]
    out = ' > '.join(bits)
    while len(out) > cap and len(bits) > 1:
        bits.pop(); out = ' > '.join(bits)
    return out

def top_openings(rows, n=2):
    """The openings this player uses most, as [(short label, how many times)]. Compound openings
    are counted under their first move too, so 'Scouts' and 'Scouts > Knights' pull together."""
    if not rows: return []
    tally = collections.Counter(short_opening(r['o']) for r in rows)
    if len(tally) > n:                       # too scattered to read: group by the opening move
        first = collections.Counter(short_opening(r['o'], parts=1) for r in rows)
        if first.most_common(1)[0][1] > tally.most_common(1)[0][1]: tally = first
    tops = tally.most_common(n)
    # a one-off next to a clear favourite is noise, not a habit, so it does not earn a chip
    if len(rows) >= 4 and len(tops) > 1 and tops[0][1] >= 3:
        tops = [t for t in tops if t[1] > 1]
    return tops

_INTEL = {}

def _intel():
    """The opponent intelligence module (opponent_intelligence.py), when it sits beside this copy.
    It lives on dev for now, so a Prod copy without it just goes without the extra line."""
    if 'mod' in _INTEL: return _INTEL['mod']
    mod = None
    if FROZEN:
        try:
            import opponent_intelligence as mod                  # built into the exe
            _INTEL['mod'] = mod; return mod
        except Exception:
            mod = None
    try:
        here = os.path.dirname(os.path.abspath(self_path()))
        if os.path.isfile(os.path.join(here, 'opponent_intelligence.py')):
            if here not in sys.path: sys.path.insert(0, here)
            import opponent_intelligence as mod
            log('opponent intelligence: loaded from %s' % here)
    except Exception as e:
        log('opponent intelligence: could not load it: %r' % (e,)); mod = None
    _INTEL['mod'] = mod
    return mod

def intel_line(rows, civ=None):
    """'Past openings: Scouts (4/6) | Feudal ~9:40 | Castle ~17:10' from their public games, or None.
    Grouped by the opening move, and narrowed to the civ they are playing when there are enough
    games on it. History only: what they did before, never what they are doing now."""
    oi = _intel()
    if not oi or not rows: return None
    try:
        recs = [{'opening': short_opening(r['o'], parts=1), 'civ': str(r.get('civ')),
                 'feudal_seconds': r.get('f') or None, 'castle_seconds': r.get('c') or None}
                for r in rows if r.get('o')]
        pred = oi.predict_opening(recs, civ=str(civ) if civ is not None else None, min_samples=3)
        return oi.format_brief(pred) if pred else None
    except Exception as e:
        log('opponent intelligence: %r' % (e,))
        return None

def intel_predict(rows, civ=None):
    """The scouting report on one opponent from their public games: their usual opening move, how
    many of their games it was, every opening move with its count, and their median Feudal and
    Castle times. Uses the opponent intelligence module when it is beside this copy; otherwise
    the same sums done here. History only, never anything about the game in progress."""
    recs = [{'opening': short_opening(r['o'], parts=1), 'civ': str(r.get('civ')),
             'feudal_seconds': r.get('f') or None, 'castle_seconds': r.get('c') or None}
            for r in rows or [] if r.get('o')]
    if len(recs) < 2: return None
    dist = collections.Counter(x['opening'] for x in recs).most_common()
    oi = _intel()
    if oi:
        try:
            pr = oi.predict_opening(recs, civ=str(civ) if civ is not None else None, min_samples=2)
            if pr:
                return dict(opening=pr.opening, observed=pr.observed, matches=pr.matches,
                            feudal=pr.feudal_seconds, castle=pr.castle_seconds, dist=dist,
                            on_civ=bool(civ is not None and pr.matches < len(recs)))
        except Exception as e:
            log('opponent intelligence: %r' % (e,))
    def med(k):
        v = sorted(x[k] for x in recs if x[k])
        return v[len(v) // 2] if v else None
    return dict(opening=dist[0][0], observed=dist[0][1], matches=len(recs),
                feudal=med('feudal_seconds'), castle=med('castle_seconds'), dist=dist, on_civ=False)

# What to do about the way they usually open. Stock ranked advice, keyed off the first move of
# their most common opening from their public games. It answers a habit, not this game: it
# never knows what they are doing right now.
OPENING_ANSWERS = [
 ('fc boom', 'punish the greed. Scouts or MAA early, then towers on their wood or gold.'),
 ('fast castle', 'hit them in Feudal. Scouts or MAA, towers, and make them pay for it.'),
 ('fc', 'hit them in Feudal before their Castle units arrive. Pikes or camels if knights come.'),
 ('drush', 'loom before they land, 2 houses by the wood, keep villagers working. Wall if you can.'),
 ('militia', 'loom before they land, keep villagers working. Archers or towers clean them up.'),
 ('maa', 'wall early and wall well. Archers or towers on your wood, skirms if archers follow.'),
 ('tower', 'scout for forward villagers. Loom, pull villagers back, get stone and build your own.'),
 ('scouts', 'spears and walls, or archers with a few spears. Keep villagers close to the TC.'),
 ('cav archer', 'skirms and walls, or your own archers in bigger numbers.'),
 ('archers', 'skirms, or scouts to raid their archers and villagers. Wall your gold.'),
 ('skirm', 'scouts or MAA. Skirms lose to both.'),
 ('eagle', 'militia line or scouts with forging. Towers help. Archers struggle.'),
 ('knight', 'pikes or camels, walls, and a castle of your own if you can.'),
 ('lancer', 'pikes and camels. Archers behind them.'),
 ('elephant', 'monks, pikes or halbs. Do not fight them with cavalry.'),
 ('nothing early', 'they tend to boom. Punish early with scouts or MAA.'),
]

def opening_answer(opening):
    o = (opening or '').lower()
    for key, text in OPENING_ANSWERS:
        if o.startswith(key) or (' ' + key) in (' ' + o): return text[:1].upper() + text[1:]
    return None

def mmss(sec):
    return '%d:%02d' % (int(sec) // 60, int(sec) % 60)

def openings_lines(rows, civ=None, strings=None):
    """Two short lines: what they open with most, then how those games went."""
    if not rows: return []
    tally = collections.Counter(short_opening(r['o']) for r in rows)
    top = [('%s ×%d' % (k, v)) if v > 1 else k for k, v in tally.most_common(3)]
    out = ['Last %d: %s' % (len(rows), ', '.join(top))]
    won = sum(1 for r in rows if r.get('result') == 'win')
    bits = ['%dW %dL' % (won, len(rows) - won)]
    fs = sorted(r['f'] for r in rows if r.get('f'))
    if fs:
        mid = fs[len(fs) // 2]
        bits.append('Feudal ~%d:%02d' % (mid // 60, mid % 60))
    if civ is not None and strings is not None:
        mine = collections.Counter(short_opening(r['o']) for r in rows if r.get('civ') == civ)
        if mine:
            bits.append('as %s: %s' % (civ_name(civ, strings), ', '.join(k for k, _ in mine.most_common(2))))
    out.append('  ·  '.join(bits))
    extra = intel_line(rows, civ)
    if extra: out.append(extra)
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
        self.gone = lambda: None           # the loading screen has just made way for the game
        self.still_running = lambda: False # is the game on screen still being recorded?
        self.fake_log = 0
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
            # quick off the mark at the menu, quicker to clear; in a game there is no loading screen
            # to catch, only the end screen (checked every few seconds), so it looks far less often
            time.sleep(0.18 if self.showing else (1.2 if self.in_game() else 0.35))
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
                        try: self.gone()
                        except Exception as e_: log('loading gone: %r' % (e_,))
                elif loading:
                    self.misses = 0
                # a game is on: every few seconds look for the end-of-game screen, and reset when it shows
                if not loading and self.ended and self.in_game() and time.time() - self.last_end_check > 3:
                    self.last_end_check = time.time()
                    if self.end_screen(read, grab, x, y, w, hh):
                        # The tech tree and other screens share words with the end-of-game screen.
                        # A game that is still being recorded is not over, whatever the screen says.
                        if self.still_running():
                            if time.time() - self.fake_log > 60:
                                self.fake_log = time.time()
                                log('this looked like the end of game screen, but the game is still being recorded: ignored')
                        else:
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
F_MAP   = (DISPLAY, 13, 'bold')          # the map's name on the panel while you play
F_HEAD  = (DISPLAY, 10, 'bold')
F_BODY  = ('Segoe UI', 10)
F_SMALL = ('Segoe UI', 8)
F_TINY  = ('Segoe UI', 7)

def pick_fonts():
    """Called once Tk is up, when the font list can be read."""
    global DISPLAY, F_TITLE, F_HEADLINE, F_HEAD, F_MAP
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
    F_MAP = (DISPLAY, 13, 'bold')
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

LIVE_RED, LIVE_HOT, LIVE_BUSY, LIVE_OFF = '#d8343a', '#f04a50', '#c9962b', '#5a5246'

def _mix(a, b, t):
    """Colour a, t of the way to colour b ('#rrggbb')."""
    a = [int(a[i:i + 2], 16) for i in (1, 3, 5)]; b = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
    return '#%02x%02x%02x' % tuple(int(x + (y - x) * t) for x, y in zip(a, b))

def live_pill(parent, bg):
    """The Go Live button: a small rounded LIVE badge, drawn smooth (Tk's own shapes come out
    jagged at this size, so the shape is drawn large with Pillow and shrunk). A dark red pill
    with a red dot while it waits, solid red once you are live. .set(text, colour, solid, ink)."""
    import tkinter as tk
    import tkinter.font as tkfont
    class Pill(tk.Canvas):
        H, DOT, PAD = 16, 5, 7
        def __init__(self):
            tk.Canvas.__init__(self, parent, bg=bg, highlightthickness=0, bd=0, cursor='hand2', height=self.H)
            self.font = tkfont.Font(family='Segoe UI', size=7, weight='bold')
            self.text, self.col, self.solid, self.ink, self.hot = 'GO LIVE', LIVE_RED, False, 'white', False
            self.img = None
            self.spin_on, self.frames, self.fi, self.img_id = False, [], 0, None
            self.bind('<Enter>', lambda e: self._hover(True), add='+')
            self.bind('<Leave>', lambda e: self._hover(False), add='+')
            self.draw()
        def _hover(self, on):
            self.hot = on; self.draw()
        def set(self, text, col=LIVE_RED, solid=True, ink='white'):
            self.spin_on = False
            self.text, self.col, self.solid, self.ink = text, col, solid, ink; self.draw()
        def busy(self):
            """Working on it: a dark red pill, 'GOING LIVE', and a small spinning ring where the
            arrow was. The frames are drawn once and then shown in turn."""
            if self.spin_on: return
            self.spin_on = True; self.text = 'GOING LIVE'; self.fi = 0
            self.draw(); self._tick()
        def _tick(self):
            if not self.spin_on or not self.frames: return
            self.fi = (self.fi + 1) % len(self.frames)
            try:
                self.itemconfigure(self.img_id, image=self.frames[self.fi])
                self.after(55, self._tick)
            except tk.TclError:
                pass
        def spin_frames(self, w, h):
            try:
                from PIL import Image, ImageDraw, ImageTk
            except Exception:
                return []
            k = 4; out = []
            fill = _mix(bg, LIVE_RED, 0.30)
            cx, cy = (self.PAD + self.DOT / 2.0) * k, h * k / 2.0
            r = (self.DOT / 2.0 + 1.6) * k
            for n in range(12):
                im = Image.new('RGB', (w * k, h * k), bg)
                d = ImageDraw.Draw(im)
                d.rounded_rectangle((0, 0, w * k - 1, h * k - 1), radius=h * k // 2, fill=fill,
                                    outline=LIVE_RED, width=int(1.3 * k))
                d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=_mix(fill, LIVE_RED, 0.55), width=int(1.8 * k))
                a0 = n * 30
                d.arc((cx - r, cy - r, cx + r, cy + r), a0, a0 + 120, fill='#ffffff', width=int(1.8 * k))
                out.append(ImageTk.PhotoImage(im.resize((w, h), Image.LANCZOS)))
            return out
        def colours(self):
            if self.solid:
                fill = LIVE_HOT if (self.hot and self.col == LIVE_RED) else self.col
                return fill, self.ink, self.ink
            # waiting to be pressed: a red outline with a play arrow, a button rather than a light
            fill = _mix(bg, self.col, 0.28) if self.hot else bg
            return fill, self.col, '#f6dcd8' if self.hot else '#e8b4ad'
        def smooth(self, w, h, fill, dot):
            try:
                from PIL import Image, ImageDraw, ImageTk
            except Exception:
                return None
            k = 4
            im = Image.new('RGB', (w * k, h * k), bg)
            d = ImageDraw.Draw(im)
            cx, cy, r = (self.PAD + self.DOT / 2.0) * k, h * k / 2.0, self.DOT * k / 2.0
            if self.solid:                                            # live (or busy): a solid pill and a dot
                d.rounded_rectangle((0, 0, w * k - 1, h * k - 1), radius=h * k // 2, fill=fill)
                d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=dot)
            else:                                                     # press me: outline and a play arrow
                d.rounded_rectangle((0, 0, w * k - 1, h * k - 1), radius=h * k // 2, fill=fill,
                                    outline=self.col, width=int(1.3 * k))
                r2 = r * 1.15
                d.polygon([(cx - r2 * 0.75, cy - r2), (cx - r2 * 0.75, cy + r2), (cx + r2, cy)], fill=dot)
            return ImageTk.PhotoImage(im.resize((w, h), Image.LANCZOS))
        def draw(self):
            h = self.H
            w = self.PAD + self.DOT + 4 + self.font.measure(self.text) + self.PAD
            self.configure(width=w)
            self.delete('all')
            fill, dot, ink = self.colours()
            if self.spin_on:
                if not self.frames or self.frames[0].width() != w: self.frames = self.spin_frames(w, h)
                if self.frames:
                    self.img_id = self.create_image(0, 0, image=self.frames[self.fi % len(self.frames)], anchor='nw')
                    self.create_text(self.PAD + self.DOT + 4, h / 2.0, text=self.text, anchor='w',
                                     fill='#f6dcd8', font=self.font)
                    return
            self.img = self.smooth(w, h, fill, dot)
            if self.img is not None:
                self.create_image(0, 0, image=self.img, anchor='nw')
            else:                                                    # no Pillow: Tk's own shapes
                r = h / 2.0
                self.create_oval(0, 0, h - 1, h - 1, fill=fill, outline=fill)
                self.create_oval(w - h, 0, w - 1, h - 1, fill=fill, outline=fill)
                self.create_rectangle(r, 0, w - r, h - 1, fill=fill, outline=fill)
                x = self.PAD
                self.create_oval(x, r - self.DOT / 2.0, x + self.DOT, r + self.DOT / 2.0, fill=dot, outline=dot)
            self.create_text(self.PAD + self.DOT + 4, h / 2.0, text=self.text, anchor='w', fill=ink, font=self.font)
    return Pill()

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
    b = tk.Label(parent, text=text, font=(F_SMALL[0], 9, 'bold'), cursor='hand2', padx=14, pady=6)
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



def _smooth_shape(w, h, bg, draw):
    """A small shape drawn 4x with Pillow and shrunk, so curves come out smooth. draw(d, k)
    gets the ImageDraw and the scale. None when Pillow is missing (callers fall back)."""
    try:
        from PIL import Image, ImageDraw, ImageTk
    except Exception:
        return None
    k = 4
    im = Image.new('RGB', (w * k, h * k), bg)
    draw(ImageDraw.Draw(im), k)
    return ImageTk.PhotoImage(im.resize((w, h), Image.LANCZOS))

_SWITCH_IMGS = {}                  # each switch look is drawn once and shared

def Check(parent, text='', variable=None, bg=INK, **_ignored):
    """A small switch and its sentence, in place of Tk's square tick box (which comes out as a
    grey Windows 95 box). Click the switch or the words. Same arguments as tk.Checkbutton, so
    the old calls carry over; colour arguments are ignored, it always matches the panel."""
    import tkinter as tk
    W, H = 24, 13
    f = tk.Frame(parent, bg=bg, cursor='hand2')
    sw = tk.Canvas(f, width=W, height=H, bg=bg, highlightthickness=0, bd=0, cursor='hand2')
    sw.pack(side='left', padx=(0, 7), pady=3)
    lab = tk.Label(f, text=text, fg=TXT, bg=bg, font=(F_SMALL[0], 9), anchor='w', cursor='hand2', justify='left')
    lab.pack(side='left', fill='x')
    st_ = {'hot': False, 'img': None}
    def draw(*_):
        on = bool(variable.get()) if variable is not None else False
        track = (_mix(RIM, GOLDC, 0.35) if st_['hot'] else RIM) if on else (_mix(PANEL, EDGE, 0.8) if st_['hot'] else PANEL)
        rim = GOLDC if on else (BRONZE if st_['hot'] else EDGE)
        knob = GOLDD if on else (MUT if st_['hot'] else FAINT)
        def paint(d, k):
            d.rounded_rectangle((0, 0, W * k - 1, H * k - 1), radius=H * k // 2, fill=track, outline=rim, width=k)
            r = (H - 5) * k / 2.0; cy = H * k / 2.0
            cx = (W - H / 2.0) * k if on else (H / 2.0) * k
            d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=knob)
        sw.delete('all')
        key_ = (on, st_['hot'], bg)
        if key_ not in _SWITCH_IMGS: _SWITCH_IMGS[key_] = _smooth_shape(W, H, bg, paint)
        st_['img'] = _SWITCH_IMGS[key_]
        if st_['img'] is not None:
            sw.create_image(0, 0, image=st_['img'], anchor='nw')
        else:
            for x0_ in (0, W - H):
                sw.create_oval(x0_, 0, x0_ + H - 1, H - 1, fill=track, outline=rim)
            sw.create_rectangle(H / 2.0, 0, W - H / 2.0, H - 1, fill=track, outline='')
            sw.create_line(H / 2.0, 0, W - H / 2.0, 0, fill=rim); sw.create_line(H / 2.0, H - 1, W - H / 2.0, H - 1, fill=rim)
            x = W - H + 2 if on else 2
            sw.create_oval(x, 2, x + H - 5, H - 3, fill=knob, outline=knob)
        lab.config(fg=GOLDD if st_['hot'] else TXT)
    def flip(_e=None):
        if variable is not None: variable.set(not bool(variable.get()))
    def hover(on):
        st_['hot'] = on; draw()
    for w_ in (f, sw, lab):
        w_.bind('<Button-1>', flip, add='+')
        w_.bind('<Enter>', lambda e: hover(True), add='+')
        w_.bind('<Leave>', lambda e: hover(False), add='+')
    if variable is not None:
        variable.trace_add('write', draw)
    draw()
    return f

def slim_scrollbar(parent, bg=INK):
    """A thin bronze scroll thumb in place of the grey Windows bar. Works like tk.Scrollbar:
    give it command=widget.yview and the widget yscrollcommand=bar.set."""
    import tkinter as tk
    class Slim(tk.Canvas):
        def __init__(self):
            tk.Canvas.__init__(self, parent, width=10, bg=bg, highlightthickness=0, bd=0)
            self.lo, self.hi, self.hot, self.cmd, self.grab = 0.0, 1.0, False, None, None
            self.bind('<Configure>', lambda e: self.draw())
            self.bind('<Enter>', lambda e: self._hover(True))
            self.bind('<Leave>', lambda e: self._hover(False))
            self.bind('<Button-1>', self._press)
            self.bind('<B1-Motion>', self._drag)
            self.bind('<ButtonRelease-1>', lambda e: setattr(self, 'grab', None))
        def config(self, **kw):
            if 'command' in kw: self.cmd = kw.pop('command')
            if kw: tk.Canvas.config(self, **kw)
        configure = config
        def set(self, lo, hi):
            self.lo, self.hi = float(lo), float(hi); self.draw()
        def _hover(self, on):
            self.hot = on; self.draw()
        def draw(self):
            self.delete('all')
            h = max(1, self.winfo_height())
            if self.hi - self.lo >= 0.999: return
            y0, y1 = self.lo * h, max(self.lo * h + 24, self.hi * h)
            x0, x1 = (2, 8) if self.hot or self.grab is not None else (3, 7)
            col = BRONZE if self.hot or self.grab is not None else RIM
            self.create_line((x0 + x1) / 2.0, y0 + 3, (x0 + x1) / 2.0, y1 - 3, fill=col,
                             width=x1 - x0, capstyle='round')
        def _press(self, e):
            h = max(1, self.winfo_height()); f = e.y / float(h)
            if self.lo <= f <= self.hi: self.grab = f - self.lo
            elif self.cmd: self.cmd('scroll', -1 if f < self.lo else 1, 'pages')
        def _drag(self, e):
            if self.grab is None or not self.cmd: return
            h = max(1, self.winfo_height())
            self.cmd('moveto', max(0.0, e.y / float(h) - self.grab)); self.draw()
    return Slim()

def build_list(parent, current, on_pick, bg=INK, width=330):
    """The build orders as a tidy list: a small bronze heading per group, then one row per build
    with its name on the left and what it lands on, in a chip, on the right. The one you have
    gets a gold bar and gold name. on_pick(name or None)."""
    import tkinter as tk
    box = tk.Frame(parent, bg=bg)
    tk.Frame(box, bg=bg, width=width, height=0).pack()             # holds the list at a steady width
    rows = {}
    def row(name, label, chip=None):
        r = tk.Frame(box, bg=bg, cursor='hand2')
        r.pack(fill='x', pady=1)
        r.columnconfigure(1, weight=1)
        bar = tk.Frame(r, bg=bg, width=3, height=1); bar.grid(row=0, column=0, sticky='ns')
        nm = tk.Label(r, text=label, fg=TXT, bg=bg, font=F_SMALL, anchor='w', padx=8, pady=4, cursor='hand2')
        nm.grid(row=0, column=1, sticky='w')
        ch = None
        if chip:
            ch = tk.Label(r, text=chip, fg=MUT, bg=PANEL, font=F_TINY, padx=6, pady=1, cursor='hand2')
            ch.grid(row=0, column=2, sticky='e', padx=(10, 6))
        parts = [w_ for w_ in (r, bar, nm, ch) if w_ is not None]
        def inside():
            try:
                x, y = r.winfo_pointerxy()
                return (r.winfo_rootx() <= x < r.winfo_rootx() + r.winfo_width()
                        and r.winfo_rooty() <= y < r.winfo_rooty() + r.winfo_height())
            except tk.TclError:
                return False
        def paint(hot=False):
            on = (current[0] or None) == name
            back = PANEL if (hot or on) else bg
            for w_ in (r, nm): w_.config(bg=back)
            bar.config(bg=GOLDC if on else (RIM if hot else back))
            nm.config(fg=GOLDD if (on or hot) else (TXT if name else MUT))   # colour only: no reflow
            if ch is not None: ch.config(bg=INK if (hot or on) else PANEL, fg=TXT if on else MUT)
        def hover(_e=None):
            # Moving from the row onto its own label counts as leaving the row in Tk, so ask
            # where the pointer really is instead, once things have settled. No flicker.
            try: r.after_idle(lambda: r.winfo_exists() and paint(inside()))
            except tk.TclError: pass
        def release(_e=None, n_=name):
            if inside(): pick(n_)
        for w_ in parts:
            w_.bind('<Enter>', hover, add='+')
            w_.bind('<Leave>', hover, add='+')
            w_.bind('<ButtonRelease-1>', release, add='+')
        rows[name] = paint; paint()
    def pick(name):
        current[0] = name
        for p_ in rows.values(): p_()
        on_pick(name)
    last = None
    for g, n, pop, _st in all_builds():
        if g != last:
            hd = tk.Frame(box, bg=bg); hd.pack(fill='x', pady=(8 if last else 2, 2))
            tk.Label(hd, text=g.upper(), fg=BRONZE, bg=bg, font=(F_TINY[0], F_TINY[1], 'bold')).pack(side='left')
            tk.Frame(hd, bg=EDGE, height=1).pack(side='left', fill='x', expand=True, padx=(8, 0), pady=(2, 0))
            last = g
        row(n, n, pop.replace(', ', '  \u00b7  '))
    tk.Frame(box, bg=EDGE, height=1).pack(fill='x', pady=(8, 3))
    row(None, 'No build order')
    return box

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
                      ('cavalry', 'horse'), ('archer', 'bow'), ('castle', 'castle'),
                      ('starts', 'banner'), ('map tips', 'eye'), ('plans', 'clock')):
        if key in h: return kind
    return 'diamond'


# ---------------------------------------------------------------- map tips for the loading screen
# What makes each map different from a normal start, then what to do about it. Only what anyone can
# see in the lobby: the map's name and its well known layout, never where things are this game.
STANDARD = 'Standard start: a Town Center, 3 villagers and a scout.'
MAP_TIPS = {
 'Arabia': dict(start=[STANDARD, 'Open land with hills and thin wood lines.'],
     tips=['Fight on the hills: units on high ground do 25% more damage.',
           'Your wood lines are exposed. A wall or palisade around them stops early raids.'],
     plans=['An aggressive map: Scouts, Archers, or a drush into Archers.',
            'Going to Castle Age? Wall up in Feudal first.']),
 'Arena': dict(start=['Your base starts walled in with stone walls.'],
     tips=['Build a gate in your wall to get your army out.',
           'Early rushes rarely land here, so expect a boom.'],
     plans=['Fast Castle is standard: Knights, Monks with siege, or a boom to Imperial.']),
 'Black Forest': dict(start=[STANDARD, 'Thick forest everywhere, with only a few paths through it.'],
     tips=['Wall the few openings early and you are safe for a long time.',
           'Siege Onagers and Trebuchets can cut new paths through the trees.'],
     plans=['Boom behind walls, then a Castle or Imperial army.']),
 'Nomad': dict(start=['No Town Center and no scout. Your villagers start spread out.',
                      'Extra wood and stone to pay for your Town Center. Water all around the land.'],
     tips=['Settle fast near wood and the shore. Every second without a Town Center costs you.',
           'Docks and fishing ships pay off early.'],
     plans=['Town Center, houses, then a dock. Whoever wins the water usually wins.']),
 'Land Nomad': dict(start=['No Town Center and no scout. Your villagers start spread out.',
                           'No water anywhere.'],
     tips=['Pick a spot with wood, food and gold close together, and settle fast.'],
     plans=['Once you are settled it plays like Arabia.']),
 'Islands': dict(start=['You start alone on your own island.'],
     tips=['You cannot reach anyone without ships.',
           'Fish and the empty islands hold the extra resources.'],
     plans=['Docks first: fishing ships, then Galleys and Fire Ships to win the water. Transports come later.']),
 'Team Islands': dict(start=['Each team shares its own island.'],
     tips=['The water decides the game. Lose it and your shore is open to attack.'],
     plans=['Docks and fishing early. One player can take the navy while the other booms.']),
 'MegaRandom': dict(start=['Anything goes: land, water, forest, walls or no Town Center.'],
     tips=['Scout early and work out what you got before you commit to a build.'],
     plans=['Pick your build after the first minute of scouting.']),
 'Michi': dict(start=[STANDARD, 'A thick forest separates the two sides.'],
     tips=['No early rushes: the forest closes your side off.',
           'Siege Onagers and Trebuchets break through the trees.'],
     plans=['Boom hard and go to Imperial. Trebuchets and Siege Onagers open it up.']),
 'Hideout': dict(start=['Your base starts inside a palisade wall.'],
     tips=['The palisade slows early raids but will not hold a real push.'],
     plans=['Fast Castle is common, but towers and Feudal pressure still work.']),
 'Hill Fort': dict(start=['Your base sits on a hill inside fortified palisade walls, with a moat below.',
                         'No berries, one big gold and one big stone.'],
     tips=['You will have to leave the hill for more resources, so guard what you take below.',
           'Units on high ground do 25% more damage.'],
     plans=['Fast Castle, then expand with Town Centers or a Castle.']),
 'Golden Pit': dict(start=[STANDARD, 'A ravine full of gold sits between you.'],
     tips=['The middle gold is the prize. Towers or a Castle near it let you hold it.'],
     plans=['Fight for the middle in Feudal, or Fast Castle and claim it with a Castle.']),
 'Acropolis': dict(start=['Your base is up on a big hill, with few resources around it.'],
     tips=['Hold the ramps up to your hill. Units on high ground do 25% more damage.',
           'The resources down below are worth fighting for.'],
     plans=['Fast Castle is common. Push down with siege and Castles.']),
 'Fortress': dict(start=['You start walled in, with gates and buildings already up.'],
     tips=['Rushes struggle to get through the walls.'],
     plans=['Fast Castle or a straight boom. Siege decides the late game.']),
 'Gold Rush': dict(start=[STANDARD, 'A big pile of gold in the middle, guarded by wolves.'],
     tips=['Send soldiers to clear the wolves before your villagers go in.'],
     plans=['Fight for the middle gold. A Castle there pays for itself.']),
 'Four Lakes': dict(start=[STANDARD, 'A lake in each corner, full of fish.'],
     tips=['The lakes hold most of the fish. Lose yours and you lose a lot of food.'],
     plans=['Docks and fishing early, with Galleys to guard your lake.']),
 'Steppe': dict(start=[STANDARD, 'Open ground with few trees.'],
     tips=['Lots of deer on the open ground: push them to your Town Center with the scout.',
           'Wood is scarce and exposed, so guard your lumber camps.'],
     plans=['A cavalry map: Scouts into Knights, or horse archers.']),
 'Valley': dict(start=[STANDARD, 'A dry riverbed runs between you.'],
     tips=['Animals gather in the riverbed. That food is worth taking but leaves villagers exposed.'],
     plans=['Scouts are strong early for holding the middle hunt.']),
 'Atacama': dict(start=[STANDARD, 'Dry desert near you; the trees are further out.'],
     tips=['Your wood is further than usual, so lumber camps sit out in the open.'],
     plans=['Guard your wood lines and raid theirs.']),
 'Kawasan': dict(start=[STANDARD, 'Lots of food on this map.'],
     tips=['A big cluster of berry bushes in the middle.',
           'Plenty of relics around the ponds: Monks pay off.'],
     plans=['Get Monks out in Castle Age for the relics.']),
 'African Clearing': dict(start=[STANDARD, 'A forest clearing with sparse resources.'],
     tips=['Expand early to claim what is there before they do.'],
     plans=['Early pressure works, since everyone is short.']),
 'Ghost Lake': dict(start=[STANDARD, 'A frozen lake in the middle that you can walk across.'],
     tips=['No fishing: the lake is ice.'],
     plans=['Plays as an open land map.']),
 'Baltic': dict(start=[STANDARD, 'You start on the coast of a sea in the middle.'],
     tips=['Fish is a big part of your food. Lose the water and your coast is open.'],
     plans=['Docks early, then Galleys. Land armies decide it once the water is settled.']),
 'Mediterranean': dict(start=[STANDARD, 'A sea in the middle with land all around.'],
     tips=['Fish is a big part of your food. Lose the water and your coast is open.'],
     plans=['Docks early, then Galleys. Land armies decide it once the water is settled.']),
 'Coastal': dict(start=[STANDARD, 'Land with a long coast.'],
     tips=['Fish along the shore is extra food.', 'Ships can hit anything near the coast.'],
     plans=['Usually won on land, but do not hand them the water.']),
 'Continental': dict(start=[STANDARD, 'One big continent with sea around it.'],
     tips=['Fish along the shore is extra food.'],
     plans=['A land map with some water play.']),
}

def map_name_desc(maps, strings, res):
    """(name, the game's own one line description) for a map id."""
    m = maps.get(res)
    if not m: return None, ''
    name = strings.get(str(m.get('name_string_id')), m.get('const_name', ''))
    desc = clean(strings.get(str(m.get('rollover_string_id')), ''))
    if desc.lower().startswith(name.lower()): desc = desc[len(name):].lstrip(' -\u2013')
    return name, desc.split('\n')[0].strip()

def map_from_screen(maps, strings, lines):
    """The map named on the loading screen, when there is no recording to read it from."""
    seen = _norm(' '.join(t for t, _ in lines))
    best = None
    for res in maps:
        nm, ds = map_name_desc(maps, strings, res)
        k = _norm(nm or '')
        if len(k) >= 4 and k in seen and (best is None or len(k) > len(_norm(best[0]))): best = (nm, ds)
    return best or (None, '')

def map_tips(name):
    """The tips for a map by its name, or None."""
    n = _norm(name or '')
    for k, v in MAP_TIPS.items():
        if _norm(k) == n: return v
    return None

def map_sections(name, desc=''):
    """The loading screen panel for the map: what is different about how it starts, what to watch,
    and the plans that usually work."""
    t = map_tips(name)
    if not t:
        return [('About this map', [desc or 'No notes for this map yet. Scout early.'])]
    return [('How it starts', t['start']), ('Map tips', t['tips']), ('Plans that work', t['plans'])]

# ---------------------------------------------------------------- window
WAKE_FILE = os.path.join(os.path.dirname(PIDFILE), 'overlay.wake')

def single_instance():
    """Only one overlay at a time. A second copy, however it was started, bows out quietly.
    Also leaves its process id where the watchdog can find it to close it later."""
    try:
        import ctypes
        k32 = ctypes.WinDLL('kernel32', use_last_error=True)   # so the 'already exists' answer is reliable
        # Restarted as admin: the old copy is still closing, so wait for it rather than bow out.
        tries = 50 if '--wait-turn' in sys.argv else 1
        for i in range(tries):
            h = k32.CreateMutexW(None, False, 'AoE2MapOverlay.SingleInstance')
            taken = ctypes.get_last_error() == 183                     # ERROR_ALREADY_EXISTS
            if h and not taken: break
            if h: k32.CloseHandle(h)
            if i == tries - 1: return False
            time.sleep(0.2)
        globals()['_INSTANCE_MUTEX'] = h                               # held for the life of the app
    except Exception as e:
        log('single instance check failed, carrying on: %r' % (e,))
    try:
        os.makedirs(os.path.dirname(PIDFILE), exist_ok=True)
        with io.open(PIDFILE, 'w', encoding='utf-8') as fh: fh.write(str(os.getpid()))
        import atexit
        atexit.register(lambda: os.path.exists(PIDFILE) and os.remove(PIDFILE))
    except Exception as e:
        log('could not write the pid file: %r' % (e,))
    return True

def warm_imports():
    """Import the shared modules once, here on the main thread, before any worker thread starts.
    Several threads importing the same module at the same moment can each get a half-built copy
    of it. In the exe, where imports are slower, that is what broke the web lookups ('unknown url
    type: https', ssl half loaded), the text reader and Go Live ('logging' has no 'Handler')."""
    import importlib
    for name in ('logging', 'logging.handlers', 'ssl', 'socket', 'http.client', 'urllib.request',
                 'urllib.parse', 'urllib.error', 'email.utils', 'hashlib', 'base64', 'zipfile',
                 'subprocess', 'ctypes', 'ctypes.wintypes', 'uuid', 'queue'):
        try: importlib.import_module(name)
        except Exception as e: log('warm import %s: %r' % (name, e))
    # winrt and comtypes are left to their own threads: they set up COM, which the main
    # thread should not take on. _load_ocr takes a lock so only one thread imports winrt.

def main():
    import tkinter as tk
    warm_imports()
    if not single_instance():
        # Opening it again means you cannot see the one that is running: ask that one to come
        # back to the front, in a spot on the screen.
        try:
            with io.open(WAKE_FILE, 'w', encoding='utf-8') as fh: fh.write(str(time.time()))
        except Exception: pass
        log('another copy is already running: asked it to show itself'); return
    maps, strings, icons = load_data()
    me = my_profile()
    root = tk.Tk()
    try:                                  # the crest on every Wingman window, not Tk's feather
        st_icons = [tk.PhotoImage(data=d) for d in APP_ICON_PNG]
        root.iconphoto(True, *st_icons); root._wm_icons = st_icons
    except Exception as e:
        log('window icon: %r' % (e,))
    pick_fonts()
    root.overrideredirect(True); root.attributes('-topmost', True)
    try: root.attributes('-alpha', 0.97)          # solid enough that the game does not show through the text
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
    PANEL_W = 440                     # the overlay is always this wide inside; anything longer wraps
    head = tk.Frame(frame, bg=BG)
    head.grid(row=0, column=0, columnspan=4, sticky='we')
    head.columnconfigure(1, weight=1)
    try:
        crest_img = tk.PhotoImage(data=CREST_20_PNG)
        badge = tk.Label(head, image=crest_img, bg=BG, bd=0); badge.image = crest_img
    except Exception:
        badge = tk.Label(head, text='', bg=BG)
    badge.grid(row=0, column=0, sticky='w', padx=(0, 4))
    badge.config(cursor='hand2')
    # the crest with a small gold padlock on it: shown while the overlay is locked in place
    crest_locked = None
    try:
        from PIL import Image as _Im, ImageDraw as _Dr, ImageTk as _ITk
        _c = _Im.open(io.BytesIO(__import__('base64').b64decode(CREST_20_PNG))).convert('RGBA')
        K_ = 4; big = _Im.new('RGBA', (20 * K_, 20 * K_), (0, 0, 0, 0)); d_ = _Dr.Draw(big)
        # body and shackle, bottom right, with a dark edge so it reads over the crest
        x0, y0 = 11 * K_, 11 * K_
        d_.rounded_rectangle((x0 - K_, y0 + 2 * K_ - K_, x0 + 8 * K_ + K_, y0 + 9 * K_ + K_), radius=2 * K_, fill=(20, 16, 10, 255))
        d_.arc((x0 + 1 * K_, y0 - 2 * K_, x0 + 7 * K_, y0 + 5 * K_), 180, 360, fill=(20, 16, 10, 255), width=4 * K_)
        d_.arc((x0 + 1 * K_ + K_ // 2, y0 - 1 * K_, x0 + 7 * K_ - K_ // 2, y0 + 5 * K_), 180, 360, fill=(232, 196, 104, 255), width=int(1.6 * K_))
        d_.rounded_rectangle((x0, y0 + 2 * K_, x0 + 8 * K_, y0 + 9 * K_), radius=int(1.5 * K_), fill=(232, 196, 104, 255))
        d_.ellipse((x0 + 3 * K_, y0 + 4 * K_, x0 + 5 * K_, y0 + 6 * K_), fill=(20, 16, 10, 255))
        _c.alpha_composite(big.resize((20, 20), _Im.LANCZOS))
        crest_locked = _ITk.PhotoImage(_c)
    except Exception:
        pass
    HEAD_NAME = 'Wingman'             # the crest already says AoE2; the short name keeps the header in one row
    title = tk.Label(head, text=HEAD_NAME, fg=GOLDC, bg=BG, font=F_HEADLINE, anchor='w', cursor='hand2',
                     justify='left', wraplength=PANEL_W - 170)
    title.grid(row=0, column=1, sticky='w', padx=(2, 0))
    state = tk.Label(head, text='WAITING', fg=MUT, bg=PANEL, font=F_TINY, padx=7, pady=3,
                     highlightthickness=1, highlightbackground=RIM)
    state.grid(row=0, column=2, sticky='e', padx=(10, 2))
    live_btn = live_pill(head, BG)                                      # pause, chat, stream on Discord
    # brings a hidden build order back: a small gold B badge
    bo_open = tk.Label(head, text='', bg=BG, padx=0, pady=0, cursor='hand2', bd=0)
    try:
        from PIL import ImageTk
        bo_open_imgs = [ImageTk.PhotoImage(draw_build_badge(23, BG, hot)) for hot in (False, True)]
        bo_open.config(image=bo_open_imgs[0]); bo_open.images = bo_open_imgs
        bo_open.bind('<Enter>', lambda e: bo_open.config(image=bo_open_imgs[1]), add='+')
        bo_open.bind('<Leave>', lambda e: bo_open.config(image=bo_open_imgs[0]), add='+')
    except Exception:
        bo_open.config(text='B', fg='#f4ead2', bg='#2f569c', font=(DISPLAY, 10, 'bold'), padx=6)
    bo_open.grid(row=0, column=3, sticky='e', padx=(3, 0)); bo_open.grid_remove()
    live_btn.grid(row=0, column=4, sticky='e', padx=(5, 1))
    stats_btn = icon_button(head, 'W/L', BG, size=8)
    stats_btn.configure(font=(DISPLAY, 8, 'bold'))
    stats_btn.grid(row=0, column=5, sticky='e', padx=(2, 0))
    gear = icon_button(head, '\u2699', BG)
    gear.grid(row=0, column=6, sticky='e', padx=(1, 0))
    close = icon_button(head, '\u2715', BG, hot=REDC)
    close.grid(row=0, column=7, sticky='e')
    for b_ in (stats_btn, gear, close): b_.config(padx=4)          # tight, so the header fits the panel's width
    sep = Rule(frame)
    sep.grid(row=1, column=0, columnspan=4, sticky='we', pady=(4, 5))

    # the map's facts, laid out as chips rather than one run-on line
    class Facts(object):
        """Stands in for the old body label: same .config(text=...) in, a tidy chip strip out."""
        WIDTH = PANEL_W                     # the room there is inside the panel

        def __init__(self, parent):
            import tkinter.font as tkfont
            self.font = tkfont.Font(font=F_SMALL)
            self.frame = tk.Frame(parent, bg=BG)
            self.text = ''
            self.binds = []
            self.prose = []                 # the map's own description, hidden until asked for
            self.show_prose = False

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
            c = tk.Frame(row, bg=PANEL)                               # a quiet tag, like every other tag
            tk.Label(c, text=label, fg=TXT, bg=PANEL, font=F_SMALL, padx=7, pady=2).pack()
            c.pack(side='left', padx=(0, 4), pady=(0, 4))
            return c

        def _note(self, parent, label, colour):
            n = tk.Label(parent, text=label, fg=colour, bg=BG, font=F_SMALL, anchor='w',
                         justify='left', wraplength=self.WIDTH)
            n.pack(fill='x', pady=(0, 4))
            return n

        def tell_me_about_the_map(self, on=None):
            """The map's own description is hidden by default: mid game the counts are what you
            want, not a paragraph. Click the map name to read it."""
            self.show_prose = (not self.show_prose) if on is None else on
            self.render()
            return self.show_prose

        def has_prose(self):
            return bool(self.prose)

        def render(self):
            for w in self.frame.winfo_children(): w.destroy()
            made = []
            self.prose = []
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
                    n = self._note(self.frame, '  \u00b7  '.join(prose), '#bdb7a6')
                    made.append(n)
                    self.prose.append(n)
                    if not self.show_prose: n.pack_forget()
                row, used = None, 0
                try: chips = merge_hunt(chips)                       # deer-like and boar-like as one each
                except Exception: pass
                for ch in chips:
                    ch = ch.replace(' OR ', ' / ')
                    w = self.font.measure(ch) + 18                    # the words, the chip around them, the gap after
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
    pin.grid(row=9, column=0, columnspan=4)

    waiting_now = [True]                 # st does not exist yet when this first runs

    def idle_size(waiting):
        was = waiting_now[0]
        waiting_now[0] = waiting
        pin.config(width=PANEL_W)                     # one width in and out of a game
        if waiting:                                   # pull everything in: there is nothing to show
            body.config(text=''); body.grid_remove()
            sep.grid_remove(); footsep.grid_remove()   # no dividers, nothing to divide
            frame.configure(padx=12, pady=9)
            title.config(font=F_TITLE)                 # the app's own name, smaller: the button shares its row
        else:
            title.config(font=F_MAP)                   # the map's name is the headline while you play
            body.grid()
            if not st.get('rolled'):
                sep.grid()
                if st.get('footer', True): footsep.grid()
            frame.configure(padx=12, pady=8)
        if was != waiting:
            try: bo_draw()                 # the strip says something different in and out of a game
            except NameError: pass         # the very first call, before it exists

    # the build order strip: one step at a time, because mid game you have no time for a list
    # i is where your pop says you are (live); view is a step you clicked to look at, None for live
    bo = {'name': None, 'i': 0, 'view': None, 'pop': 0, 'hidden': False, 'voice': False, 'said': -1,
          'voice_at': None, 'game_t': 0, 'pop_t': 0, 'done': False, 'done_t': 0, 'said_done': False,
          'said_set': set()}
    BO_WRAP = 260                               # the narrowest the strip wraps to
    bo_box = tk.Frame(frame, bg=PANEL, highlightthickness=1, highlightbackground=EDGE, padx=9, pady=5)
    bo_box.grid(row=3, column=0, columnspan=4, sticky='we', pady=(6, 0)); bo_box.grid_remove()
    bo_box.columnconfigure(0, weight=1)
    # the build's name is a button (with a drop-down arrow) that opens the list of builds
    bo_caprow = tk.Frame(bo_box, bg=PANEL, cursor='hand2')
    bo_caprow.grid(row=0, column=0, sticky='w')
    bo_cap = tk.Label(bo_caprow, text='', fg=GOLDC, bg=INK, font=(F_TINY[0], F_TINY[1], 'bold'), anchor='w',
                      cursor='hand2', padx=7, pady=2, highlightthickness=1, highlightbackground=RIM)
    bo_cap.pack(side='left')
    # right of the build's name: [LIVE or 3/6] [POP 12-17], both fixed widths, so nothing moves
    bo_right = tk.Frame(bo_box, bg=PANEL)
    bo_right.grid(row=0, column=1, sticky='e')
    bo_at = tk.Label(bo_right, text='', fg=GOLDD, bg=PANEL, font=(DISPLAY, 10, 'bold'), anchor='e', padx=2, pady=0,
                     width=9)                    # one width for 'POP 7' and 'POP 12-17', so nothing beside it shifts
    bo_at.pack(side='right')
    # back and forward through the steps; your pop moving on brings it back to where you are
    bo_navf = tk.Frame(bo_box, bg=PANEL)
    bo_navf.grid(row=0, column=2, sticky='e', padx=(6, 0))
    bo_back = tk.Label(bo_navf, text='\u25c2', fg=MUT, bg=PANEL, font=('Segoe UI', 14, 'bold'), padx=4, cursor='hand2')
    bo_fwd = tk.Label(bo_navf, text='\u25b8', fg=MUT, bg=PANEL, font=('Segoe UI', 14, 'bold'), padx=4, cursor='hand2')
    # One fixed space before the arrows, for either the LIVE button (looking at another step) or
    # the 3/6 counter (live). It never changes size, so stepping never shifts anything sideways.
    bo_slot = tk.Frame(bo_right, bg=PANEL)
    # shown only while you look at a step that is not the live one; click it to go back
    bo_prev = tk.Label(bo_slot, text='\u21a9 LIVE', fg=INK, bg=GOLDC, font=(F_TINY[0], F_TINY[1], 'bold'),
                       padx=6, pady=1, cursor='hand2')
    # which villager of a several-villager step is training now ('3/6')
    bo_cnt = tk.Label(bo_slot, text='', fg=GOLDC, bg=INK, font=(F_SMALL[0], F_SMALL[1], 'bold'), padx=5, pady=0)
    bo_slot.update_idletasks()
    bo_slot.config(width=max(bo_prev.winfo_reqwidth(), bo_cnt.winfo_reqwidth() + 22) + 2,
                   height=max(bo_prev.winfo_reqheight(), bo_cnt.winfo_reqheight()))
    bo_slot.pack_propagate(False)
    bo_slot.pack(side='right', padx=(0, 2))
    bo_back.pack(side='left'); bo_fwd.pack(side='left')
    bo_snd = icon_button(bo_box, '', PANEL, size=9)                   # reads the steps out loud, or not
    bo_snd.config(padx=4, pady=2)
    bo_snd.grid(row=2, column=3, rowspan=2, sticky='e', padx=(8, 0))   # beside the step and the next one
    bo_snd_img = {}
    try:
        from PIL import ImageTk
        for k_ in ('sound_on', 'sound_off'):
            bo_snd_img[k_] = ImageTk.PhotoImage(draw_step_icon(k_, 26, PANEL))
    except Exception:
        pass
    def bo_voice_draw():
        k_ = 'sound_on' if bo['voice'] else 'sound_off'
        if bo_snd_img.get(k_): bo_snd.config(image=bo_snd_img[k_], text='')
        else: bo_snd.config(image='', text='\U0001F50A' if bo['voice'] else '\U0001F507')
    bo_voice_draw()
    bo_x = icon_button(bo_box, '\u2715', PANEL, hot=REDC, size=9)     # closes the build order
    bo_x.config(padx=4, pady=0)
    bo_x.grid(row=0, column=3, sticky='ne', padx=(2, 0))
    bo_now = tk.Label(bo_box, text='', fg=GOLDD, bg=PANEL, font=(DISPLAY, 12, 'bold'),
                      anchor='w', justify='left', cursor='hand2', wraplength=BO_WRAP - 30)
    bo_now.grid(row=2, column=0, columnspan=3, sticky='w', pady=(1, 0))
    try:
        import tkinter.font as tkfont
        _ls = tkfont.Font(font=(DISPLAY, 12, 'bold')).metrics('linespace')
        bo_box.grid_rowconfigure(2, minsize=max(36, 2 * _ls + 4))     # the strip does not grow or shrink step to step
        _nfont = tkfont.Font(font=F_SMALL)
    except Exception:
        _nfont = None
    def one_line(t_, px_):
        """Cut a line to fit the room, with an ellipsis, so the NEXT line never wraps."""
        if not _nfont or not t_ or _nfont.measure(t_) <= px_: return t_
        while t_ and _nfont.measure(t_ + '\u2026') > px_: t_ = t_[:-1]
        return t_.rstrip(' ,.') + '\u2026'
    # how far through the build you are: one short bar per step, gold for the one you are on
    bo_prog = tk.Canvas(bo_box, height=3, bg=PANEL, highlightthickness=0, bd=0)
    bo_prog.grid(row=1, column=0, columnspan=4, sticky='we', pady=(3, 3))
    def bo_prog_draw(_e=None):
        bo_prog.delete('all')
        found_ = build_by_name(bo['name'])
        if not found_: return
        n = len(found_[2]); w = max(1, bo_prog.winfo_width()); gap = 3
        seg = (w - gap * (n - 1)) / float(n)
        v = bo['view']
        for k in range(n):
            x0 = k * (seg + gap)
            col = GOLDC if k == bo['i'] else (BRONZE if k < bo['i'] else EDGE)
            if v is not None and k == v and v != bo['i']: col = '#efe6d2'      # the step you are looking at
            bo_prog.create_rectangle(x0, 0, x0 + seg, 3, fill=col, outline='')
    bo_prog.bind('<Configure>', bo_prog_draw, add='+')
    bo_nrow = tk.Frame(bo_box, bg=PANEL)
    bo_nrow.grid(row=3, column=0, columnspan=3, sticky='we', pady=(1, 0))
    # the build's goal ('19 pop, Feudal 8:50'), small, at the end of the NEXT line
    bo_goal = tk.Label(bo_nrow, text='', fg=FAINT, bg=PANEL, font=F_TINY, anchor='e', cursor='hand2')
    bo_goal.pack(side='right', anchor='n', pady=(1, 0))
    bo_ntag = tk.Label(bo_nrow, text='NEXT', fg=BRONZE, bg=PANEL, font=(F_TINY[0], F_TINY[1], 'bold'), anchor='nw')
    bo_ntag.pack(side='left', anchor='n', padx=(0, 6), pady=(1, 0))
    bo_next = tk.Label(bo_nrow, text='', fg=FAINT, bg=PANEL, font=F_SMALL, anchor='w', justify='left',
                       wraplength=BO_WRAP - 36)
    bo_next.pack(side='left', anchor='n')
    bo_live = tk.Label(bo_box, text='', fg=GREEN, bg=PANEL, font=F_SMALL, anchor='w', justify='left',
                       cursor='hand2', wraplength=BO_WRAP - 36)
    bo_live.grid(row=4, column=0, columnspan=4, sticky='w', pady=(4, 0)); bo_live.grid_remove()

    def bo_wrap(e=None):
        # Long steps wrap to whatever width the overlay already is, never wider. The margin is
        # bigger than the box's own padding so the wrap can never push the box out a pixel and
        # set off another resize.
        w = max(BO_WRAP, bo_box.winfo_width() - 34)
        try: cur_ = int(str(bo_now.cget('wraplength')))
        except ValueError: cur_ = -1
        if cur_ != w - 84:                     # room for the step picture and the speaker
            bo_now.config(wraplength=w - 84); bo_next.config(wraplength=w - 76); bo_live.config(wraplength=w - 10)
            if bo.get('name'): root.after_idle(bo_draw)
    bo_box.bind('<Configure>', bo_wrap, add='+')

    def bo_draw():
        if bo['hidden']:                          # hidden from the list: the header icon brings it back
            bo_box.grid_remove(); bo_open_sync(); foot_fit(); return
        found = build_by_name(bo['name'])
        if not found:
            # Nothing picked yet. At the menu that gets an invitation, because otherwise there is
            # nothing on screen to click and no way to find the feature at all. In a game it stays
            # hidden: if you have not picked one by then you do not want a prompt mid match.
            if waiting_now[0]:
                bo_cap.config(text='BUILD ORDER  \u25be'); bo_goal.config(text='')
                bo_at.config(text='')
                bo_now.config(text='Pick one', font=(DISPLAY, 10, 'bold'), image='')
                bo_next.config(image='')
                bo_next.config(text=BUILD_SOURCE); bo_ntag.pack_forget()
                bo_box.config(highlightbackground=EDGE, highlightthickness=1)
                bo_prog.grid_remove(); bo_snd.grid_remove(); bo_live.grid_remove()
                bo_right.grid_remove(); bo_navf.grid_remove()
                bo_box.grid()
            else:
                bo_box.grid_remove()
            bo_open_sync(); foot_fit(); return
        bo_now.config(font=(DISPLAY, 12, 'bold'))
        bo_right.grid(); bo_navf.grid()
        name, pop, steps = found
        live = max(0, min(bo['i'], len(steps) - 1))
        bo['i'] = live
        if bo['view'] is not None:
            bo['view'] = max(0, min(bo['view'], len(steps) - 1))
            if bo['view'] == live: bo['view'] = None
        i = live if bo['view'] is None else bo['view']          # the step on show
        if bo['done'] and bo['view'] is None:
            bo_cap.config(text='%s  \u25be' % name.upper()); bo_goal.config(text=pop)
            bo_at.config(text='DONE', fg=GREEN)
            img_ = step_icon('militia', 33, PANEL, 10)          # the sword picture
            bo_now.config(text=BO_DONE, image=img_ or '', compound='left', fg=GOLDD); bo_now.image = img_
            bo_next.config(text='Right-click to look back over the build.', image='')
            bo_ntag.pack_forget(); bo_live.grid_remove()
            bo_box.config(highlightbackground=EDGE, highlightthickness=1); bo_prev.pack_forget()
            bo_prog.grid(); bo_prog_draw(); bo_snd.grid()
            bo_box.grid(); bo_open_sync(); foot_fit(); return
        lo, hi, text = steps[i]
        span = '%d' % lo if lo == hi else ('%d+' % lo if hi >= 99 else '%d-%d' % (lo, hi))
        bo_cap.config(text='%s  \u25be' % name.upper()); bo_goal.config(text=pop)
        bo['span'] = (lo, span, hi, i == live)
        bo_pop_text(fg=GOLDD if i == live else '#efe6d2')
        previewing = i != live                         # looking ahead (or back) at a step that is not live
        bo_live.grid_remove()
        if previewing and not bo_prev.winfo_manager():
            bo_cnt.pack_forget(); bo_prev.pack(side='right')
        elif not previewing:
            bo_prev.pack_forget()
            if bo_cnt.cget('text') and not bo_cnt.winfo_manager(): bo_cnt.pack(side='right')
        img_ = step_icon(text, 33, PANEL, 10)
        bo_now.config(text=text, image=img_ or '', compound='left',
                      fg=GOLDD if i == live else '#cfc8b6')        # a step you are only looking at is paler
        bo_now.image = img_
        nxt = steps[i + 1][2] if i + 1 < len(steps) else None
        try: room_ = int(str(bo_next.cget('wraplength'))) - 10 - (bo_goal.winfo_reqwidth() if bo_goal.cget('text') else 0)
        except Exception: room_ = 260
        bo_next.config(text=one_line(nxt or 'Last step. Over to you.', room_), image='')
        if nxt and not bo_ntag.winfo_manager():
            bo_ntag.pack(side='left', anchor='n', padx=(0, 6), pady=(1, 0), before=bo_next)
        elif not nxt:
            bo_ntag.pack_forget()
        # the moment to click up gets a gold edge, so it stands out from the villager steps
        up_ = any(k in text.lower() for k in ('click feudal', 'click castle'))
        # a step you are only looking at: a pale double edge round the whole strip, so it is plain
        # at a glance that this is not where you are
        bo_box.config(highlightbackground='#efe6d2' if previewing else (GOLDC if up_ else EDGE),
                      highlightthickness=2 if previewing else 1)
        bo_prog.grid(); bo_prog_draw(); bo_snd.grid()
        bo_box.grid(); bo_open_sync(); foot_fit()

    def bo_open_sync():
        """The build order icon in the header shows only while the build order is hidden."""
        if bo['hidden']: bo_open.grid()
        else: bo_open.grid_remove()

    def bo_set_hidden(h):
        bo['hidden'] = bool(h)
        cfg_ = load_settings(); cfg_['build_order_hidden'] = bo['hidden']; save_settings(cfg_)
        bo_draw()

    def bo_reopen():
        bo_set_hidden(False)
        if not bo['name']: bo_menu(bo_box)

    def bo_pick(name):
        bo['name'] = name or None
        bo['i'] = 0; bo['pop'] = 0; bo['said_set'] = set(); bo['view'] = None
        bo['done'] = False; bo['done_t'] = 0; bo['said_done'] = False
        bo['hidden'] = not bo['name']          # 'No build order': the strip goes, the B badge brings the list back
        cfg_ = load_settings(); cfg_['build_order'] = bo['name'] or ''
        cfg_['build_order_hidden'] = bo['hidden']
        save_settings(cfg_)
        bo_draw()

    def bo_close():
        """The cross hides the strip but keeps your build; the header icon brings it back."""
        bo_set_hidden(True)

    def bo_menu(anchor=None):
        """The builds in a small dark panel, right under the strip (or under the Build button).
        Like the overlay it never takes focus from the game (the game mutes itself when it loses
        focus). Pick one and it closes; so does a click anywhere else, or the mouse wandering off."""
        old = st.get('bo_pop')
        if old is not None:
            st['bo_pop'] = None
            try: old.destroy()
            except tk.TclError: pass
            return
        pop_ = tk.Toplevel(root); st['bo_pop'] = pop_
        pop_.withdraw()
        pop_.overrideredirect(True); pop_.attributes('-topmost', True); pop_.configure(bg=RIM)
        try: pop_.attributes('-alpha', 0.0)          # drawn out of sight, shown once it is all in place
        except tk.TclError: pass
        inner = tk.Frame(pop_, bg=INK, padx=10, pady=8); inner.pack(padx=1, pady=1)
        hd = tk.Frame(inner, bg=INK); hd.pack(fill='x')
        tk.Frame(hd, bg=GOLDC, width=3, height=14).pack(side='left', padx=(0, 7))
        tk.Label(hd, text='Build order', fg=GOLDC, bg=INK, font=F_HEAD).pack(side='left')
        tk.Label(hd, text=BUILD_SOURCE, fg=FAINT, bg=INK, font=F_TINY).pack(side='right', padx=(14, 0))
        live = {'away': None}
        def close():
            if st.get('bo_pop') is pop_: st['bo_pop'] = None
            try: pop_.destroy()
            except tk.TclError: pass
        def chose(n_):
            close(); bo_pick(n_)
        build_list(inner, [bo['name']], chose, bg=INK).pack(fill='x', pady=(4, 0))
        # show or hide the strip from here; the build you picked is kept either way
        hide_ = tk.Label(inner, text='Show the build order' if bo['hidden'] else 'Hide the build order',
                         fg=MUT, bg=INK, font=F_SMALL, anchor='w', padx=11, pady=4, cursor='hand2')
        hide_.pack(fill='x')
        hover(hide_, MUT, GOLDD)
        hide_.bind('<ButtonRelease-1>', lambda e: (close(), bo_set_hidden(not bo['hidden'])))
        tk.Label(inner, text="Hera hasn't endorsed Wingman yet. I reckon he's great and I hope he does!",
                 fg=FAINT, bg=INK, font=F_TINY, anchor='w', justify='left', wraplength=320
                 ).pack(fill='x', pady=(6, 0), padx=(4, 0))
        at = anchor if anchor is not None or not bo_box.winfo_ismapped() else bo_box
        at = at if at is not None else bo_open
        pop_.update_idletasks()
        x = at.winfo_rootx(); y = at.winfo_rooty() + at.winfo_height() + 4
        sw_, sh_ = pop_.winfo_screenwidth(), pop_.winfo_screenheight()
        w_, h_ = pop_.winfo_reqwidth(), pop_.winfo_reqheight()
        if y + h_ > sh_ - 40: y = max(0, at.winfo_rooty() - h_ - 4)     # no room below: open upwards
        x = max(0, min(x, sw_ - w_ - 4))
        pop_.geometry('+%d+%d' % (x, y))
        pop_.deiconify(); pop_.lift()
        try:                                       # no activate, no taskbar button: same as the overlay
            import ctypes
            u32 = ctypes.windll.user32
            u32.GetAncestor.restype = ctypes.c_void_p
            u32.GetWindowLongW.argtypes = [ctypes.c_void_p, ctypes.c_int]
            u32.SetWindowLongW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_long]
            h = u32.GetAncestor(pop_.winfo_id(), 2)
            u32.SetWindowLongW(ctypes.c_void_p(h), -20, u32.GetWindowLongW(ctypes.c_void_p(h), -20) | 0x08000000 | 0x80)
            down = lambda: bool(u32.GetAsyncKeyState(0x01) & 0x8000) or bool(u32.GetAsyncKeyState(0x02) & 0x8000)
        except Exception:
            down = lambda: False
        fade_in(pop_, to=0.97, wait=20, ms=90)        # drawn see-through, then up in one go
        def over(w):
            try:
                px, py = w.winfo_pointerxy()
                return (w.winfo_rootx() <= px < w.winfo_rootx() + w.winfo_width()
                        and w.winfo_rooty() <= py < w.winfo_rooty() + w.winfo_height())
            except tk.TclError:
                return False
        def watch():
            if st.get('bo_pop') is not pop_: return
            if over(pop_) or over(root) or (anchor is not None and over(anchor)):   # on the list, the overlay or what opened it
                live['away'] = None
            else:
                if down() and not over(root): close(); return           # clicked somewhere else
                live['away'] = live['away'] or time.time()
                if time.time() - live['away'] > 4: close(); return      # wandered off
            pop_.after(80, watch)
        pop_.after(300, watch)

    def bo_step(by=1):
        """Look at the step after (or before) the one on show. Where you really are stays put, and
        the strip goes back to it by itself the moment your pop moves you on."""
        if not bo['name']: return
        found = build_by_name(bo['name'])
        if not found: return
        cur = bo['i'] if bo['view'] is None else bo['view']
        v = max(0, min(len(found[2]) - 1, cur + by))
        bo['view'] = None if v == bo['i'] else v
        bo_draw()

    def bo_live_again():
        bo['view'] = None; bo_draw()

    def bo_pop_text(fg=None):
        """The gold box: your pop as the game shows it, and the pop the step on show is for when you
        are not there yet ('POP 7 \u203a 8'). Without a reading it falls back to the step's own pop."""
        lo, span, hi, live_ = bo.get('span') or (0, '', 0, True)
        t_ = 'POP %s' % span                                    # the pops this step is for
        # A step that covers several villagers ('6 to sheep', '6 to the boar'): how many of them are
        # already out doing it, the way you would count them on screen. 5 on sheep reads 5/6.
        p_ = bo['pop'] or 0
        cnt_ = ('%d/%d' % (p_ - lo + 1, hi - lo + 1)) if (live_ and p_ and hi < 99 and hi > lo
                                                          and lo - 1 <= p_ <= hi) else ''
        if bo_cnt.cget('text') != cnt_:
            bo_cnt.config(text=cnt_)
            if cnt_ and not bo_cnt.winfo_manager() and not bo_prev.winfo_manager(): bo_cnt.pack(side='right')
            elif not cnt_: bo_cnt.pack_forget()
        kw = {'text': t_}
        if fg: kw['fg'] = fg
        if bo_at.cget('text') != t_ or fg: bo_at.config(**kw)

    def bo_follow(pop):
        """Move with the pop counter the Town Center watcher already reads off your screen.

        The builds are written in pop, the same number as the counter, so the scout and any
        militia the build makes are already counted in the steps.
        """
        pop = pop or 0
        if not bo['name'] or pop < 1: return
        found = build_by_name(bo['name'])
        if not found: return
        steps = found[2]
        now = time.time()
        if bo['pop'] and pop > bo['pop'] + 3:
            # a big jump is most likely a misread ('14' as '41'): only believe it if it holds
            if bo.get('jump') != pop: bo['jump'], bo['jump_t'] = pop, now; return
            if now - bo.get('jump_t', now) < 3: return
        bo['jump'] = None
        if pop != bo['pop']:
            # Only a pop back at a starting count, with no game known, is a new game. Losing
            # villagers mid game is not (a drush can do that), and neither is a misread.
            if pop <= 5 and bo['pop'] >= 8 and not tcw.active: bo_fresh(force=True)
            bo['pop'] = pop; bo['pop_t'] = now
            if not bo['done'] and bo['view'] is None:
                try: bo_pop_text()                         # 'n of 6' moves on with every villager
                except Exception: pass

        if bo['done']: return                                # finished: stays that way until the next game
        # Straight off your pop counter, which counts the villagers already out. The one training
        # now is pop + 1, so its step shows (and is said) as it starts training: at pop 7 the 8th
        # villager is in the Town Centre and you hear 'Send 2 to wood' for it.
        i = build_step_at(steps, pop + 1)
        if i > bo['i']:
            bo['i'] = i; bo['view'] = None; bo_draw()      # ticked over: back to live
        if bo['i'] == len(steps) - 1 and not bo['done_t']: bo['done_t'] = now
        # the last step has had its time: well past its pop and a minute and a half on
        if (bo['i'] == len(steps) - 1 and bo['done_t'] and now - bo['done_t'] > 90
                and pop >= steps[-1][0] + 6):
            bo['done'] = True; bo['view'] = None; bo_draw(); log('build order done')

    def pop_now():
        """The pop just changed: move the build order and say the step now, not at the next tick."""
        try:
            if tcw.pop: bo_follow(tcw.pop[0])
            bo_voice_tick()
        except Exception as e_:
            log('build follow: %r' % (e_,))
    def bo_voice_set(on):
        """The speaker on the strip. On, it reads each step out as you reach it."""
        bo['voice'] = bool(on)
        cfg_ = load_settings(); cfg_['build_voice'] = bo['voice']; save_settings(cfg_)
        bo_voice_draw()
        if not on: VOICE.stop(); return
        bo['said_set'] = set()                                   # say the step you are on now
        if waiting_now[0] or not bo['voice_at'] or time.time() < bo['voice_at']:
            VOICE.say('Voice on')                          # so you know the sound works
            bo['said_set'] = {bo['i']}                     # and the step is read when the game gets to it

    def bo_voice_tick():
        """Twice a second: read the step out the first time you reach it."""
        if not bo['voice'] or bo['hidden']: return
        if waiting_now[0] and time.time() - getattr(tcw, 'pop_t', 0) > 10: return     # no game on
        if not bo['voice_at'] or time.time() < bo['voice_at']: return
        found = build_by_name(bo['name'])
        if not found: return
        if bo['done']:
            if not bo['said_done']: bo['said_done'] = True; VOICE.say(BO_DONE)
            return
        steps = found[2]
        said = bo.setdefault('said_set', set())
        i = max(0, min(bo['i'], len(steps) - 1))
        if i not in said:                                  # the step on the strip, read out as it comes up
            said.add(i); VOICE.say(spoken_step(steps[i][2]))
            if i + 1 < len(steps): VOICE.prep(spoken_step(steps[i + 1][2]))   # the next one, ready to go

    def bo_fresh(at=None, force=False):
        """Back to the first step for a new game. Called by the recording turning up and by the loading
        screen going, whichever is first: the second one within a couple of minutes changes nothing."""
        now = time.time()
        if not force and now - bo['game_t'] < 120:
            if at and not bo['voice_at']: bo['voice_at'] = at
            return
        bo['game_t'] = now
        bo['i'] = 0; bo['pop'] = 0; bo['said_set'] = set(); bo['view'] = None; bo['voice_at'] = at
        bo['done'] = False; bo['done_t'] = 0; bo['said_done'] = False; bo['pop_t'] = now
        if bo['voice'] and bo['name']:
            VOICE.warm()
            try:
                found_ = build_by_name(bo['name'])
                if found_: VOICE.prep(spoken_step(found_[2][0][2]))      # the first line, ready
            except Exception: pass
        try: bo_draw()
        except Exception: pass

    def bo_loaded():
        """The loading screen has gone, so the game clock is running now. Mid game the screen can
        look like a loading screen for a moment; a big pop read in the last minute means it was not."""
        p_ = getattr(tcw, 'pop', None)
        if p_ and p_[0] > 10 and time.time() - getattr(tcw, 'pop_t', 0) < 60:
            log('loading screen gone, but a game was already on: the build order carries on'); return
        bo_fresh(time.time() + bo_voice_wait())

    def bo_voice_wait():
        found_ = build_by_name(bo['name'])
        return voice_start_s(found_[2] if found_ else [])

    def bo_game_start(f):
        """A new game: the build starts again, and the voice waits until the clock has run a bit."""
        bo_fresh(force=True)
        wait_ = bo_voice_wait()
        def work():
            try:
                fresh = time.time() - os.path.getctime(f) <= 40       # not opened part way through
                if fresh:
                    size0 = os.path.getsize(f)
                    for _ in range(120):              # the recording grows once the game clock runs
                        if os.path.getsize(f) > size0: break
                        time.sleep(0.25)
                at = time.time() + (wait_ if fresh else min(wait_, 3))
            except OSError:
                at = time.time() + wait_
            def go():
                if st.get('last') == f and not bo['voice_at']: bo['voice_at'] = at
            root.after(0, go)
        threading.Thread(target=work, daemon=True).start()

    rec_line = tk.Label(frame, text='', fg=MUT, bg=BG, font=F_SMALL, anchor='w', justify='left', wraplength=PANEL_W)
    rec_line.grid(row=4, column=0, columnspan=4, sticky='w', pady=(3, 0)); rec_line.grid_remove()

    # the card that goes up once the service confirms how the last game went
    card = tk.Frame(frame, bg=PANEL, highlightthickness=1, highlightbackground=EDGE, padx=9, pady=6)
    card.grid(row=4, column=0, columnspan=4, sticky='we', pady=(8, 0)); card.grid_remove()
    card.columnconfigure(1, weight=1)
    card_word = tk.Label(card, text='', fg=GREEN, bg=PANEL, font=(DISPLAY, 11, 'bold'), anchor='w')
    card_word.grid(row=0, column=0, sticky='w')
    card_elo = tk.Label(card, text='', fg=MUT, bg=PANEL, font=F_SMALL, anchor='e')
    card_elo.grid(row=0, column=1, sticky='e')
    card_line = tk.Label(card, text='', fg=TXT, bg=PANEL, font=F_SMALL, anchor='w', justify='left',
                         wraplength=PANEL_W - 24)
    card_line.grid(row=1, column=0, columnspan=2, sticky='w', pady=(3, 0))
    # the score line: how your side's total compares, and the flag when the game looks gone
    score_line = tk.Label(frame, text='', fg=MUT, bg=PANEL, font=F_SMALL, anchor='w', padx=9, pady=4,
                          justify='left', wraplength=PANEL_W - 24, highlightthickness=1, highlightbackground=EDGE)
    score_line.grid(row=5, column=0, columnspan=4, sticky='we', pady=(6, 0)); score_line.grid_remove()
    opp_area = tk.Frame(frame, bg=PANEL, highlightthickness=1, highlightbackground=EDGE, padx=9, pady=6)
    opp_area.grid(row=6, column=0, columnspan=4, sticky='we'); opp_area.grid_remove()

    # footer: the one action, with the hint that only appears while the mouse is over the overlay
    footsep = Rule(frame)
    footsep.grid(row=7, column=0, columnspan=4, sticky='we', pady=(9, 0))
    host_row = tk.Frame(frame, bg=BG)
    host_row.grid(row=8, column=0, columnspan=4, sticky='we', pady=(7, 0))
    host_row.columnconfigure(1, weight=1)
    # The party invite button sits up in the header, where the state tag goes while a game is on,
    # so with no game on the whole panel is one row. The row below it only appears when the
    # button has something to say.
    btn_plate = tk.Frame(head, bg=RIM, padx=1, pady=1)           # dark edge around the bronze face
    host_btn = tk.Label(btn_plate, text='Ranked invite', fg='#2a2113', bg=GOLD, font=(DISPLAY, 9, 'bold'),
                        padx=8, pady=3, cursor='hand2')
    host_btn.pack()
    host_btn.bind('<Enter>', lambda e: host_btn.cget('bg') == GOLD and host_btn.config(bg=GOLDD), add='+')
    host_btn.bind('<Leave>', lambda e: host_btn.cget('bg') == GOLDD and host_btn.config(bg=GOLD), add='+')
    btn_plate.grid(row=0, column=2, sticky='e', padx=(6, 2))
    state.grid_remove()                                          # the app opens with no game on
    hint = tk.Label(host_row, text='drag to move  \u00b7  click the name to roll up  \u00b7  W/L for your record', fg=FAINT, bg=BG,
                    font=F_TINY, anchor='e', justify='right', wraplength=PANEL_W - 20)
    hint.grid(row=0, column=1, sticky='e', padx=(12, 2)); hint.grid_remove()
    host_msg = tk.Label(host_row, text='', fg='#b8b19f', bg=BG, font=F_SMALL, anchor='w',
                        justify='left', wraplength=PANEL_W)
    host_msg.grid(row=1, column=0, columnspan=2, sticky='w')
    admin_box = tk.Frame(host_row, bg=BG)                        # the admin buttons, only when they're needed
    admin_box.grid(row=2, column=0, columnspan=2, sticky='w', pady=(6, 0)); admin_box.grid_remove()
    host_row.grid_remove()                                       # nothing to say yet
    idle_size(True)                 # the app opens with no game on, so start small
    try:
        if god_mode_status()[0] != 'on':
            host_msg.config(text='Idle TC alert needs the God Mode mod (%s). Get it in Settings.'
                                 % ('not installed' if god_mode_status()[0] == 'missing' else 'switched off'))
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
    OV_W = PANEL_W + 2 * 12 + 2 + 4        # the panel, its padding, its edge and the bronze rim
    _hold = {'hwnd': None, 'short': 0.0, 'said': 0.0}
    def repaint():
        """Have Windows draw the whole overlay now, every part of it, so a resize never leaves a
        black strip or a part still drawn where it used to be."""
        try:
            import ctypes as _ct
            u_ = _ct.windll.user32
            if not _hold['hwnd']:
                u_.GetAncestor.restype = _ct.c_void_p
                _hold['hwnd'] = u_.GetAncestor(root.winfo_id(), 2)
            u_.RedrawWindow(_ct.c_void_p(_hold['hwnd']), None, None, 0x0001 | 0x0004 | 0x0080 | 0x0100 | 0x0400)
        except Exception:
            pass
    def refit():
        try:
            frame.pack_configure(fill='both', expand=True, padx=2, pady=2)   # re-lays it out to the window
            root.update_idletasks()
        except tk.TclError:
            pass
    def hold_now():
        # the height everything inside asks for: the panel's own request (plus its 2px margin),
        # or the window's, whichever is more
        h_ = max(root.winfo_reqheight(), frame.winfo_reqheight() + 4)
        if root.winfo_width() != OV_W or root.winfo_height() != h_:
            root.geometry('%dx%d' % (OV_W, h_))
            root.update_idletasks()
            refit()
            repaint()
        elif frame.winfo_height() + 4 < h_ - 1:
            # Windows did not tell Tk the window had grown, so the panel was left at the old size
            # with the bottom cut off (seen in the log as 'overlay squeezed'): lay it out again
            refit(); repaint()
        # anything still squeezed for more than a second gets written down, to find out why
        now_ = time.time()
        if frame.winfo_height() + 1 < frame.winfo_reqheight():
            if not _hold['short']: _hold['short'] = now_
            elif now_ - _hold['short'] > 1 and now_ - _hold['said'] > 60:
                _hold['said'] = now_
                log('overlay squeezed: window %dx%d (asks %d), panel %d (asks %d)' % (
                    root.winfo_width(), root.winfo_height(), root.winfo_reqheight(),
                    frame.winfo_height(), frame.winfo_reqheight()))
        else:
            _hold['short'] = 0.0
    # Changes in one piece. When a part of the overlay is rebuilt (the opponents, the build order
    # step, a section opening or closing), the new layout and the new window size are worked out
    # and applied together, straight away, rather than the size catching up a moment later. That
    # moment was the text hanging below the edge and the black strip while it grew.
    _calm = {'n': 0}
    def calm(fn):
        def run_(*a, **k):
            if _calm['n']: return fn(*a, **k)              # already inside one: the outer one sizes it
            _calm['n'] += 1
            try:
                r_ = fn(*a, **k)
                try: root.update_idletasks(); hold_now(); root.update_idletasks()
                except Exception: pass
            finally:
                _calm['n'] -= 1
            return r_
        return run_
    def hold_size():
        # One width, always: the overlay never jumps sideways as things come and go. Anything
        # wider than that wraps (or, at worst, is cut at the edge). Only the height follows.
        # Straight to the new height in one go: every resize makes Windows redraw the whole
        # see-through window, so it happens once, not over several frames.
        try:
            hold_now()
        except Exception as e:
            if not _hold.get('err'): _hold['err'] = 1; log('overlay size: %r' % (e,))
        try: root.after(16, hold_size)              # never stops, whatever happened above
        except Exception: pass
    root.geometry('%dx%d' % (OV_W, root.winfo_reqheight()))
    root.after(20, hold_size)
    bo_draw = calm(bo_draw); idle_size = calm(idle_size)
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
        # hidden from captures by default (so the screen reads never see it); Settings can show it
        u32.SetWindowDisplayAffinity(ctypes.c_void_p(top), 0 if load_settings().get('show_in_shots') else 0x11)
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
        try:
            if os.path.getsize(LOG) > 0: shutil.copyfile(LOG, LOG[:-4] + '.previous.log')   # the run before this one
        except OSError: pass
        with open(LOG, 'w', encoding='utf-8') as f: f.write('%s %s started from %s\n' % (APP_NAME, VERSION, self_path()))
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
        try:
            if tc['win'] is not None and tc['win'].winfo_viewable():
                tc['flash'] ^= 1
                tc['label'].config(bg=TC_RED[tc['flash']]); tc['sub'].config(bg=TC_RED[tc['flash']])
                tc['house'].config(bg=TC_BLUE[tc['flash']])
                tc['note'].config(bg=TC_GOLD[tc['flash']])
            if tc.get('note_until') and time.time() >= tc['note_until']:
                tc['note_until'] = 0; tc_draw()         # the reminder has had its few seconds
        except Exception as e_:
            if not st.get('pulse_err'): st['pulse_err'] = 1; log('tc pulse: %r' % (e_,))
        try:
            if tcw.pop: bo_follow(tcw.pop[0])
        except Exception: pass
        try: bo_voice_tick()
        except Exception as e_: log('build voice: %r' % (e_,))
        root.after(450, tc_pulse)

    def tc_note(text, seconds=8):
        """A timed reminder on the same badge: up for a few seconds, then gone."""
        tc_window()
        tc['note'].config(text=text); tc['note_until'] = time.time() + seconds
        tc_draw()

    def reminders():
        """The reminder settings. Looked up afresh every few seconds, not twice a second."""
        now = time.time()
        if now - st.get('rem_t', 0) > 5:
            c = load_settings()
            st['rem'] = dict(castle=c.get('castle_note', True), feudal=c.get('feudal_note', True),
                             castle_food=int(typed_number(c.get('castle_food'), CASTLE_NOTE_FOOD, 100, 5000)),
                             feudal_pop=int(typed_number(c.get('feudal_pop'), FEUDAL_NOTE_POP, 5, 60)))
            st['rem_t'] = now
        return st['rem']

    def castle_reminder():
        """Once you are 13 minutes in and your food reaches 500 (the food Castle Age costs), one quick
        nudge to check the two buildings it needs. If the food can't be read off the screen, it falls
        back to 17 minutes. Not if you are already in Castle Age, and only once a game."""
        if st.get('last') is None or st.get('castle_note') or not tcw.active: return
        if time.time() - st.get('watch_t', 0) < 60: return       # just opened, or just restarted: look first
        want = reminders(); food_at = want['castle_food']
        mins = tcw.game_minutes(time.time())
        if mins < CASTLE_NOTE_MIN: return
        food = getattr(tcw, 'food', None)
        pop = tcw.pop[0] if tcw.pop else None
        if food is not None and food < food_at: return
        # No food reading to go on: 17 minutes, but only with an economy that could be clicking up.
        # (Without the game clock the minutes are a guess that counts pauses, so the pop decides.)
        if food is None and (mins < CASTLE_NOTE_LATE or pop is None or pop < 22): return
        st['castle_note'] = True
        if tcw.age >= 3 or not want['castle']: return
        if st.get('ended') and st.get('ended') == st.get('last'): return     # that game has finished
        log('castle reminder shown (food %s, %.1f min)' % (food, mins))
        tc_note(('%d FOOD' % food_at if food is not None else '%d MIN' % CASTLE_NOTE_LATE)
                + '  \u00b7  2 BUILDINGS FOR CASTLE AGE?')

    def feudal_reminder():
        """When your population reaches 18 (or the number set in Settings) and you are still in
        the Dark Age, one quick nudge to check the two buildings Feudal Age needs. Only once a game."""
        if st.get('last') is None or st.get('feudal_note') or not tcw.active or not tcw.pop: return
        want = reminders(); at = want['feudal_pop']
        pop = tcw.pop[0]
        if pop < at: return
        st['feudal_note'] = True
        if tcw.age >= 2 or pop > at + 3: return                 # already up, or opened part way through
        if not want['feudal']: return
        log('%d pop reminder shown' % at)
        tc_note('%d POP  ·  2 BUILDINGS FOR FEUDAL AGE?' % at)

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
    tcw.on_pop = lambda: root.after(0, pop_now)       # the build order moves the moment the pop does
    tcw.start(); tc_pulse()
    watcher.on_lines = tcw.message_lines

    # ---- score check: your side's total against theirs, and a flag once the game looks gone
    def place_found():
        """The 'Red found' note sits on the score's line, over on the right. When the two do not
        fit side by side, or the red concede bar has the line, it takes the line above instead."""
        if ' found' not in rec_line.cget('text') or st.get('rolled'): return
        rec_line.grid(row=4, column=0, columnspan=4, sticky='w', pady=(3, 0))   # its own line, under the build order

    def score_notify(mine_, theirs, behind, flag):
        def go():
            if mine_ is None or st.get('last') is None:
                score_line.config(text=''); score_line.grid_remove(); place_found(); return
            pct = int(round(abs(behind) * 100))
            nums = '{:,} against {:,}'.format(mine_, theirs)
            if flag:
                score_line.config(text=' CONCEDE AVAILABLE  \u00b7  %d%% behind  \u00b7  %s ' % (pct, nums),
                                  fg='white', bg='#b3261e', font=(DISPLAY, 9, 'bold'))
            else:                                     # only the concede flag earns a line; the plain score is not shown
                score_line.config(text=''); score_line.grid_remove(); place_found(); return
            if not st.get('rolled'): score_line.grid()
            place_found()
        try: root.after(0, go)
        except Exception: pass
    scorew = ScoreWatcher(score_notify, lambda: tcw.game_minutes(time.time()))
    scorew.enabled = load_settings().get('concede_flag', True)
    scorew.start()

    def score_off():
        scorew.active = False
        score_line.config(text=''); score_line.grid_remove()

    def ping_at(x, y, colour):
        """A ring drawn on the screen over the spot on your minimap where the opponent turned up.

        This is a picture sitting on top of your own screen, like the rest of the overlay. It is
        not the game's flare: nothing is sent to the game, nothing is placed in the world, and
        your team sees none of it.
        """
        KEY = '#010203'                      # the colour the window makes see-through
        S = 74
        try:
            w = tk.Toplevel(root)
            w.overrideredirect(True)
            w.attributes('-topmost', True)
            try:
                w.attributes('-transparentcolor', KEY)
            except tk.TclError:
                w.destroy(); return          # without it this would be a black square on your map
            px = max(0, min(int(x - S / 2), root.winfo_screenwidth() - S))
            py = max(0, min(int(y - S / 2), root.winfo_screenheight() - S))
            w.geometry('%dx%d+%d+%d' % (S, S, px, py))
            c = tk.Canvas(w, width=S, height=S, bg=KEY, highlightthickness=0)
            c.pack()
            w.update_idletasks()
            try:
                import ctypes
                h = ctypes.windll.user32.GetParent(w.winfo_id()) or w.winfo_id()
                ex = ctypes.windll.user32.GetWindowLongW(h, -20)
                ctypes.windll.user32.SetWindowLongW(h, -20, ex | 0x20 | 0x80 | 0x08000000)
                ctypes.windll.user32.SetWindowDisplayAffinity(h, 0x11)   # keep it out of captures
            except Exception:
                pass
        except tk.TclError:
            return
        mid = S / 2.0
        def frame(step=0):
            try:
                c.delete('all')
                for k in range(2):                       # two thin rings chasing each other outward
                    t = step - k * 8
                    if t < 0: continue
                    t %= 21
                    r = 5 + t * 1.5
                    if r > mid - 2: continue
                    c.create_oval(mid - r, mid - r, mid + r, mid + r, outline=colour,
                                  width=2 if t < 8 else 1)
                c.create_oval(mid - 2, mid - 2, mid + 2, mid + 2, fill=colour, outline=colour)
                if step < 46: w.after(45, lambda: frame(step + 1))   # about two seconds, then gone
                else: w.destroy()
            except tk.TclError:
                pass
        frame()

    def scout_found(idx, label, x=None, y=None):
        """An opponent's colour has turned up on your own minimap for the first time."""
        def go():
            civ = (st.get('opp_civ') or {}).get(idx, '')
            rec_line.config(text='%s found%s' % (label, ('   \u00b7   ' + civ) if civ else ''),
                            fg=name_colour(idx, GOLDC))
            rec_line.grid(); place_found()
            def clear():
                if '%s found' % label in rec_line.cget('text'):
                    rec_line.config(text=''); rec_line.grid_remove()
            root.after(25000, clear)
            if x is not None and load_settings().get('scout_ping', True):
                ping_at(x, y, name_colour(idx, GOLDC))
        try: root.after(0, go)
        except Exception: pass
        play_voice(os.path.join(sound_dir(), '%s.wav' % (label or '').lower()))

    scout = ScoutWatcher(scout_found)
    scout.start()

    def start_scout(players, mine_p, strings_, same_game=False, recording=None):
        """Watch for the opponents in this game, and nobody else. Allies and your own colour
        are never looked for, so your own units can never set it off."""
        st['opp_civ'] = {}
        targets = {}
        # off unless switched on in Settings (a new name, so an old 'on' does not carry over)
        if load_settings().get('scout_callout', False) and mine_p is not None:
            for pp in players:
                if pp is mine_p: continue
                if mine_p.get('team', 0) > 1 and pp.get('team') == mine_p.get('team'): continue
                idx = pp.get('colour')
                if idx is None or not (0 <= idx < len(PLAYER_NAMES)): continue
                targets[idx] = PLAYER_NAMES[idx]
                try: st['opp_civ'][idx] = civ_name(pp['civ'], strings_)
                except Exception: pass
        scout.start_game(targets, keep=same_game, recording=recording)
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
                tk.Label(who, text=ln, fg=fg_, bg=PANEL, font=F_SMALL, anchor='w', justify='left',
                         wraplength=max(200, bw - 150)).pack(fill='x', anchor='w', pady=(3, 0))
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
        cfg_b = load_settings()
        want_map = False                                        # the map tips panel: taken out, Ash did not like it
        want_civ = cfg_b.get('civ_panel_loading', False)        # your opponent's civ, under it
        if not (want_map or want_civ):
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
            BW, YOURS, YH, THEIRS, TH = 760, 106, 380, 496, 434      # the map panel up top, theirs under it
            green = (int(cx - BW / 2 * s_), int(y + YOURS * s_), int(BW * s_), int(YH * s_))
            red = (int(cx - BW / 2 * s_), int(y + THEIRS * s_), int(BW * s_), int(TH * s_))
            # the top panel: the map, and what is different about it (it used to be your own civ)
            mname, mdesc = None, ''
            if lob:
                if lob['selected'] != lob['resolved']:
                    mname, mdesc = 'Hidden map', 'Hidden in the lobby. Scout early to work out what you got.'
                else:
                    mname, mdesc = map_name_desc(maps, strings, lob['resolved'])
            if not mname and lines:
                mname, mdesc = map_from_screen(maps, strings, lines)
            st['boxes_ok'] = (not want_civ or bool(me_p)) and (not want_map or bool(mname))
            if mname and want_map:
                map_rec = short_record([g for g in load_stats()['games'] if g.get('map') == mname])
                tips_ = map_tips(mname)
                make_box(green, GOLDC, mname, map_sections(mname, mdesc), tag='MAP', letter='M',
                         meta=[('Your record here: ' + map_rec) if map_rec else ''])
            if opps and want_civ:
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
                root.after(0, lambda: show_post_game(gid) if review_gid[0] == gid and
                           st.get('last') is None else None)
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
        rec_line.grid(row=4, column=0, columnspan=4, sticky='w', pady=(3, 0))

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


    # POST-GAME REVIEW: deliberately built into the existing Tkinter application.
    # WHY: Wingman already records matches, so a useful review must work offline and
    # must not introduce another service, dependency, or incompatible exe asset.
    # The game service is authoritative for wins/losses; never infer a result from
    # an end-screen detection or from the player's score.
    review_window = [None]
    review_gid = [None]

    def close_post_game():
        """Close the optional review without changing the persisted match record."""
        w = review_window[0]
        review_window[0] = None
        review_gid[0] = None
        try:
            if w is not None and w.winfo_exists(): w.destroy()
        except Exception: pass

    def show_post_game(gid):
        """Open/refresh a dedicated, scrollable post-game screen on the Tk main thread.

        DESIGN INTENT: surface verified facts, make uncertainty explicit, and offer
        one actionable practice focus based on actual match history. We do not
        invent build timings, army compositions, or replay-derived statistics.
        This screen opens on the end-screen event; service results arrive later,
        and calling it again refreshes the same window rather than stacking them.
        """
        if not gid or st.get('last') is not None: return
        try:
            games = load_stats().get('games', [])
            g = next((row for row in games if row.get('id') == gid), None)
            if not g: return
            old_geometry = None
            if review_window[0] is not None:
                try:
                    old_geometry = review_window[0].geometry()
                except Exception: pass
                close_post_game()  # rebuild with latest confirmed data
            w = tk.Toplevel(root)
            review_window[0], review_gid[0] = w, gid
            w.title('Wingman | Post-game review')
            w.configure(bg=BG)
            w.geometry(old_geometry or '740x700')
            w.minsize(560, 440)
            # This is an actual independent Tk window, not just backend data.
            # Preserve its position when refreshing a pending service result.
            w.protocol('WM_DELETE_WINDOW', close_post_game)
            try: w.attributes('-topmost', True)
            except Exception: pass

            # Scrollable layout: no content disappears on smaller laptop displays.
            shell = tk.Frame(w, bg=BG); shell.pack(fill='both', expand=True)
            canvas = tk.Canvas(shell, bg=BG, highlightthickness=0)
            scroll = tk.Scrollbar(shell, orient='vertical', command=canvas.yview)
            canvas.configure(yscrollcommand=scroll.set)
            scroll.pack(side='right', fill='y'); canvas.pack(side='left', fill='both', expand=True)
            page = tk.Frame(canvas, bg=BG, padx=24, pady=20)
            item = canvas.create_window((0, 0), window=page, anchor='nw')
            page.bind('<Configure>', lambda e: canvas.configure(scrollregion=canvas.bbox('all')))
            canvas.bind('<Configure>', lambda e: canvas.itemconfigure(item, width=e.width))
            def wheel_review(e):
                if e.delta: canvas.yview_scroll(-int(e.delta / 120), 'units')
            # Bind the scroll wheel to the canvas and content; child labels may
            # intercept wheel events, so use a binding on each generated label too.
            canvas.bind('<MouseWheel>', wheel_review)
            page.bind('<MouseWheel>', wheel_review)

            def label(parent, value, size=11, color=FG, bold=False, wrap=660):
                font_ = ('Segoe UI', size, 'bold' if bold else 'normal')
                obj = tk.Label(parent, text=str(value), bg=BG, fg=color, font=font_,
                               anchor='w', justify='left', wraplength=wrap)
                obj.pack(fill='x', pady=(0, 6))
                obj.bind('<MouseWheel>', wheel_review)
                return obj

            def section(title):
                label(page, title.upper(), 11, GOLD, True)
                tk.Frame(page, bg=EDGE, height=1).pack(fill='x', pady=(0, 12))

            def detail(k, v):
                line = tk.Frame(page, bg=BG); line.pack(fill='x', pady=(0, 6))
                key_label = tk.Label(line, text=k, width=19, anchor='w', bg=BG, fg=MUT,
                         font=('Segoe UI', 10))
                key_label.pack(side='left')
                value_label = tk.Label(line, text=str(v), anchor='w', bg=BG, fg=FG,
                         font=('Segoe UI', 10, 'bold'), wraplength=450,
                         justify='left')
                value_label.pack(side='left', fill='x', expand=True)
                for widget in (line, key_label, value_label):
                    widget.bind('<MouseWheel>', wheel_review)

            result = g.get('result')
            verified = result in ('win', 'loss')
            label(page, 'MATCH DEBRIEF', 12, GOLD, True)
            label(page, 'VICTORY' if result == 'win' else
                  'DEFEAT' if result == 'loss' else 'RESULT PENDING',
                  25, GREEN if result == 'win' else REDC if result == 'loss' else GOLD, True)
            label(page, 'Confirmed by match history' if verified else
                  'Waiting for the game service to confirm the result. No outcome is assumed.',
                  10, MUT)
            section('Match overview')
            detail('Civilization', g.get('civ') or 'Unknown')
            detail('Opponent civilization', g.get('opp') or 'Unknown')
            detail('Map', g.get('map') or 'Unknown')
            detail('Format', g.get('size') or g.get('mode') or 'Unknown')
            detail('Queue', 'Ranked' if g.get('ranked') else 'Unspecified')
            detail('Duration', fmt_len(game_length(g)) if game_length(g) else 'Not yet available')
            detail('Played', g.get('at') or 'Unknown')
            before, after = g.get('rating'), g.get('rating_after')
            if isinstance(before, (int, float)) and isinstance(after, (int, float)):
                delta = after - before
                detail('Rating', '%s  (%+d)' % (after, delta))
            elif after is not None:
                detail('Rating after', after)

            # History comparisons use only confirmed results; unknown matches
            # must not quietly count as losses or dilute the win percentage.
            # If timestamps are absent, do not include unrelated newer games.
            # A missing start timestamp means we cannot establish chronology.
            started = g.get('started')
            earlier = [x for x in games if x.get('id') != gid
                       and x.get('result') in ('win', 'loss')
                       and isinstance(started, (int, float))
                       and isinstance(x.get('started'), (int, float))
                       and x['started'] < started]
            def record(rows):
                wins = sum(x.get('result') == 'win' for x in rows)
                return '%d wins / %d games (%d%%)' % (
                    wins, len(rows), round(100.0 * wins / len(rows))) if rows else 'No confirmed history yet'
            section('Your track record before this game')
            detail('Overall', record(earlier))
            detail('With this civ', record([x for x in earlier if x.get('civ') == g.get('civ')]))
            detail('On this map', record([x for x in earlier if x.get('map') == g.get('map')]))
            detail('Last 10', record(sorted(earlier, key=lambda x: x.get('started') or 0)[-10:]))

            # PERFORMANCE METRICS: show useful placeholders now, but never invent
            # numbers. Wingman's existing replay-lobby reader does not decode
            # action events, and the live TC watcher detects *possible* idleness
            # from OCR rather than measuring an authoritative game timeline.
            # Future replay parsers or validated trackers can populate these keys
            # on the existing game row without changing this UI contract.
            section('Performance metrics')
            def metric_value(key, suffix, minimum=0, maximum=None):
                value = g.get(key)
                if isinstance(value, bool) or not isinstance(value, (int, float)):
                    return 'Not recorded'
                if not (minimum <= value and (maximum is None or value <= maximum)):
                    return 'Not recorded'
                return ('%s %s' % (round(value, 1), suffix)).strip()
            detail('APM', metric_value('apm', 'actions/min', 0, 1000))
            detail('Effective APM', metric_value('eapm', 'actions/min', 0, 1000))
            detail('Idle TC time', metric_value('idle_tc_seconds', 'seconds', 0, 14400))
            detail('TC idle share', metric_value('idle_tc_pct', '%', 0, 100))
            detail('Villagers lost', metric_value('villagers_lost', '', 0, 1000))
            detail('Resources floated', metric_value('resources_floated', '', 0, 1000000))
            label(page, 'Metrics appear when reliable match telemetry is available. '
                  'APM requires action events; TC idle time requires a trustworthy '
                  'time series. Wingman does not currently record either.', 9, MUT)

            section('Coach notes')
            same_civ = [x for x in earlier if x.get('civ') == g.get('civ')]
            same_map = [x for x in earlier if x.get('map') == g.get('map')]
            if not verified:
                advice = 'The outcome is still pending. Review your opening and note the first decision you would change.'
            elif len(same_civ) >= 3 and sum(x.get('result') == 'loss' for x in same_civ) > len(same_civ) / 2:
                advice = ('Practice one repeatable opening with %s. Your earlier confirmed '
                          'matches with this civilization show more losses than wins.' % (g.get('civ') or 'this civ'))
            elif len(same_map) >= 3 and sum(x.get('result') == 'loss' for x in same_map) > len(same_map) / 2:
                advice = ('Review your first five minutes on %s. Your earlier confirmed '
                          'matches on this map show more losses than wins.' % (g.get('map') or 'this map'))
            elif result == 'loss':
                advice = 'Pick one turning point from this loss and practice a response in your next game.'
            else:
                advice = 'Identify the opening decision that worked and aim to repeat it next match.'
            # Only give metric-specific coaching when the source provides a
            # plausible measurement; no fabricated thresholds for missing data.
            idle_pct = g.get('idle_tc_pct')
            if isinstance(idle_pct, (int, float)) and not isinstance(idle_pct, bool) and 15 <= idle_pct <= 100:
                advice += ' Prioritise villager production: your measured TC idle share was %.1f%%.' % idle_pct
            apm = g.get('apm')
            if isinstance(apm, (int, float)) and not isinstance(apm, bool) and 0 <= apm < 20:
                advice += ' Your measured APM was low; practise a simple production-and-scouting rhythm.'
            label(page, advice, 11, FG, wrap=660)
            label(page, 'These are history-based prompts, not claims about unobserved '
                  'economy, army, or build-order events.', 9, MUT)
            section('Next steps')
            label(page, 'Compare your build-order milestones and scout notes while the '
                  'match is fresh. Detailed timing analysis needs recorded milestones '
                  'or replay parsing and is intentionally not fabricated here.', 10, FG)
            buttons = tk.Frame(page, bg=BG); buttons.pack(fill='x', pady=(12, 18))
            tk.Button(buttons, text='Refresh result', command=lambda: show_post_game(gid),
                      bg=RIM, fg=FG, padx=14, pady=7).pack(side='left', padx=(0, 10))
            tk.Button(buttons, text='Close', command=close_post_game,
                      bg=RIM, fg=FG, padx=14, pady=7).pack(side='left')
            w.lift()
        except Exception as e:
            log('post-game review failed: %r' % (e,))
            close_post_game()

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
            st['ended_t'], st['ended_hits'] = time.time(), 0
            try: st['ended_size'] = os.path.getsize(st['last'])
            except OSError: st['ended_size'] = 0
            st['was'] = st['last']                         # so its counts survive if it turns out not to be over
            st['last'] = None; st['first'] = None; st['herd'] = None
            watcher.active = False
            tcw.active = False
            bo['voice_at'] = None                          # nothing more to say until the next game starts
            scout.active = False; scout.stop_game(); score_off()
            title.config(text=HEAD_NAME); idle_size(True)
            state.config(text='WAITING', fg=MUT)           # or the tag goes on saying IN GAME at the menu
            rec_line.config(text=''); rec_line.grid_remove(); show_footer(True)
            stats_btn.grid()
            show_opponents([]); hide_boxes()
            # Do not interrupt a player with a full-size review before the
            # end-screen detection has been confirmed. The existing game-over
            # detector can briefly misfire while a replay is still growing.
            if gid:
                root.after(1800, lambda: show_post_game(gid) if
                           st.get('ended') and st.get('last') is None else None)
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
    loadw.still_running = lambda: bool(st.get('last')) and recording_growing(st['last'])
    loadw.gone = lambda: root.after(0, bo_loaded)        # the build order starts its clock off the screen too
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

    def _alive(w_):
        try: return bool(w_.winfo_exists())
        except Exception: return False
    def toggle(widget):
        if widget.winfo_manager(): widget.grid_remove()
        else: widget.grid()
    st['actions'][title] = lambda: toggle(body)

    def press(e):
        st['shift'] = bool(e.state & 1)
        st['drag'] = (e.x_root - root.winfo_x(), e.y_root - root.winfo_y(), e.x_root, e.y_root)
    def motion(e):
        if st['drag'] and not st.get('locked'):
            root.geometry('+%d+%d' % (e.x_root - st['drag'][0], e.y_root - st['drag'][1]))
    def remember_pos():
        try:
            c = load_settings(); c['pos'] = [root.winfo_x(), root.winfo_y()]; save_settings(c)
        except Exception: pass
    def release(e):
        d = st['drag']; st['drag'] = None
        if d and abs(e.x_root - d[2]) < 4 and abs(e.y_root - d[3]) < 4:
            act = st['actions'].get(e.widget)
            if act: calm(act)()
        elif d and not st.get('locked'):
            remember_pos()                 # moved: keep this spot for next time
    def bind_all(w):
        w.bind('<ButtonPress-1>', press); w.bind('<B1-Motion>', motion)
        w.bind('<ButtonRelease-1>', release)
    for w in (root, frame, head, badge, title, state, stats_btn, body, rec_line, opp_area, footsep, sep,
              host_row, btn_plate, host_btn, host_msg, hint,
              card, card_word, card_line, card_elo,
              bo_box, bo_caprow, bo_cap, bo_goal, bo_at, bo_right, bo_navf, bo_slot, bo_back, bo_fwd, bo_prev, bo_cnt, bo_x, bo_snd, bo_now, bo_next, bo_nrow, bo_ntag, bo_prog, bo_live,
              live_btn, bo_open): bind_all(w)
    def show_lock():
        if st.get('locked') and crest_locked is not None: badge.config(image=crest_locked)
        else: badge.config(image=getattr(badge, 'image', '') or '')
    def toggle_lock():
        """The crest locks the overlay where it is, so it cannot be dragged by accident; click
        it again to move it."""
        st['locked'] = not st.get('locked')
        try:
            c_ = load_settings(); c_['locked'] = st['locked']; save_settings(c_)
        except Exception: pass
        show_lock()
        log('overlay %s' % ('locked in place' if st['locked'] else 'unlocked'))
    st['locked'] = bool(load_settings().get('locked'))
    show_lock()
    st['actions'][badge] = toggle_lock
    st['actions'][bo_prog] = bo_menu
    st['actions'][bo_cap] = bo_menu                  # the caption picks the build
    st['actions'][bo_caprow] = bo_menu
    st['actions'][bo_goal] = bo_menu
    # a click anywhere on the build strip opens the list; a right click on the step moves it on
    st['actions'][bo_now] = bo_menu
    st['actions'][bo_box] = bo_menu
    st['actions'][bo_at] = bo_menu
    bo_now.bind('<Button-3>', lambda e: bo_step(-1), add='+')
    st['actions'][bo_next] = lambda: bo_step(1)       # the next step: look at it
    st['actions'][bo_nrow] = lambda: bo_step(1)
    st['actions'][bo_ntag] = lambda: bo_step(1)
    st['actions'][bo_live] = bo_live_again            # and back to where you are
    st['actions'][bo_prev] = bo_live_again
    st['actions'][bo_back] = lambda: bo_step(-1)
    st['actions'][bo_fwd] = lambda: bo_step(1)
    st['actions'][bo_navf] = lambda: None
    st['actions'][bo_slot] = lambda: None
    st['actions'][bo_right] = lambda: None
    hover(bo_back, MUT, GOLDD); hover(bo_fwd, MUT, GOLDD)
    bo_prev.bind('<Enter>', lambda e: bo_prev.config(bg=GOLDD), add='+')
    bo_prev.bind('<Leave>', lambda e: bo_prev.config(bg=GOLDC), add='+')
    for w_ in (bo_next, bo_nrow, bo_ntag): w_.config(cursor='hand2')
    hover(bo_next, FAINT, TXT)
    hover(bo_live, GREEN, '#9fe0a0')
    st['actions'][bo_x] = bo_close
    st['actions'][bo_snd] = lambda: bo_voice_set(not bo['voice'])
    st['actions'][bo_open] = bo_reopen

    def live_start(in_game=True, report=None):
        """The Go Live button. Runs off the main thread so the overlay keeps drawing while it works."""
        if st.get('live_busy'): return
        if in_game:
            # pause and chat are key presses into the game, and Windows throws those away when the
            # game runs as admin and Wingman does not: same fix as the party invite
            try: blocked = game_needs_admin()
            except Exception as e: log('admin check: %r' % (e,)); blocked = None
            if blocked:
                log('go live: the game is elevated, so the keys would be blocked')
                go_admin('live')       # Windows asks; say yes and it starts again and carries on
                return
        st['live_busy'] = True
        try: live_btn.busy()                    # the spinner straight away
        except Exception: pass
        def show(text, col=LIVE_RED, solid=True, ink='white'):
            try: root.after(0, lambda: live_btn.set(text, col, solid, ink))
            except Exception: pass
        def work():
            ok, why = False, ''
            try:
                go_live(load_settings(), in_game=in_game, timer=tcw.timer_stopped,
                        status=lambda t: root.after(0, live_btn.busy))
                ok = True
            except LiveFail as e:
                why = str(e)
            except Exception as e:
                why = 'something went wrong: %r' % (e,)
                try:
                    import traceback; log('go live trace: %s' % traceback.format_exc().strip().replace('\n', ' | ')[-900:])
                except Exception: pass
            finally:
                st['live_busy'] = False
            log('go live: %s' % ('done' if ok else 'stopped, ' + why))
            if ok: show('LIVE')                                 # solid: you are live
            else:
                show('FAIL', LIVE_OFF)
                try: root.after(0, lambda: host_msg.config(text='Go Live: ' + why))
                except Exception: pass
            try: root.after(8000, lambda: live_btn.set('GO LIVE', LIVE_RED, False))
            except Exception: pass
            if report:
                try: root.after(0, lambda: report(ok, why))
                except Exception: pass
        threading.Thread(target=work, daemon=True).start()
    st['live_start'] = live_start
    st['actions'][live_btn] = lambda: live_start(not waiting_now[0])   # at the menu: Discord only
    def cap_hot(on):
        bo_cap.config(fg=GOLDD if on else GOLDC, highlightbackground=GOLDC if on else RIM,
                      bg=PANEL if on else INK)
    for w_ in (bo_cap, bo_goal, bo_caprow):
        w_.bind('<Enter>', lambda e: cap_hot(True), add='+'); w_.bind('<Leave>', lambda e: cap_hot(False), add='+')
    hover(bo_now, GOLDD, 'white')

    for cx, cy, ax, ay in ((0, 0, 1, 1), (1, 0, -1, 1), (0, 1, 1, -1), (1, 1, -1, -1)):
        for w_, h_ in ((10, 2), (2, 10)):      # the little L pieces in each corner of the panel
            piece = tk.Frame(root, bg=BRONZE, width=w_, height=h_)   # on root, inside the bronze ring
            piece.place(relx=cx, rely=cy, x=6 if ax > 0 else -6, y=6 if ay > 0 else -6,
                        anchor=('nw' if ax > 0 else 'ne') if ay > 0 else ('sw' if ax > 0 else 'se'))
            piece.lift(); bind_all(piece)
    st['actions'][close] = root.destroy

    def foot_fit():
        """The row under the header is only there while the party invite has something to say."""
        want = bool(host_msg.cget('text').strip()) and st.get('footer', True) and not st.get('rolled')
        if want != bool(host_row.winfo_manager()):
            if want: host_row.grid()
            else: host_row.grid_remove()

    def show_footer(on):
        calm(_show_footer)(on)
    def _show_footer(on):
        """The party invite button only makes sense at the menu. Out of a game it is there, in the
        header; in a game the state tag takes its place, so there is nothing to fat finger while you play."""
        st['footer'] = on
        if on: state.grid_remove(); btn_plate.grid()
        else: btn_plate.grid_remove()             # nothing in its place: no 'IN GAME' tag
        foot_fit()
        if st.get('rolled'): return
        if on and not waiting_now[0]: footsep.grid()              # no divider while idle
        else: footsep.grid_remove()

    def toggle_roll():
        """Click the name to roll the overlay up to just its header, and again to open it."""
        up = not st.get('rolled')
        for w in (sep, body, bo_box, rec_line, card, score_line, opp_area, footsep):
            if up: w.grid_remove()
            elif w is bo_box:
                if bo['name']: w.grid()
            elif w is score_line:
                if score_line.cget('text'): w.grid()
            elif w is opp_area:
                if opp_area.winfo_children(): w.grid()
            elif w is footsep and not st.get('footer', True): continue
            elif w in (footsep, sep) and waiting_now[0]: continue    # no dividers while idle
            elif w is body and not body.cget('text'): continue      # nothing to show while waiting
            elif w is card: 
                if st.get('card'): w.grid()
            elif w is not rec_line or rec_line.cget('text'): w.grid()
        st['rolled'] = up
        foot_fit()

    def title_click():
        """In a game the map name reads out the map's description. Out of a game, where there is
        nothing to describe, it still rolls the overlay up as it always did."""
        if st.get('last') is not None and body.has_prose():
            body.tell_me_about_the_map(); foot_fit(); return
        toggle_roll()
    st['actions'][title] = title_click

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

    def open_cheats():
        """The Godmode panel: buttons for the game's own cheat codes."""
        if st.get('cheat_win') is not None:
            try: bring_up(st['cheat_win']); return
            except tk.TclError: st['cheat_win'] = None
        win = tk.Toplevel(root); st['cheat_win'] = win
        win.withdraw()
        win.title('Godmode'); win.configure(bg=BORDER); win.attributes('-topmost', True)
        win.resizable(False, False)
        win.protocol('WM_DELETE_WINDOW', lambda: (st.update(cheat_win=None), win.destroy()))
        box = tk.Frame(win, bg=INK, padx=16, pady=12); box.pack(fill='both', expand=True, padx=1, pady=1)
        tk.Label(box, text='GODMODE', fg=REDC, bg=INK, font=(DISPLAY, 13, 'bold'), anchor='w').pack(fill='x')
        tk.Label(box, text='The game\'s own cheat codes. Single player, or a lobby with cheats on. '
                           'Ranked turns cheats off, so none of these work there.',
                 fg=MUT, bg=INK, font=F_SMALL, anchor='w', justify='left', wraplength=340).pack(fill='x', pady=(2, 8))
        out = tk.Label(box, text='', fg=GREEN, bg=INK, font=F_SMALL, anchor='w')
        def fire(code):
            out.config(text='Sending...', fg=MUT)
            def work():
                r = send_cheat(code)
                try: win.after(0, lambda: out.config(text=r, fg=GREEN if r.startswith('Sent') else REDC))
                except Exception: pass
            threading.Thread(target=work, daemon=True).start()
        for group, items in CHEATS:
            tk.Label(box, text=group.upper(), fg=BRONZE, bg=INK, font=F_TINY, anchor='w').pack(fill='x', pady=(8, 3))
            row = tk.Frame(box, bg=INK); row.pack(fill='x')
            for i, (label, code) in enumerate(items):
                b = flat_button(row, label, lambda c=code: fire(c))
                b.configure(padx=8, pady=3, font=F_SMALL, width=22)
                b.grid(row=i // 2, column=i % 2, sticky='we', padx=(0, 6), pady=2)
            row.columnconfigure(0, weight=1); row.columnconfigure(1, weight=1)
        out.pack(fill='x', pady=(10, 0))
        fade_in(win)

    def fade_in(w_, to=1.0, then=None, **_):
        """Show a window that is already built, at once and in one piece: it goes on screen fully
        see-through, every part of it is drawn while nobody can see it (a few hundredths of a
        second), then it is made solid in one step. `then` runs once it is showing."""
        try: w_.attributes('-alpha', 0.0)
        except tk.TclError: pass
        try:
            w_.deiconify(); w_.update()
        except tk.TclError:
            return
        def up():
            try:
                w_.update_idletasks(); w_.attributes('-alpha', to)
            except tk.TclError: pass
            if then:
                try: then()
                except Exception: pass
        w_.after(10, up)

    _SPIN = {}
    def spinner_frames(S, bg_):
        """A smooth loading ring: a faint track and a gold arc with a fading tail, drawn large and
        shrunk so it is clean at any size. 24 frames, made once."""
        key = (S, bg_)
        if key in _SPIN: return _SPIN[key]
        out = []
        try:
            from PIL import Image, ImageDraw, ImageTk
            k = 6; N = S * k; w = max(2, int(S * 0.13)) * k; pad = w / 2 + k
            box = (pad, pad, N - pad, N - pad)
            def mix(a, b, t):
                a = [int(a[i:i + 2], 16) for i in (1, 3, 5)]; b = [int(b[i:i + 2], 16) for i in (1, 3, 5)]
                return '#%02x%02x%02x' % tuple(int(a[j] + (b[j] - a[j]) * t) for j in range(3))
            track = mix(bg_, BRONZE, 0.22)
            for f in range(24):
                im = Image.new('RGB', (N, N), bg_)
                d = ImageDraw.Draw(im)
                d.ellipse(box, outline=track, width=w)
                head = f * 15
                for n_ in range(40):                       # the tail fades out behind the head
                    t = n_ / 39.0
                    a0 = head - 200 + n_ * 5
                    d.arc(box, a0, a0 + 6, fill=mix(track, GOLDC, t ** 1.6), width=w)
                r_ = w / 2.0                               # a round cap on the leading end
                import math
                cx, cy, R = N / 2.0, N / 2.0, (N - 2 * pad) / 2.0 - w / 2.0   # PIL draws the stroke inside the box
                ang = math.radians(head)
                hx, hy = cx + R * math.cos(ang), cy + R * math.sin(ang)
                d.ellipse((hx - r_, hy - r_, hx + r_, hy + r_), fill=GOLDC)
                out.append(ImageTk.PhotoImage(im.resize((S, S), Image.LANCZOS)))
        except Exception:
            out = []
        _SPIN[key] = out
        return out
    def spinner(parent, S, bg_):
        """A label that turns through the ring's frames until it is destroyed."""
        fr = spinner_frames(S, bg_)
        if not fr:
            c_ = tk.Canvas(parent, width=S, height=S, bg=bg_, highlightthickness=0)
            arc = c_.create_arc(2, 2, S - 2, S - 2, start=0, extent=270, style='arc', outline=GOLDC, width=2)
            st_ = {'a': 0}
            def turn():
                try:
                    st_['a'] = (st_['a'] - 30) % 360; c_.itemconfigure(arc, start=st_['a']); c_.after(50, turn)
                except tk.TclError: pass
            turn(); return c_
        l_ = tk.Label(parent, image=fr[0], bg=bg_, bd=0)
        st_ = {'i': 0}
        def turn():
            try:
                st_['i'] = (st_['i'] + 1) % len(fr); l_.config(image=fr[st_['i']]); l_.after(40, turn)
            except tk.TclError: pass
        l_.after(40, turn)
        return l_

    def settings_shell(geo=None):
        """The Settings window's frame, on screen the moment the gear is pressed: its own title,
        border and heading, with a spinner where the cards will be. Settings itself replaces it
        as soon as it is drawn, in the same place and at the same size."""
        w_ = tk.Toplevel(root)
        w_.title(APP_NAME + ' settings'); w_.configure(bg=BORDER); w_.attributes('-topmost', True)
        w_.resizable(False, False)
        geo = geo or st.get('settings_geo')
        if not geo:
            gw, gh = min(1500, w_.winfo_screenwidth() - 80), min(900, w_.winfo_screenheight() - 120)
            geo = (gw, gh, (w_.winfo_screenwidth() - gw) // 2, max(0, (w_.winfo_screenheight() - gh) // 2 - 24))
        w_.geometry('%dx%d+%d+%d' % geo)
        DEEP_ = '#0f0c07'
        sh_ = tk.Frame(w_, bg=DEEP_); sh_.pack(fill='both', expand=True, padx=1, pady=1)
        hd_ = tk.Frame(sh_, bg=DEEP_, padx=16); hd_.pack(fill='x', pady=(12, 0))
        try:
            im_ = tk.PhotoImage(data=APP_ICON_PNG[1]); l_ = tk.Label(hd_, image=im_, bg=DEEP_); l_.image = im_
            l_.pack(side='left', padx=(0, 10))
        except Exception: pass
        tk.Label(hd_, text='Settings', fg=GOLD, bg=DEEP_, font=F_HEADLINE).pack(side='left')
        mid_ = tk.Frame(sh_, bg=DEEP_); mid_.place(relx=0.5, rely=0.45, anchor='center')
        spinner(mid_, 40, DEEP_).pack()
        tk.Label(mid_, text='Loading settings', fg=MUT, bg=DEEP_, font=F_SMALL).pack(pady=(10, 0))
        try: w_.update()
        except tk.TclError: pass
        return w_

    def bring_up(w_):
        """Put one of our windows in front and give it the keyboard. The overlay never takes focus
        (so the game keeps its sound), which means Windows will not let a new window jump in front
        unless we ask the way the game switch does."""
        try:
            if not w_.winfo_ismapped(): w_.deiconify()
            w_.lift()
            import ctypes
            h_ = ctypes.windll.user32.GetAncestor(w_.winfo_id(), 2)
            threading.Thread(target=lambda: focus_window(h_), daemon=True).start()
        except Exception as e:
            log('bring window up: %r' % (e,))

    def reveal_settings(w_):
        """Put a built Settings window on screen, in the middle, ready to use."""
        w_.update_idletasks()
        geo = (w_.winfo_reqwidth(), w_.winfo_reqheight(),
               max(0, (w_.winfo_screenwidth() - w_.winfo_reqwidth()) // 2),
               max(0, (w_.winfo_screenheight() - w_.winfo_reqheight()) // 2 - 24))
        st['settings_geo'] = geo                       # the loading frame opens at this size next time
        w_.geometry('+%d+%d' % geo[2:])
        shell_ = st.pop('settings_shell', None)
        def swap():
            try: w_.lift()
            except tk.TclError: pass
            if shell_ is not None and hasattr(shell_, 'destroy'):
                try: shell_.destroy()
                except tk.TclError: pass
            try: w_.focus_force()
            except tk.TclError: pass
            w_.after(40, lambda: bring_up(w_))
        fade_in(w_, then=swap)                         # drawn unseen, then solid over the loading frame

    def drop_settings(key):
        w_ = st.pop(key, None)
        if w_ is not None and hasattr(w_, 'destroy'):
            try: w_.destroy()
            except tk.TclError: pass

    def prebuild_settings():
        """Build Settings ahead of time, out of sight, so the gear opens it straight away. Only at
        the menu (building it is a lot of work for a moment, and a game should not stutter for it),
        and again when the hidden one is ten minutes old, so what it shows is never stale."""
        if st.get('settings_win') is not None: return
        if not waiting_now[0]:
            root.after(20000, prebuild_settings); return
        pre = st.get('settings_pre')
        try:
            if pre is not None and pre.winfo_exists():
                if time.time() - st.get('settings_pre_t', 0) < 600: return
                drop_settings('settings_pre')                 # old: build a fresh one
        except tk.TclError: pass
        try:
            open_settings(show=False); st['settings_pre_t'] = time.time()
        except Exception as e:
            log('settings prebuild: %r' % (e,)); drop_settings('settings_pre')

    def open_settings(show=True):
        if show:
            pre = st.pop('settings_pre', None)                 # built earlier, out of sight: just show it
            try:
                if pre is not None and pre.winfo_exists() and getattr(pre, 'built_ok', False):
                    st['settings_win'] = pre; reveal_settings(pre); return
            except tk.TclError: pass
        if st.get('settings_win') is not None:
            try:
                if st['settings_win'].winfo_exists(): bring_up(st['settings_win']); return
            except tk.TclError: pass
            st['settings_win'] = None
        cfg = load_settings()
        st_set = {}
        win = tk.Toplevel(root)
        if show: st['settings_win'] = win
        else: st['settings_pre'] = win
        win.withdraw()                         # built out of sight, then shown once in one piece
        win.title(APP_NAME + ' settings'); win.configure(bg=BORDER); win.attributes('-topmost', True)
        win.resizable(False, False)

        # The sections scroll (mouse wheel or the bar) so the window always fits the screen,
        # and the Save row is pinned underneath where it can always be reached.
        # The page is a shade darker than the cards on it, so each part of Settings sits in its
        # own panel. Everything after a section() call lands in that section's card.
        DEEP = '#0f0c07'
        shell_ = tk.Frame(win, bg=DEEP); shell_.pack(fill='both', expand=True, padx=1, pady=1)
        foot = tk.Frame(shell_, bg=DEEP, padx=18); foot.pack(side='bottom', fill='x', pady=(10, 14))
        topf = tk.Frame(shell_, bg=DEEP, padx=16); topf.pack(side='top', fill='x', pady=(12, 0))   # title and jump bar stay put
        nav = tk.Frame(topf, bg=DEEP)
        cards_ = {}
        bar_ = slim_scrollbar(shell_, bg=DEEP)
        board_ = tk.Canvas(shell_, bg=DEEP, highlightthickness=0, bd=0, yscrollcommand=bar_.set)
        bar_.config(command=board_.yview)
        board_.pack(side='left', fill='both', expand=True)
        page = tk.Frame(board_, bg=DEEP, padx=16, pady=8)
        board_.create_window((0, 0), window=page, anchor='nw')
        outer = page
        def fit_(_=None):
            room = win.winfo_screenheight() - 200               # leave space for the title, the Save row and the taskbar
            board_.configure(scrollregion=board_.bbox('all'), width=page.winfo_reqwidth(),
                             height=min(page.winfo_reqheight(), room))
            if page.winfo_reqheight() > room: bar_.pack(side='right', fill='y')
            else: bar_.pack_forget()
        # once it is on screen the window keeps its size; only what there is to scroll changes
        def page_moved(_e=None):
            if not win.winfo_ismapped(): fit_(); return
            # on screen the window keeps its size; if something grew past the bottom (more friends,
            # a long mods report), the scroll bar comes so it can still be reached
            board_.configure(scrollregion=board_.bbox('all'))
            if page.winfo_reqheight() > board_.winfo_height() + 2:
                if not bar_.winfo_manager(): bar_.pack(side='right', fill='y')
        page.bind('<Configure>', page_moved)
        # smooth scrolling: the wheel sets how far to go, and the page glides there a few pixels a
        # frame instead of jumping a tenth of the page at a time
        board_.configure(yscrollincrement=1)
        glide = {'left': 0.0, 'job': None}
        def glide_step():
            left = glide['left']
            if abs(left) < 1:
                glide['left'], glide['job'] = 0.0, None; return
            d = int(left * 0.45) or (1 if left > 0 else -1)
            board_.yview_scroll(d, 'units'); glide['left'] -= d
            glide['job'] = win.after(16, glide_step)
        def wheel_(e):
            # only on a screen too small for the columns: one clean jump per notch, drawn in full
            # straight away (a glide leaves smeared copies of the lines behind on Windows)
            if page.winfo_reqheight() <= board_.winfo_height(): return
            board_.yview_scroll(int(-(e.delta / 120.0) * 90), 'units')
            board_.update_idletasks()
        win.bind('<MouseWheel>', wheel_)

        hd = tk.Frame(topf, bg=DEEP); hd.pack(fill='x')
        try:
            hd_img = tk.PhotoImage(data=APP_ICON_PNG[1])
            hl = tk.Label(hd, image=hd_img, bg=DEEP); hl.image = hd_img; hl.pack(side='left', padx=(0, 10))
        except Exception:
            pass
        tk.Label(hd, text='Settings', fg=GOLD, bg=DEEP, font=F_HEADLINE).pack(side='left')
        tk.Label(hd, text=VERSION, fg=MUT, bg=PANEL, font=F_TINY, padx=7, pady=2).pack(side='right')

        def section(label, note=None, gap=14):
            """A card with a gold heading; what follows goes in it. The notes stay in the code as a
            record of how each part works, but are not shown: Settings reads cleaner without them."""
            nonlocal outer
            card = tk.Frame(page, bg=INK, highlightthickness=1, highlightbackground=EDGE, padx=14, pady=9)
            card.pack(fill='x', pady=(8, 0))
            tk.Label(card, text=label, fg=GOLD, bg=INK, font=F_HEAD, anchor='w').pack(fill='x', pady=(0, 7))
            outer = card
            cards_[label] = card

        def field(label):
            """A small label for one part of a card."""
            tk.Label(outer, text=label, fg=MUT, bg=INK, font=F_SMALL, anchor='w').pack(fill='x', pady=(6, 2))

        section('Update', 'Wingman.exe updates itself from the public Releases page. The .bat '
                          'updates from GitHub: Prod is the settled version, dev gets changes first.', gap=10)
        card_ = tk.Frame(outer, bg=PANEL, highlightthickness=1, highlightbackground=RIM, padx=12, pady=9)
        card_.pack(fill='x', pady=(2, 0))
        row1 = tk.Frame(card_, bg=PANEL); row1.pack(fill='x')
        tk.Label(row1, text='YOU HAVE', fg=BRONZE, bg=PANEL, font=F_TINY).pack(side='left')
        tk.Label(row1, text='%s  \u00b7  %s' % (VERSION, 'Wingman.exe' if FROZEN else 'AoE2 Wingman.bat'),
                 fg=TXT, bg=PANEL, font=(DISPLAY, 10, 'bold')).pack(side='left', padx=(8, 0))
        newest = tk.Label(row1, text='', fg=MUT, bg=PANEL, font=F_SMALL)    # only says something when there is news
        newest.pack(side='right')
        up_row = tk.Frame(card_, bg=PANEL); up_row.pack(fill='x', pady=(8, 0))
        # how the update went, beside the buttons; empty until you press one
        up_msg = tk.Label(up_row, text='', fg='#b8b19f', bg=PANEL, font=F_SMALL,
                          anchor='e', justify='right', wraplength=190)
        def restart_into(path_):
            def swap():
                try:
                    if FROZEN:
                        start_fresh_exe(path_, '--wait-turn')
                    else:
                        restart_app(path_)
                except Exception as e:
                    log('restart failed: %r' % (e,))
                    try: up_msg.config(text='Updated, but could not restart: %s' % e, fg=REDC)
                    except tk.TclError: pass
                    return
                try: root.destroy()
                finally: os._exit(0)
            root.after(1200, swap)
        def run_update(branch):
            if st.get('updating'): return
            st['updating'] = True
            up_msg.config(text='Checking...', fg=MUT)
            def work():
                path_ = None
                try:
                    if branch == 'exe':
                        rel = latest_release(fresh=True)
                        if not rel or not rel.get('exe'):
                            ok_, text_ = False, 'Still building. Try again soon.'
                        elif ver_num(rel['ver']) <= ver_num(VERSION):
                            ok_, text_ = True, 'Up to date'
                        else:
                            path_ = update_exe(rel, lambda t: root.after(0, lambda: up_msg.config(text=t, fg=MUT)))
                            ok_, text_ = True, 'Updated to %s.' % rel['ver']
                    else:
                        ok_, text_, path_ = update_from_github(branch)
                except Exception as e:
                    log('update failed: %r' % (e,))
                    ok_, text_, path_ = False, 'Update failed. Try again in a bit.', None
                log('update from %s: %s' % (branch, text_))
                def done():
                    st['updating'] = False
                    try:
                        up_msg.config(text=text_ + (' Restarting...' if path_ else ''), fg=GREEN if ok_ else REDC)
                        if ok_ and not path_: newest.config(text='')
                    except tk.TclError: pass
                    if path_: restart_into(path_)
                root.after(0, done)
            threading.Thread(target=work, daemon=True).start()
        st['run_update'] = run_update
        # Same two buttons whichever way you run it. Every published version gets an exe build
        # too, so for the exe both come from the newest release; the .bat takes the branch.
        flat_button(up_row, 'Update', lambda: run_update('exe' if FROZEN else 'Prod'),
                    fill=True).pack(side='left')
        flat_button(up_row, 'Update to Beta', lambda: run_update('exe' if FROZEN else 'dev')
                    ).pack(side='left', padx=(8, 0))
        up_msg.pack(side='right', padx=(10, 0))
        def look_newest():
            rel = latest_release()
            def put():
                try:
                    if rel and ver_num(rel['ver']) > ver_num(VERSION):
                        newest.config(text='%s is out' % rel['ver'], fg=GOLDD)
                except tk.TclError: pass
            try: root.after(0, put)
            except Exception: pass
        threading.Thread(target=look_newest, daemon=True).start()

        # share it: one link that lets your mates pick the exe or the .bat
        share_ = tk.Frame(outer, bg=INK); share_.pack(fill='x', pady=(8, 0))
        share_msg = tk.Label(share_, text='',
                             fg=MUT, bg=INK, font=F_SMALL, anchor='w', justify='left', wraplength=250)
        def copy_link():
            try:
                win.clipboard_clear(); win.clipboard_append(DOWNLOAD_PAGE)
                share_msg.config(text='Link copied. Opening the page...', fg=GREEN)
            except Exception as e:
                share_msg.config(text='Could not copy it: %s' % e, fg=REDC)
            try:                                  # then open it, so you can see what they will see
                import webbrowser; webbrowser.open(DOWNLOAD_PAGE)
            except Exception as e:
                log('open download page: %r' % (e,))
        flat_button(share_, 'Share with mates', copy_link).pack(side='left')
        share_msg.pack(side='left', padx=(10, 0), fill='x')

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

        # Ash's position on the one question everyone asks. Near the top of Settings on purpose.
        outer = page
        fair = tk.Frame(outer, bg=PANEL, highlightthickness=1, highlightbackground=RIM,
                        padx=12, pady=10)
        fair.pack(fill='x', pady=(8, 0))
        fh = tk.Frame(fair, bg=PANEL); fh.pack(fill='x')
        fc = tk.Canvas(fh, width=15, height=15, bg=PANEL, highlightthickness=0)
        draw_icon(fc, 'shield', 15, GOLD); fc.pack(side='left', padx=(0, 7))
        tk.Label(fh, text='IS THIS CHEATING?', fg=GOLD, bg=PANEL,
                 font=(DISPLAY, 9, 'bold')).pack(side='left')
        for body_, col_ in (
            ('No. I absolutely do not like cheating. This app never exposes you to information '
             'you do not have, and it will never do things like moving units or performing a '
             'game based action.', TXT),
            ('The grey area: the overlay reads information from visible logs, such as SHEEP FOUND, '
             'and makes it more presentable. That is not reading hidden information, so it is not '
             'viewed as breaching the rules, though I understand some may be concerned. The rules '
             'here are going to be clarified with the dev team.', '#cfc8b6'),
            ('Rest assured: this app will never expose new information to the player. It does not '
             'give you anything you do not already have, and it does not move units.', GOLDD)):
            tk.Label(fair, text=body_, fg=col_, bg=PANEL, font=F_SMALL, anchor='w',
                     justify='left', wraplength=404).pack(fill='x', pady=(7, 0))

        section('Discord')
        field('Channel name')
        ch = tk.Entry(outer, width=46); style_entry(ch)
        ch.insert(0, cfg.get('channel', 'wesley')); ch.pack(fill='x', ipady=3)

        field('Webhook link for that channel')
        wh = tk.Entry(outer, width=46, show='\u2022'); style_entry(wh)
        wh.insert(0, cfg.get('webhook', '')); wh.pack(fill='x', ipady=3)
        wh_btns = tk.Frame(outer, bg=INK); wh_btns.pack(fill='x', pady=(8, 0))   # its test button goes here

        section('Ranked party')
        field('Friends to invite, and their Discord if you want them tagged')
        friends = [f for f in cfg.get('friends', []) if f.strip()]
        fdisc = {k.lower(): v for k, v in (cfg.get('friend_discord') or {}).items() if str(v).strip()}
        if not fdisc:                     # older settings had a separate tag list: carry over any that match
            for p_ in cfg.get('pings', []):
                nm_, uid_ = tag_parts(p_)
                for f_ in friends:
                    if f_.lower() == nm_.lower(): fdisc[f_.lower()] = uid_ or nm_
        fr_list = tk.Frame(outer, bg=INK); fr_list.pack(fill='x')
        fr_add = tk.Frame(outer, bg=INK); fr_add.pack(fill='x', pady=(6, 0))
        fr_add.columnconfigure(0, weight=3); fr_add.columnconfigure(1, weight=2)
        fr_msg = tk.Label(outer, text='', fg=GREEN, bg=INK, font=F_TINY, anchor='w')
        fr_msg.pack(fill='x')

        def friends_saved(note):
            merged = load_settings(); merged['friends'] = list(friends); merged['friend_discord'] = dict(fdisc)
            save_settings(merged)
            fr_msg.config(text=note, fg=GREEN)
            win.after(2000, lambda: fr_msg.cget('text') == note and fr_msg.config(text=''))

        def disc_text(v):
            v = str(v or '').strip()
            if not v: return ''
            if re.fullmatch(r'<?@?!?\d{15,21}>?', v): return 'Discord \u2026' + re.sub(r'\D', '', v)[-4:]
            return '@' + v.lstrip('@')

        def draw_friends():
            for w in fr_list.winfo_children(): w.destroy()
            if not friends:
                tk.Label(fr_list, text='Nobody yet. Add a name below.', fg=FAINT, bg=INK,
                         font=F_SMALL, anchor='w').pack(fill='x', pady=(2, 0))
                return
            for nm in list(friends):
                row = tk.Frame(fr_list, bg=PANEL, highlightthickness=1, highlightbackground=EDGE, cursor='hand2')
                row.pack(fill='x', pady=2)
                lab = tk.Label(row, text=nm, fg=TXT, bg=PANEL, font=F_BODY, anchor='w', padx=9, pady=4, cursor='hand2')
                lab.pack(side='left')
                x = tk.Label(row, text='\u2715', fg=MUT, bg=PANEL, font=F_SMALL, padx=10, pady=4,
                             cursor='hand2')
                x.pack(side='right')
                dl = tk.Label(row, text=disc_text(fdisc.get(nm.lower())) or 'no Discord tag', bg=PANEL,
                              fg=MUT if fdisc.get(nm.lower()) else FAINT, font=F_TINY, padx=4, cursor='hand2')
                dl.pack(side='right')
                hover(x, MUT, REDC)
                def drop(_e=None, who=nm):
                    if who in friends: friends.remove(who)
                    fdisc.pop(who.lower(), None)
                    draw_friends(); friends_saved('Removed %s.' % who)
                x.bind('<Button-1>', drop)
                def edit(_e=None, who=nm):          # click a friend to change their Discord
                    fr_entry.delete(0, 'end'); fr_entry.insert(0, who)
                    fd_entry.delete(0, 'end'); fd_entry.insert(0, fdisc.get(who.lower(), ''))
                    fd_entry.focus_set()
                for w_ in (row, lab, dl): w_.bind('<Button-1>', edit)

        tk.Label(fr_add, text='AoE2 name', fg=FAINT, bg=INK, font=F_TINY, anchor='w').grid(row=0, column=0, sticky='w')
        tk.Label(fr_add, text='Discord ID (optional)', fg=FAINT, bg=INK, font=F_TINY, anchor='w'
                 ).grid(row=0, column=1, sticky='w', padx=(8, 0))
        fr_entry = tk.Entry(fr_add, width=18); style_entry(fr_entry)
        fr_entry.grid(row=1, column=0, sticky='we', ipady=3)
        fd_entry = tk.Entry(fr_add, width=14); style_entry(fd_entry)
        fd_entry.grid(row=1, column=1, sticky='we', ipady=3, padx=(8, 0))
        def add_friend(_e=None):
            nm = fr_entry.get().strip(); dv = fd_entry.get().strip()
            if not nm: return
            known = next((f for f in friends if f.lower() == nm.lower()), None)
            if known:
                if dv: fdisc[known.lower()] = dv
                else: fdisc.pop(known.lower(), None)
                note = 'Updated %s.' % known
            else:
                friends.append(nm)
                if dv: fdisc[nm.lower()] = dv
                note = 'Added %s.' % nm
            fr_entry.delete(0, 'end'); fd_entry.delete(0, 'end')
            draw_friends(); friends_saved(note)
        fr_entry.bind('<Return>', add_friend); fd_entry.bind('<Return>', add_friend)
        ab_ = flat_button(fr_add, 'Add', add_friend); ab_.grid(row=1, column=2, padx=(8, 0))
        draw_friends()

        section('Go Live')
        lv_row = tk.Frame(outer, bg=INK); lv_row.pack(fill='x', pady=(2, 0))
        lv = {}
        for key_, label_ in (('live_pause_key', 'Pause keys'), ('live_before', 'Say first'),
                             ('live_after', 'Say after')):
            r_ = tk.Frame(lv_row, bg=INK); r_.pack(fill='x', pady=2)
            tk.Label(r_, text=label_, fg=TXT, bg=INK, font=F_SMALL, width=10, anchor='w').pack(side='left')
            e_ = tk.Entry(r_, width=30); style_entry(e_)
            v_ = str(cfg.get(key_) or LIVE_DEFAULTS[key_])
            if key_ == 'live_pause_key' and not combo_ok(v_): v_ = LIVE_DEFAULTS[key_]
            e_.insert(0, v_); e_.pack(side='left', fill='x', expand=True, ipady=2)
            lv[key_] = e_
        field("Voice channel link (joined if you're not in a call)")
        lv_chan = tk.Entry(outer, width=46); style_entry(lv_chan)
        lv_chan.insert(0, cfg.get('live_channel', '')); lv_chan.pack(fill='x', ipady=3)
        lv_hint = tk.Label(outer, text='', fg=FAINT, bg=INK, font=F_TINY, anchor='w',
                           justify='left', wraplength=400)
        lv_hint.pack(fill='x', pady=(3, 0))
        LV_HOW = ('Paste the channel link, like https://discord.com/channels/713962454140321834/713962454589112323\n'
                  'In Discord: right-click the voice channel, then Copy Link. Leave it empty to skip.')
        def lv_check(_e=None):
            t_ = lv_chan.get().strip()
            if not t_: lv_hint.config(text=LV_HOW, fg=FAINT)
            elif discord_channel_link(t_): lv_hint.config(text='\u2713 Channel link set. Wingman opens it when you Go Live.', fg=GREEN)
            else: lv_hint.config(text="That isn't a channel link yet. " + LV_HOW, fg=REDC)
        lv_chan.bind('<KeyRelease>', lv_check, add='+'); lv_chan.bind('<FocusOut>', lv_check, add='+')
        lv_chan.bind('<<Paste>>', lambda e: lv_chan.after(10, lv_check), add='+')
        lv_check()
        lv_msg = tk.Label(outer, text='', fg='#b8b19f', bg=INK, font=F_SMALL, anchor='w',
                          justify='left', wraplength=400)
        def lv_test():
            c_ = collect()
            if c_.get('live_channel') and not discord_channel_link(c_['live_channel']):
                lv_check(); lv_msg.config(text="The voice channel needs to be the channel's link first.", fg=REDC); return
            if st.get('live_busy'):
                lv_msg.config(text='Go Live is already running. Give it a moment.', fg=GOLDC); return
            merged = load_settings(); merged.update(c_); save_settings(merged)
            lv_msg.config(text='Trying the Discord part only, no pause or chat...', fg=MUT)
            st['live_start'](False, lambda ok, why: lv_msg.config(
                text=('Worked. You are live on Discord.' if ok else 'Did not work: ' + why),
                fg=GREEN if ok else REDC))
        lv_b = tk.Frame(outer, bg=INK); lv_b.pack(fill='x', pady=(6, 0))
        flat_button(lv_b, 'Test the Discord part', lv_test).pack(side='left')
        lv_msg.pack(fill='x', pady=(4, 0))

        section('Your build orders')
        cb_list = tk.Frame(outer, bg=INK); cb_list.pack(fill='x')
        cb_msg = tk.Label(outer, text='', fg=GREEN, bg=INK, font=F_TINY, anchor='w')

        def cb_saved_list():
            return [b for b in (load_settings().get('custom_builds') or []) if b.get('name')]

        def cb_store(lst, note):
            merged = load_settings(); merged['custom_builds'] = lst; save_settings(merged)
            custom_builds(fresh=True)
            cb_draw()
            cb_msg.config(text=note, fg=GREEN)
            win.after(2500, lambda: cb_msg.cget('text') == note and cb_msg.config(text=''))
            try: bo_draw()
            except Exception: pass

        def cb_draw():
            for w in cb_list.winfo_children(): w.destroy()
            mine_ = cb_saved_list()
            if not mine_:
                tk.Label(cb_list, text='None yet. Make one, or start from one of Hera\'s and change it.',
                         fg=FAINT, bg=INK, font=F_SMALL, anchor='w', justify='left', wraplength=420
                         ).pack(fill='x', pady=(0, 2))
            for b in mine_:
                row = tk.Frame(cb_list, bg=PANEL, highlightthickness=1, highlightbackground=EDGE, cursor='hand2')
                row.pack(fill='x', pady=2)
                lab = tk.Label(row, text=b['name'], fg=TXT, bg=PANEL, font=F_BODY, anchor='w', padx=9, pady=4,
                               cursor='hand2')
                lab.pack(side='left')
                x = tk.Label(row, text='✕', fg=MUT, bg=PANEL, font=F_SMALL, padx=10, pady=4, cursor='hand2')
                x.pack(side='right')
                hover(x, MUT, REDC)
                info = '%s  ·  %d steps' % ((b.get('goal') or '').strip() or 'your build', len(b.get('steps') or []))
                il = tk.Label(row, text=info, fg=MUT, bg=PANEL, font=F_TINY, padx=4, cursor='hand2')
                il.pack(side='right')
                def drop(_e=None, nm=b['name']):
                    cb_store([c for c in cb_saved_list() if c['name'] != nm], 'Deleted %s.' % nm)
                    if bo['name'] == nm: bo_pick(None)
                x.bind('<Button-1>', drop)
                for w_ in (row, lab, il): w_.bind('<Button-1>', lambda e, b_=b: cb_edit(b_))

        def cb_edit(b=None, start=None):
            """The build order editor: a name, what it aims for, and the steps by pop."""
            ed = tk.Toplevel(win); ed.title('Build order'); ed.configure(bg=BORDER)
            ed.attributes('-topmost', True); ed.resizable(False, False)
            body_ = tk.Frame(ed, bg=INK, padx=18, pady=14); body_.pack(fill='both', expand=True, padx=1, pady=1)
            old_name = b['name'] if b else None
            src = b or start
            tk.Label(body_, text='Edit build order' if b else 'New build order', fg=GOLDC, bg=INK,
                     font=F_HEAD, anchor='w').pack(fill='x')
            top_ = tk.Frame(body_, bg=INK); top_.pack(fill='x', pady=(10, 0))
            top_.columnconfigure(0, weight=3); top_.columnconfigure(1, weight=2)
            tk.Label(top_, text='Name', fg=FAINT, bg=INK, font=F_TINY, anchor='w').grid(row=0, column=0, sticky='w')
            tk.Label(top_, text='Aim (optional)', fg=FAINT, bg=INK, font=F_TINY, anchor='w'
                     ).grid(row=0, column=1, sticky='w', padx=(8, 0))
            nm_e = tk.Entry(top_, width=26); style_entry(nm_e); nm_e.grid(row=1, column=0, sticky='we', ipady=3)
            gl_e = tk.Entry(top_, width=16); style_entry(gl_e); gl_e.grid(row=1, column=1, sticky='we', ipady=3, padx=(8, 0))
            if src:
                nm_e.insert(0, src.get('name', '') if b else '%s (mine)' % src.get('name', ''))
                gl_e.insert(0, src.get('goal', ''))
            hd_ = tk.Frame(body_, bg=INK); hd_.pack(fill='x', pady=(12, 2))
            tk.Label(hd_, text='At pop', fg=FAINT, bg=INK, font=F_TINY, width=7, anchor='w').pack(side='left')
            tk.Label(hd_, text='What to do', fg=FAINT, bg=INK, font=F_TINY, anchor='w').pack(side='left', padx=(6, 0))
            rows_box = tk.Frame(body_, bg=INK); rows_box.pack(fill='x')
            rows_ = []
            def add_row(pop_='', text_=''):
                r = tk.Frame(rows_box, bg=INK); r.pack(fill='x', pady=2)
                pe = tk.Entry(r, width=5, justify='center'); style_entry(pe); pe.pack(side='left', ipady=2)
                te = tk.Entry(r, width=44); style_entry(te); te.pack(side='left', fill='x', expand=True, padx=(8, 0), ipady=2)
                xx = tk.Label(r, text='✕', fg=MUT, bg=INK, font=F_SMALL, padx=8, cursor='hand2'); xx.pack(side='left')
                hover(xx, MUT, REDC)
                pe.insert(0, str(pop_)); te.insert(0, text_)
                item = (r, pe, te)
                def rm(_e=None):
                    if item in rows_: rows_.remove(item)
                    r.destroy()
                xx.bind('<Button-1>', rm)
                rows_.append(item)
                return pe
            if src and src.get('steps'):
                for p_, t_ in src['steps']: add_row(p_, t_)
            else:
                add_row(2, '6 to sheep'); add_row(8, '')
            add_ = tk.Label(body_, text='+ Add a step', fg=GOLDC, bg=INK, font=F_SMALL, anchor='w', cursor='hand2')
            add_.pack(fill='x', pady=(6, 0)); hover(add_, GOLDC, GOLDD)
            def more(_e=None):
                last = 0
                for _r, pe, _t in rows_:
                    try: last = max(last, int(pe.get()))
                    except ValueError: pass
                add_row(last + 1 if last else '').focus_set()
            add_.bind('<Button-1>', more)
            tk.Label(body_, text='A step shows from its pop until the next step\'s pop. Pop counts your villagers '
                                 'and scout, like the counter in the game.', fg=FAINT, bg=INK, font=F_TINY,
                     anchor='w', justify='left', wraplength=460).pack(fill='x', pady=(8, 0))
            em = tk.Label(body_, text='', fg=REDC, bg=INK, font=F_SMALL, anchor='w', justify='left', wraplength=460)
            em.pack(fill='x', pady=(6, 0))
            bt = tk.Frame(body_, bg=INK); bt.pack(fill='x', pady=(10, 0))
            def save_ed():
                nm = nm_e.get().strip()
                if not nm: em.config(text='Give it a name.'); return
                if any(n_ == nm for _g, n_, _p, _s in BUILDS):
                    em.config(text="That's the name of one of Hera's builds. Pick another."); return
                others = [c for c in cb_saved_list() if c['name'] != old_name]
                if any(c['name'].lower() == nm.lower() for c in others):
                    em.config(text='You already have a build with that name.'); return
                steps_ = []
                for _r, pe, te in rows_:
                    pv, tv = pe.get().strip(), te.get().strip()
                    if not pv and not tv: continue
                    if not tv: em.config(text='A step at pop %s has nothing to do.' % pv); return
                    try: pi = int(pv)
                    except ValueError: em.config(text='"%s" needs a pop number.' % tv[:40]); return
                    if not 1 <= pi <= 200: em.config(text='Pop has to be between 1 and 200.'); return
                    steps_.append([pi, tv])
                if not steps_: em.config(text='Add at least one step.'); return
                steps_.sort(key=lambda x: x[0])
                entry = {'name': nm, 'goal': gl_e.get().strip(), 'steps': steps_}
                lst = cb_saved_list(); placed = False
                for k_, c in enumerate(lst):
                    if c['name'] == old_name: lst[k_] = entry; placed = True
                if not placed: lst.append(entry)
                cb_store(lst, 'Saved %s.' % nm)
                if old_name and bo['name'] == old_name: bo_pick(nm)
                ed.destroy()
            flat_button(bt, 'Save build order', save_ed, fill=True).pack(side='left')
            flat_button(bt, 'Cancel', ed.destroy, accent=MUT, hot='#cfc8b6').pack(side='right')
            ed.bind('<Escape>', lambda e: ed.destroy())
            ed.update_idletasks()
            ed.geometry('+%d+%d' % (win.winfo_rootx() + 30, max(0, win.winfo_rooty() + 60)))
            bring_up(ed)
            nm_e.focus_set()

        cb_btns = tk.Frame(outer, bg=INK); cb_btns.pack(fill='x', pady=(8, 0))
        flat_button(cb_btns, 'New build order', lambda: cb_edit()).pack(side='left')
        def from_hera():
            m_ = tk.Menu(win, tearoff=0, bg=INK, fg=TXT, activebackground=PANEL, activeforeground=GOLDD, bd=0)
            for _g, n_, pop_, steps_ in BUILDS:
                m_.add_command(label='%s  (%s)' % (n_, pop_), command=lambda n_=n_, p_=pop_, s_=steps_: cb_edit(
                    start={'name': n_, 'goal': p_, 'steps': [[lo, t_] for lo, _hi, t_ in s_]}))
            try: m_.tk_popup(win.winfo_pointerx(), win.winfo_pointery())
            finally: m_.grab_release()
        flat_button(cb_btns, "Start from one of Hera's", from_hera).pack(side='left', padx=(8, 0))
        cb_msg.pack(fill='x', pady=(4, 0))
        cb_draw()

        section('Alerts')
        tc_on = tk.BooleanVar(value=cfg.get('tc_alert', True))
        for var, txt in ((tc_on, 'Show the idle Town Center alert'),):
            Check(outer, text=txt, variable=var, fg=TXT, bg=INK, selectcolor=PANEL, activebackground=INK,
                           activeforeground=GOLDD, font=F_SMALL, anchor='w', highlightthickness=0).pack(fill='x')

        field('House warning: spare pop when it starts')
        bands = cfg.get('house_bands') or HOUSE_BANDS
        band_grid = tk.Frame(outer, bg=INK); band_grid.pack(fill='x', pady=(2, 0))
        band_e = []
        for col, (upto, spare) in enumerate(bands):
            cell = tk.Frame(band_grid, bg=INK); cell.grid(row=0, column=col, padx=(0, 10))
            tk.Label(cell, text=('to %d min' % upto) if upto < 999 else 'after that',
                     fg=MUT, bg=INK, font=F_TINY).pack()
            e = tk.Entry(cell, width=4, justify='center'); style_entry(e)
            e.insert(0, str(spare)); e.pack(ipady=2)
            band_e.append((upto, e))
        extra_grid = tk.Frame(outer, bg=INK); extra_grid.pack(fill='x', pady=(8, 0))
        tk.Label(extra_grid, text='Nothing before', fg=MUT, bg=INK, font=F_SMALL).pack(side='left')
        hg_e = tk.Entry(extra_grid, width=4, justify='center'); style_entry(hg_e)
        hg_e.insert(0, str(cfg.get('house_grace', HOUSE_GRACE_MIN))); hg_e.pack(side='left', padx=6, ipady=2)
        tk.Label(extra_grid, text='game minutes.      On a 20 pop cap, at most',
                 fg=MUT, bg=INK, font=F_SMALL).pack(side='left')
        h20_e = tk.Entry(extra_grid, width=4, justify='center'); style_entry(h20_e)
        h20_e.insert(0, str(cfg.get('house_cap20', HOUSE_CAP20))); h20_e.pack(side='left', padx=6, ipady=2)
        tk.Label(extra_grid, text='spare', fg=MUT, bg=INK, font=F_SMALL).pack(side='left')

        def house_cfg():
            """The warning rules as typed, falling back to what they were if a box is not a number."""
            out = []
            for i, (upto, e) in enumerate(band_e):
                try: out.append([upto, max(0, min(100, int(float(e.get().strip()))))])
                except ValueError: out.append([upto, bands[i][1]])
            try: grace = max(0.0, min(30.0, float(hg_e.get().strip())))
            except ValueError: grace = cfg.get('house_grace', HOUSE_GRACE_MIN)
            try: cap20 = max(0, min(20, int(float(h20_e.get().strip()))))
            except ValueError: cap20 = cfg.get('house_cap20', HOUSE_CAP20)
            return out, grace, cap20

        cp_on = tk.BooleanVar(value=cfg.get('civ_panel_loading', False))
        field('Reminders')
        cn_on = tk.BooleanVar(value=cfg.get('castle_note', True))
        fn_on = tk.BooleanVar(value=cfg.get('feudal_note', True))
        def reminder_row(var, before, value, after):
            """A tick box with a number you can change in the middle of its sentence."""
            line = tk.Frame(outer, bg=INK); line.pack(fill='x', pady=(2, 0))
            Check(line, text=before, variable=var, fg=TXT, bg=INK, selectcolor=PANEL, activebackground=INK,
                           activeforeground=GOLDD, font=F_SMALL, anchor='w', highlightthickness=0).pack(side='left')
            e = tk.Entry(line, width=4, justify='center'); style_entry(e)
            e.insert(0, value); e.pack(side='left', padx=6, ipady=1)
            tk.Label(line, text=after, fg=TXT, bg=INK, font=F_SMALL).pack(side='left')
            return e
        fp_e = reminder_row(fn_on, 'Remind me about my two Feudal Age buildings at',
                            '%d' % typed_number(cfg.get('feudal_pop'), FEUDAL_NOTE_POP, 5, 60), 'population')
        cm_e = reminder_row(cn_on, 'Remind me about my two Castle Age buildings at',
                            '%d' % typed_number(cfg.get('castle_food'), CASTLE_NOTE_FOOD, 100, 5000),
                            'food (from %d min)' % CASTLE_NOTE_MIN)

        field('Score and scouting')
        cf_on = tk.BooleanVar(value=cfg.get('concede_flag', True))
        Check(outer, text='Flag when a game looks gone (score check)', variable=cf_on, fg=TXT, bg=INK,
                       selectcolor=PANEL, activebackground=INK, activeforeground=GOLDD,
                       font=F_SMALL, anchor='w', highlightthickness=0).pack(fill='x')

        oo_on = tk.BooleanVar(value=cfg.get('opp_openings', True))
        Check(outer, text='Show how opponents usually open', variable=oo_on, fg=TXT, bg=INK,
                       selectcolor=PANEL, activebackground=INK, activeforeground=GOLDD,
                       font=F_SMALL, anchor='w', highlightthickness=0).pack(fill='x')

        field('Opponent spotted')
        sc_on = tk.BooleanVar(value=cfg.get('scout_callout', False))
        sp_on = tk.BooleanVar(value=cfg.get('scout_ping', True))
        for var, txt in ((sc_on, "Call out opponents ('Red found')"),
                         (sp_on, 'Ring the spot on the minimap as well')):
            Check(outer, text=txt, variable=var, fg=TXT, bg=INK,
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

        section('Display')
        ss_on = tk.BooleanVar(value=bool(cfg.get('show_in_shots', False)))
        def ss_apply(*_):
            on = bool(ss_on.get())
            try:
                import ctypes
                ctypes.windll.user32.SetWindowDisplayAffinity(ctypes.c_void_p(OVERLAY_TOP[0]), 0 if on else 0x11)
            except Exception as e:
                log('show in screenshots: %r' % (e,))
            c_ = load_settings(); c_['show_in_shots'] = on; save_settings(c_)      # takes effect straight away
        ss_on.trace_add('write', ss_apply)
        Check(outer, text='Show Wingman in screenshots and streams', variable=ss_on).pack(fill='x')

        Check(outer, text="Show your opponent's civ while the game loads", variable=cp_on).pack(fill='x')

        fg_on = tk.BooleanVar(value=cfg.get('focus_game', True))
        Check(outer, text='Bring the game to the front when it starts', variable=fg_on, fg=TXT, bg=INK,
                       selectcolor=PANEL, activebackground=INK, activeforeground=GOLDD,
                       font=F_SMALL, anchor='w', highlightthickness=0).pack(fill='x')
        cr_on = tk.BooleanVar(value=cfg.get('companion_results', True))
        Check(outer, text='Fill in older results from aoe2companion.com', variable=cr_on, fg=TXT, bg=INK,
                       selectcolor=PANEL, activebackground=INK, activeforeground=GOLDD,
                       font=F_SMALL, anchor='w', highlightthickness=0).pack(fill='x')

        # the build order's voice: pick any voice Windows has, and hear it straight away
        vo_row = tk.Frame(outer, bg=INK); vo_row.pack(fill='x', pady=(10, 0))
        vo_lab = tk.Label(vo_row, text='Build order voice: %s' % (cfg.get('voice_name') or 'automatic'),
                          fg=MUT, bg=INK, font=F_SMALL, anchor='w')
        vo_lab.pack(side='left')
        def vo_pick():
            vo_lab.config(text='Build order voice: looking...')
            def work():
                got = VOICE.voices()
                def show():
                    try:
                        vo_lab.config(text='Build order voice: %s' % (load_settings().get('voice_name') or 'automatic'))
                        if not got:
                            vo_lab.config(text="Build order voice: couldn't list the voices on this PC"); return
                        eng = sorted([g for g in got if g[1].lower().startswith('en')], key=lambda g: (g[1] != 'en-AU', g[0]))
                        rest = sorted([g for g in got if g not in eng])
                        m_ = tk.Menu(win, tearoff=0, bg=INK, fg=TXT, activebackground=PANEL, activeforeground=GOLDD, bd=0)
                        def choose(nm):
                            c_ = load_settings(); c_['voice_name'] = nm; save_settings(c_)
                            VOICE.set_voice(nm); VOICE.say('This is your build order voice')
                            vo_lab.config(text='Build order voice: %s' % (nm or 'automatic'))
                        m_.add_command(label='Automatic (an Australian voice if there is one)', command=lambda: choose(''))
                        for nm, lang in eng + rest:
                            m_.add_command(label='%s  (%s)' % (nm, lang), command=lambda n_=nm: choose(n_))
                        m_.tk_popup(win.winfo_pointerx(), win.winfo_pointery())
                        m_.grab_release()
                    except tk.TclError: pass
                try: win.after(0, show)
                except Exception: pass
            threading.Thread(target=work, daemon=True).start()
        flat_button(vo_row, 'Change voice', vo_pick).pack(side='right')

        # the recorded games pile up; moving the old ones aside keeps the game's list and Wingman quick
        rc_row = tk.Frame(outer, bg=INK); rc_row.pack(fill='x', pady=(10, 0))
        rc_lab = tk.Label(rc_row, text='Recorded games: counting...', fg=MUT, bg=INK, font=F_SMALL, anchor='w')
        rc_lab.pack(side='left')
        def rc_count():
            n_all, n_old = recordings_count(TIDY_DAYS)
            def put():
                try:
                    rc_lab.config(text='Recorded games: %d, %d older than 3 months' % (n_all, n_old))
                    if n_old and not rc_btn.winfo_manager(): rc_btn.pack(side='right')
                    elif not n_old: rc_btn.pack_forget()
                except tk.TclError: pass
            try: root.after(0, put)
            except Exception: pass
        def rc_tidy():
            rc_lab.config(text='Moving...', fg=MUT)
            def work():
                n_ = tidy_recordings(TIDY_DAYS)
                def put():
                    try:
                        rc_btn.pack_forget()
                        rc_lab.config(text='Moved %d into "Older recordings" in your savegame folder.' % n_, fg=GREEN)
                    except tk.TclError: pass
                root.after(0, put)
            threading.Thread(target=work, daemon=True).start()
        rc_btn = flat_button(rc_row, 'Move the old ones', rc_tidy)
        threading.Thread(target=rc_count, daemon=True).start()

        section('Godmode')
        gm_row = tk.Frame(outer, bg=INK); gm_row.pack(fill='x', pady=(2, 0))
        gm_msg = tk.Label(outer, text='', fg='#b8b19f', bg=INK, font=F_SMALL, anchor='w')
        def gm_open_btn():
            for w_ in gm_row.winfo_children(): w_.destroy()
            flat_button(gm_row, 'Open Godmode', open_cheats, fill=True).pack(side='left')
            def lock():
                c_ = load_settings(); c_['godmode'] = False; save_settings(c_); gm_lock_box()
                cw_ = st.pop('cheat_win', None)              # and the open panel goes too
                if cw_ is not None:
                    try: cw_.destroy()
                    except tk.TclError: pass
            flat_button(gm_row, 'Lock it again', lock).pack(side='left', padx=(8, 0))
        def gm_lock_box():
            for w_ in gm_row.winfo_children(): w_.destroy()
            e_ = tk.Entry(gm_row, width=18, show='\u2022'); style_entry(e_); e_.pack(side='left', ipady=2)
            def unlock(_=None):
                if e_.get().strip() == GODMODE_WORD:
                    c_ = load_settings(); c_['godmode'] = True; save_settings(c_)
                    gm_msg.config(text='Unlocked.', fg=GREEN); gm_open_btn()
                else:
                    gm_msg.config(text='Not the password.', fg=REDC); e_.delete(0, 'end')
            e_.bind('<Return>', unlock)
            flat_button(gm_row, 'Unlock', unlock).pack(side='left', padx=(8, 0))
        if cfg.get('godmode'): gm_open_btn()
        else: gm_lock_box()
        gm_msg.pack(fill='x', pady=(4, 0))

        section('Running as administrator',
                'Only matters for the party invite. If the game runs as admin, Windows ignores clicks from '
                'programs that don\'t, so Wingman has to restart as admin to click it. Better still, stop the '
                'game needing admin and neither of them will.')
        ad_on = tk.BooleanVar(value=cfg.get('admin_auto', False))
        Check(outer, text='When the game needs it, restart Wingman as admin without asking first',
                       variable=ad_on, fg=TXT, bg=INK, selectcolor=PANEL, activebackground=INK,
                       activeforeground=GOLDD, font=F_SMALL, anchor='w', highlightthickness=0).pack(fill='x')
        ad_row = tk.Frame(outer, bg=INK); ad_row.pack(fill='x', pady=(6, 0))
        ad_msg = tk.Label(outer, text='', fg='#b8b19f', bg=INK, font=F_SMALL, anchor='w',
                          justify='left', wraplength=400)
        ad_msg.pack(fill='x', pady=(6, 0))
        def admin_state():
            me_ = 'Wingman is running as admin.' if overlay_is_admin() else 'Wingman is running normally.'
            try: flags = admin_flags()
            except Exception: flags = []
            if not flags: return me_ + ' Nothing is set to make the game or Steam run as admin.', GREEN
            names = sorted({os.path.basename(n) for _, n, _ in flags})
            return me_ + ' Set to always run as admin: %s.' % ', '.join(names), GOLDC
        def ad_refresh():
            t_, c_ = admin_state(); ad_msg.config(text=t_, fg=c_)
        def ad_fix():
            try: cleared, left = clear_admin_flags()
            except Exception as e: cleared, left = [], ['?']; log('fix admin: %r' % (e,))
            ad_refresh()
            if left:
                ad_msg.config(text=ad_msg.cget('text') + ' Some are set for every user on this PC: untick '
                              '"Run this program as an administrator" under Properties > Compatibility > '
                              'Change settings for all users.', fg=GOLDC)
            elif cleared:
                ad_msg.config(text='Done. Close Steam fully and open it again, then start the game.', fg=GREEN)
        flat_button(ad_row, 'Stop the game needing admin', ad_fix).pack(side='left')
        win.after(50, ad_refresh)                        # after the window is up, so it opens straight away

        # God Mode: the UI mod this app is built around (it pins the resource bar and the Global
        # Queue, which the idle Town Center alert reads). The button opens its official mod page.
        section('Mods'); field('God Mode mod')
        mods_row = tk.Frame(outer, bg=INK); mods_row.pack(fill='x', pady=(2, 0))
        gm_state, gm_text = god_mode_status()
        flat_button(mods_row, 'Install God Mode' if gm_state == 'missing' else 'Open its mod page',
                    open_god_mode_page, fill=gm_state == 'missing').pack(side='left')
        tk.Label(mods_row, text=gm_text, fg=GREEN if gm_state == 'on' else GOLDC if gm_state == 'off' else REDC,
                 bg=INK, font=F_SMALL, anchor='w').pack(side='left', padx=(10, 0))

        # Mod clashes: two enabled mods shipping the same file means only one does anything; this
        # says which one wins. GodMode merges others in on purpose, so it is expected to win.
        field('Do your mods clash?')
        clash_row = tk.Frame(outer, bg=INK); clash_row.pack(fill='x', pady=(2, 0))
        clash_out = tk.Label(outer, text='', fg='#b8b19f', bg=INK, font=F_SMALL, anchor='w',
                             justify='left', wraplength=430)
        clash_out.pack(fill='x', pady=(6, 0))

        def run_clash_check():
            clash_out.config(text='Checking...', fg=MUT)
            def work():
                try:
                    rows = mod_clashes()
                except Exception as e:
                    log('mod check: %r' % (e,))
                    txt, col = "Couldn't read your mods folder. Try again with the game closed.", REDC
                else:
                    if not rows:
                        txt, col = "All good. None of your mods get in each other's way.", GREEN
                    else:
                        nice = lambda m_: re.sub(r'(?<=[a-z])(?=[A-Z])', ' ', str(m_)).replace('_', ' ').strip()
                        lines = ['%d of your mods overlap, so only one version of some files shows:'
                                 % len({x for r_ in rows for x in r_[:2]})]
                        for w, l, n, _ex in rows[:6]:
                            ok_ = 'godmode' in _norm(w)
                            lines.append('\u2022  %s wins over %s (%d file%s).%s'
                                         % (nice(w), nice(l), n, '' if n == 1 else 's',
                                            " That's expected: God Mode includes it." if ok_ else ''))
                        if len(rows) > 6: lines.append('\u2022  and %d more.' % (len(rows) - 6))
                        if not all('godmode' in _norm(r_[0]) for r_ in rows):
                            lines.append("To pick which one shows, change the order in the game's Mods screen.")
                        txt, col = '\n'.join(lines), GOLDC
                try: win.after(0, lambda: clash_out.config(text=txt, fg=col))
                except Exception: pass
            threading.Thread(target=work, daemon=True).start()
        flat_button(clash_row, 'Check my mods', run_clash_check).pack(side='left')

        def collect():
            hb, hg, h20 = house_cfg()
            return {'house_bands': hb, 'house_grace': hg, 'house_cap20': h20,
                    'channel': ch.get().strip().lstrip('#'), 'webhook': wh.get().strip(),
                    'tc_alert': bool(tc_on.get()), 'scout_callout': bool(sc_on.get()),
                    'scout_ping': bool(sp_on.get()),
                    'concede_flag': bool(cf_on.get()), 'opp_openings': bool(oo_on.get()),
                    'focus_game': bool(fg_on.get()), 'castle_note': bool(cn_on.get()),
                    'feudal_note': bool(fn_on.get()), 'companion_results': bool(cr_on.get()),
                    'castle_food': int(typed_number(cm_e.get(), cfg.get('castle_food', CASTLE_NOTE_FOOD), 100, 5000)),
                    'feudal_pop': int(typed_number(fp_e.get(), cfg.get('feudal_pop', FEUDAL_NOTE_POP), 5, 60)),
                    'civ_panel_loading': bool(cp_on.get()),
                    'admin_auto': bool(ad_on.get()),
                    'friends': list(friends), 'friend_discord': dict(fdisc),
                    'live_pause_key': (lv['live_pause_key'].get().strip().upper()
                                       if combo_ok(lv['live_pause_key'].get()) else 'CTRL+F3'),
                    'live_before': lv['live_before'].get(), 'live_after': lv['live_after'].get(),
                    'live_channel': lv_chan.get().strip()}
        def save():
            c = collect()
            if c['webhook'] and not re.match(r'https://(\w+\.)?discord(app)?\.com/api/webhooks/', c['webhook']):
                msg.config(text="That doesn't look like a Discord webhook link.", fg=REDC); return
            if c.get('live_channel') and not discord_channel_link(c['live_channel']):
                lv_check(); msg.config(text="The Go Live voice channel needs to be the channel's link. "
                                            "See the note under it.", fg=REDC); return
            # Only what you changed here is written. Settings can sit built and hidden for a while,
            # and anything set elsewhere in the meantime (admin, lock, build order) is kept.
            merged = load_settings()
            first_ = st_set.get('initial') or {}
            for k_, v_ in c.items():
                if k_ not in first_ or first_[k_] != v_ or k_ not in merged: merged[k_] = v_
            save_settings(merged)
            tc_settings(); tc_draw()
            scorew.enabled = merged.get('concede_flag', True)
            close_win()
        def test():
            c = collect()
            if not c['webhook']: msg.config(text='Paste the webhook link first.', fg=REDC); return
            msg.config(text='Sending a test message\u2026', fg=MUT)
            body_ = ('Test from %s. Invites will look like this:\n' % APP_NAME +
                     invite_message('aoe2de://0/123456789', '123456789', discord_tags(dict(load_settings(), **c))))
            def work():                                  # off the main thread: Discord can be slow
                try:
                    post_discord(c['webhook'], body_)
                    t_, col_ = 'Sent a test message to #%s.' % (c['channel'] or 'discord'), GREEN
                except Exception as e:
                    t_, col_ = 'Discord said no: %s' % e, REDC
                try: root.after(0, lambda: msg.winfo_exists() and msg.config(text=t_, fg=col_))
                except Exception: pass
            threading.Thread(target=work, daemon=True).start()
        def close_win():
            st['settings_win'] = None; win.destroy()
            root.after(1500, prebuild_settings)          # the next one ready and waiting, with what was saved

        flat_button(wh_btns, 'Send a test message', test).pack(side='left')
        btns = tk.Frame(foot, bg=DEEP); btns.pack(fill='x', pady=(0, 0))
        flat_button(btns, 'Save', save, fill=True).pack(side='left')
        flat_button(btns, 'Close', close_win, accent=MUT, hot='#cfc8b6').pack(side='right')
        msg = tk.Label(foot, text='', fg='#b8b19f', bg=DEEP, font=F_SMALL, anchor='w',
                       justify='left', wraplength=400)
        msg.pack(fill='x', pady=(10, 0))
        try: st_set['initial'] = collect()                # what the window showed when it was built
        except Exception: pass
        win.built_ok = True                               # all of it is there
        win.update_idletasks()
        # Side by side columns, as many as it takes for everything to fit on the screen, so there
        # is nothing to scroll (scrolling a page of controls smears on Windows). Only a screen too
        # small for that still scrolls. The cards keep their order, top to bottom, left to right.
        try:
            kids = list(page.pack_slaves())
            hs = [c_.winfo_reqheight() + 8 for c_ in kids]
            cw = max(c_.winfo_reqwidth() for c_ in kids)
            room = win.winfo_screenheight() - 200 - 20          # what fit_ allows, less the page's own padding
            most = max(1, min(4, (win.winfo_screenwidth() - 70) // (cw + 16)))
            def groups(limit):
                out_, cur, tot = [], [], 0
                for c_, h_ in zip(kids, hs):
                    if cur and tot + h_ > limit: out_.append(cur); cur, tot = [], 0
                    cur.append(c_); tot += h_
                if cur: out_.append(cur)
                return out_
            def best(n_):
                lo_, hi_ = max(hs), sum(hs)
                while lo_ < hi_:
                    mid = (lo_ + hi_) // 2
                    if len(groups(mid)) <= n_: hi_ = mid
                    else: lo_ = mid + 1
                return lo_
            def shortest(n_):
                # each card, in turn, goes under whichever column is shortest so far
                cols, tot = [[] for _ in range(n_)], [0] * n_
                for c_, h_ in zip(kids, hs):
                    j = tot.index(min(tot)); cols[j].append(c_); tot[j] += h_
                return [c for c in cols if c], max(tot)
            def plan(n_):
                a_ = (groups(best(n_)), best(n_)); b_ = shortest(n_)
                return a_ if a_[1] <= b_[1] else b_
            n_ = next((k for k in range(1, most + 1) if plan(k)[1] <= room), most)
            grps, tall = plan(n_)
            log('settings: %d columns, tallest %d of %d (screen %dx%d)' % (n_, tall, room,
                win.winfo_screenwidth(), win.winfo_screenheight()))
            if n_ > 1 and len(kids) > 1:
                cols_ = tk.Frame(page, bg=DEEP); cols_.pack(fill='x')
                for j, grp in enumerate(grps):
                    col = tk.Frame(cols_, bg=DEEP)
                    col.grid(row=0, column=j, sticky='nwe', padx=(0 if j == 0 else 14, 0))
                    cols_.grid_columnconfigure(j, minsize=cw, uniform='col')
                    for c_ in grp:
                        info = c_.pack_info(); info.pop('in', None)
                        c_.pack_forget(); c_.pack(in_=col, **info); c_.lift()
                win.update_idletasks()
        except Exception as e:
            log('settings columns: %r' % (e,))
        fit_()
        win.bind('<Escape>', lambda e: close_win())        # Esc does the same as Cancel
        win.protocol('WM_DELETE_WINDOW', close_win)
        if show: reveal_settings(win)
        else:
            try:                                           # so the loading frame opens at the right size
                st['settings_geo'] = (win.winfo_reqwidth(), win.winfo_reqheight(),
                                      max(0, (win.winfo_screenwidth() - win.winfo_reqwidth()) // 2),
                                      max(0, (win.winfo_screenheight() - win.winfo_reqheight()) // 2 - 24))
            except tk.TclError: pass
    def busy_spinner(text):
        """A small gold spinner by the overlay while something takes a moment to build.
        Returns a function that takes it away."""
        w_ = tk.Toplevel(root); w_.overrideredirect(True); w_.attributes('-topmost', True)
        w_.configure(bg=RIM)
        f_ = tk.Frame(w_, bg=INK, padx=10, pady=7); f_.pack(padx=1, pady=1)
        c_ = tk.Canvas(f_, width=16, height=16, bg=INK, highlightthickness=0); c_.pack(side='left')
        tk.Label(f_, text=text, fg=MUT, bg=INK, font=F_SMALL).pack(side='left', padx=(8, 0))
        arc = c_.create_arc(2, 2, 14, 14, start=0, extent=270, style='arc', outline=GOLDC, width=2)
        live_ = {'on': True, 'a': 0}
        def spin():
            if not live_['on']: return
            live_['a'] = (live_['a'] - 30) % 360
            try: c_.itemconfigure(arc, start=live_['a']); w_.after(50, spin)
            except tk.TclError: pass
        w_.update_idletasks()
        x_ = root.winfo_rootx() + max(0, (root.winfo_width() - w_.winfo_reqwidth()) // 2)
        y_ = root.winfo_rooty() + root.winfo_height() + 6
        w_.geometry('+%d+%d' % (x_, y_)); w_.update(); spin()
        def gone():
            live_['on'] = False
            try: w_.destroy()
            except tk.TclError: pass
        return gone

    def open_settings_soon():
        """The gear: a spinner straight away, then Settings, which takes a moment to build."""
        if st.get('settings_win') is not None:
            open_settings(); return                        # already open: bring it to the front
        if st.get('settings_shell') is not None: return    # on its way
        # the frame with a spinner straight away, then Settings drops into it
        st['settings_shell'] = 'coming'                    # a second click meanwhile does nothing
        st['settings_shell'] = settings_shell()
        def go():
            try: open_settings()
            except Exception as e:
                log('settings open: %r' % (e,))
                w_ = st.get('settings_win')                 # half built: take it away, so the gear works again
                if w_ is not None and not getattr(w_, 'built_ok', False): drop_settings('settings_win')
            drop_settings('settings_shell')                 # if Settings never took its place
        root.after(15, go)
    st['actions'][gear] = open_settings_soon
    root.after(4000, prebuild_settings)

    def open_stats():
        """The record: filters for 1v1 / team games, time window and ranked, then your form, rating,
        best and worst civs, maps and match-ups, and the last games with their result."""
        if st.get('stats_win') is not None:
            try:
                if st['stats_win'].winfo_exists(): bring_up(st['stats_win']); return
            except tk.TclError: pass
            st['stats_win'] = None
        cfg_ = load_settings()
        st.setdefault('scope', cfg_.get('stats_mode', '1v1'))
        if st['scope'] not in ('1v1', 'TG'): st['scope'] = '1v1'
        st.setdefault('days', cfg_.get('stats_days', 0))
        st.setdefault('ranked', cfg_.get('stats_ranked', False))
        win = tk.Toplevel(root); st['stats_win'] = win
        win.withdraw()                                  # built out of sight, then faded up
        win.title(APP_NAME + ' record'); win.configure(bg=RIM); win.attributes('-topmost', True)
        win.geometry('600x760'); win.minsize(560, 460)
        outer = tk.Frame(win, bg=INK, padx=18, pady=14)
        outer.pack(fill='both', expand=True, padx=2, pady=2)

        hd = tk.Frame(outer, bg=INK); hd.pack(fill='x')
        tk.Label(hd, text='Record', fg=GOLDC, bg=INK, font=F_HEADLINE).pack(side='left')

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

        segment(bar_, 'scope', (('1v1', '1v1'), ('TG', 'Team games'))).pack(side='left')
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

        def table(parent, rows, limit=10, wide=110):
            t = tk.Frame(parent, bg=INK); t.pack(fill='x')
            t.columnconfigure(0, weight=1)
            for i, (name, played, w_, l_, unk) in enumerate(rows[:limit]):
                dec = w_ + l_
                fr = (w_ / dec) if dec else 0.0
                tk.Label(t, text=name, fg=TXT, bg=INK, font=('Segoe UI', 9), anchor='w').grid(row=i, column=0, sticky='w', pady=1)
                tk.Label(t, text='%d-%d' % (w_, l_), fg=MUT, bg=INK, font=F_SMALL, width=6,
                         anchor='e').grid(row=i, column=1, sticky='e', padx=(6, 6))
                bar(t, fr, wide=wide).grid(row=i, column=2, padx=(0, 6))
                tk.Label(t, text=('%d%%' % round(fr * 100)) if dec else '-', fg=GOLDC if dec else FAINT,
                         bg=INK, font=F_SMALL, width=5, anchor='e').grid(row=i, column=3, sticky='e')
            if len(rows) > limit:
                tk.Label(parent, text='and %d more' % (len(rows) - limit), fg=FAINT, bg=INK,
                         font=F_TINY, anchor='w').pack(fill='x')

        def side_by_side(parent, left, right):
            """Two short tables next to each other instead of one long one under another:
            (heading, rows) on the left, the same on the right."""
            both = tk.Frame(parent, bg=INK); both.pack(fill='x')
            both.columnconfigure(0, weight=1, uniform='half'); both.columnconfigure(1, weight=1, uniform='half')
            for col, (head, rows) in enumerate((left, right)):
                cell = tk.Frame(both, bg=INK)
                cell.grid(row=0, column=col, sticky='nwe', padx=(0, 12) if col == 0 else (12, 0))
                caption(cell, head)
                table(cell, rows, wide=52)

        def tile(parent, col, label):
            """One of the boxes across the top. Returns the frame to put its contents in."""
            box = tk.Frame(parent, bg=PANEL, highlightthickness=1, highlightbackground=EDGE, padx=10, pady=7)
            box.grid(row=0, column=col, sticky='nswe', padx=(0 if col == 0 else 6, 0))
            tk.Label(box, text=label, fg=FAINT, bg=PANEL, font=F_TINY, anchor='w').pack(fill='x')
            return box

        def sparkline(parent, pts, name):
            """Your rating game by game: a line, its high and low, and where it stands now."""
            row = tk.Frame(parent, bg=INK); row.pack(fill='x', pady=(8, 0))
            c = tk.Canvas(row, bg=INK, height=46, highlightthickness=0)
            c.pack(side='left', fill='x', expand=True)
            side = tk.Frame(row, bg=INK); side.pack(side='right', padx=(8, 0))
            tk.Label(side, text='high %d' % max(pts), fg=FAINT, bg=INK, font=F_TINY, anchor='e').pack(anchor='e')
            tk.Label(side, text='low %d' % min(pts), fg=FAINT, bg=INK, font=F_TINY, anchor='e').pack(anchor='e')
            tk.Label(side, text='%d games' % len(pts), fg=FAINT, bg=INK, font=F_TINY, anchor='e').pack(anchor='e')
            def draw(_=None):
                c.delete('all')
                w, h = max(40, c.winfo_width()), 46
                lo, hi = min(pts), max(pts)
                span = float(max(1, hi - lo))
                xy = []
                for i, p in enumerate(pts):
                    xy += [4 + (w - 10) * i / float(max(1, len(pts) - 1)), 5 + (h - 10) * (1 - (p - lo) / span)]
                c.create_line(0, h - 1, w, h - 1, fill=EDGE)
                c.create_line(*xy, fill=GOLDC, width=2)
                c.create_oval(xy[-2] - 3, xy[-1] - 3, xy[-2] + 3, xy[-1] + 3, fill=GOLDD, outline=INK)
            c.bind('<Configure>', draw)

        def build():
            paint_chips()
            for w in list(summary.winfo_children()) + list(inner.winfo_children()): w.destroy()
            every = [g for g in load_stats()['games'] if online_game(g)]      # games against the computer are left out
            games = filter_games(every, st['scope'], st['days'], st['ranked'])
            wins = sum(1 for g in games if g.get('result') == 'win')
            losses = sum(1 for g in games if g.get('result') == 'loss')
            decided = wins + losses
            rate = (wins / decided) if decided else 0.0

            # across the top: win rate, the record, your form, your rating
            tiles = tk.Frame(summary, bg=INK); tiles.pack(fill='x', pady=(4, 0))
            for col in range(4): tiles.columnconfigure(col, weight=1, uniform='tile')
            t1 = tile(tiles, 0, 'WIN RATE')
            tk.Label(t1, text=('%d%%' % round(rate * 100)) if decided else '-', fg=GOLDC, bg=PANEL,
                     font=(DISPLAY, 20, 'bold'), anchor='w').pack(fill='x')
            if decided: bar(t1, rate, wide=104, high=6).pack(anchor='w', pady=(2, 0))

            t2 = tile(tiles, 1, 'RECORD')
            tk.Label(t2, text='%d - %d' % (wins, losses), fg=TXT, bg=PANEL, font=(DISPLAY, 20, 'bold'), anchor='w').pack(fill='x')
            extra = len(games) - decided
            tk.Label(t2, text='%d game%s%s' % (len(games), '' if len(games) == 1 else 's',
                                               ('  ·  %d no result' % extra) if extra else ''),
                     fg=FAINT, bg=PANEL, font=F_TINY, anchor='w').pack(fill='x')

            t3 = tile(tiles, 2, 'FORM')
            kind, n = current_streak(games)
            tk.Label(t3, text=('%s%d' % (kind, n)) if kind else '-', fg=(GREEN if kind == 'W' else REDC) if kind else FAINT,
                     bg=PANEL, font=(DISPLAY, 20, 'bold'), anchor='w').pack(fill='x')
            form = [g.get('result') for g in games if g.get('result') in ('win', 'loss')][-10:]
            dots = tk.Frame(t3, bg=PANEL); dots.pack(anchor='w', pady=(3, 0))
            for r in form:
                tk.Frame(dots, bg=GREEN if r == 'win' else REDC, width=8, height=8).pack(side='left', padx=(0, 2))

            ladder, pts, moved = rating_line(games)
            t4 = tile(tiles, 3, 'RATING')
            tk.Label(t4, text=str(pts[-1]) if pts else '-', fg=TXT if pts else FAINT, bg=PANEL,
                     font=(DISPLAY, 20, 'bold'), anchor='w').pack(fill='x')
            if pts:
                tk.Label(t4, text='%+d  ·  %s' % (moved, ladder.replace('Random Map', 'RM').replace('Empire Wars', 'EW')),
                         fg=GREEN if moved > 0 else REDC if moved < 0 else FAINT, bg=PANEL, font=F_TINY, anchor='w').pack(fill='x')

            under = []
            lens_w = [game_length(g) for g in games if g.get('result') == 'win' and game_length(g)]
            lens_l = [game_length(g) for g in games if g.get('result') == 'loss' and game_length(g)]
            if lens_w or lens_l:
                under.append('average game:  wins %s, losses %s' % (
                    fmt_len(sum(lens_w) / len(lens_w)) if lens_w else '-',
                    fmt_len(sum(lens_l) / len(lens_l)) if lens_l else '-'))
            if st['scope'] == 'all':                                  # how the two kinds of game compare
                for lab, key in (('1v1', '1v1'), ('TG', 'TG')):
                    w2 = sum(1 for g in games if g.get('mode') == key and g.get('result') == 'win')
                    l2 = sum(1 for g in games if g.get('mode') == key and g.get('result') == 'loss')
                    if w2 + l2: under.append('%s %d-%d (%d%%)' % (lab, w2, l2, round(100 * w2 / (w2 + l2))))
            if under:
                tk.Label(summary, text='   ·   '.join(under), fg=MUT, bg=INK, font=F_TINY, anchor='w').pack(fill='x', pady=(6, 0))
            if len(pts) >= 4: sparkline(summary, pts, ladder)

            if not games:
                tk.Label(inner, text='No games here yet. Try a wider filter, or play one and it will show up.',
                         fg=MUT, bg=INK, font=F_BODY, anchor='w').pack(fill='x', pady=(20, 0))
                return

            civs = tally_by(games, 'civ')
            maps = tally_by(games, 'map')
            opps = tally_by(games, 'opp')
            # the takeaways: where you win and where you struggle (3+ decided games)
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
                    cell = tk.Frame(grid_, bg=PANEL, highlightthickness=1, highlightbackground=EDGE, padx=8, pady=4)
                    cell.grid(row=i // 3, column=i % 3, sticky='we', padx=(0, 6), pady=3)
                    tk.Label(cell, text=lab.upper(), fg=FAINT, bg=PANEL, font=F_TINY, anchor='w').pack(fill='x')
                    tk.Label(cell, text=val, fg=col, bg=PANEL, font=('Segoe UI', 9), anchor='w').pack(fill='x')
                for col in range(3): grid_.columnconfigure(col, weight=1, uniform='note')

            bans = map_bans([g for g in games if g.get('ranked')] or games)
            if bans:
                caption(inner, 'BAN THESE MAPS', 'your worst, 4+ decided ranked games')
                table(inner, bans, limit=3)

            side_by_side(inner, ('YOUR CIVILISATIONS', civs), ('MAPS', maps))
            faced = [r for r in opps if r[0] != 'Unknown'] or opps
            half = (min(len(faced), 20) + 1) // 2
            side_by_side(inner, ('AGAINST' + ('  (first opponent in team games)' if st['scope'] != '1v1' else ''), faced[:half]),
                         ('', faced[half:half * 2]))

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
                         fg=MUT, bg=INK, font=F_TINY, width=8, anchor='e').grid(row=i, column=3, sticky='e', padx=(6, 0))
                res = g.get('result', '?')
                delta = rating_change(g)
                tk.Label(recent, text=delta, fg=GREEN if delta.startswith('+') else REDC, bg=INK, font=F_TINY,
                         width=4, anchor='e').grid(row=i, column=4, sticky='e', padx=(6, 0))
                fresh = time.time() - max(g.get('started', 0), g.get('ended', 0)) < 3600
                word = {'win': 'WON', 'loss': 'LOST'}.get(res, 'waiting' if fresh else 'no result')
                col = {'win': GREEN, 'loss': REDC}.get(res, FAINT)
                tk.Label(recent, text=word, fg=col, bg=PANEL, font=F_TINY, padx=5, pady=2,
                         width=8, highlightthickness=1,
                         highlightbackground=RIM).grid(row=i, column=5, sticky='e', padx=(8, 0))

        r1 = Rule(outer); r1.configure(bg=INK); r1.pack(fill='x', pady=(10, 0))
        btns = tk.Frame(outer, bg=INK); btns.pack(fill='x', pady=(10, 0))
        flat_button(btns, 'Close', close_win, accent=MUT, hot=TXT).pack(side='right')
        def check_now():
            if st.get('checking'): return
            st['checking'] = True
            def work():
                try: fill_results(me, force=True)
                except Exception as e: log('check results: %r' % (e,))
                finally:
                    st['checking'] = False
                    try: root.after(0, refresh_stats_window)
                    except Exception: pass
            threading.Thread(target=work, daemon=True).start()
        flat_button(btns, 'Check results now', check_now).pack(side='left')
        tk.Label(outer, text='Results come from your own online match history, so nothing is guessed: the game\'s '
                 'service first, then aoe2companion.com for older games. Games against the computer are '
                 'left out. R marks a ranked game, and the number beside it is what the game did to your rating.',
                 fg=FAINT, bg=INK, font=F_TINY,
                 anchor='w', justify='left', wraplength=540).pack(fill='x', pady=(8, 0))
        st['stats_build'] = build
        build()
        win.bind('<Escape>', lambda e: close_win())
        win.protocol('WM_DELETE_WINDOW', close_win)
        win.update_idletasks()
        win.geometry('+%d+%d' % (max(0, (win.winfo_screenwidth() - 600) // 2),
                                 max(0, (win.winfo_screenheight() - 760) // 2 - 24)))
        fade_in(win)
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

    # ---- the game runs as administrator, so Windows bins our clicks. Say why, offer to fix the cause
    # (so it never needs admin again), or restart Wingman as admin and carry on with the invite.
    def hide_admin():
        for w in admin_box.winfo_children(): w.destroy()
        admin_box.grid_remove()

    def go_admin(resume):
        hide_admin()
        host_msg.config(text='Windows will ask if Wingman can make changes. Click Yes and it carries on by itself.')
        def work():
            try: ok = relaunch_as_admin(resume)
            except Exception as e: log('restart as admin failed: %r' % (e,)); ok = False
            def after():
                if ok:
                    try: root.destroy()
                    finally: os._exit(0)
                host_msg.config(text='Wingman did not restart as admin, so nothing was clicked.')
            root.after(0, after)
        threading.Thread(target=work, daemon=True).start()

    def show_admin(resume):
        hide_admin()
        why, fixable = why_game_is_admin()
        host_msg.config(text=why + ' Windows won\'t let Wingman click the game unless Wingman runs as admin too.'
                        + (' "Fix it" stops that for good (then restart Steam and the game).' if fixable else ''))
        if fixable:
            def fix():
                try: cleared, left = clear_admin_flags()
                except Exception as e: log('fix admin: %r' % (e,)); cleared, left = [], ['?']
                hide_admin()
                host_msg.config(text=('Done. Close Steam fully (right click its tray icon > Exit), open it again and '
                                      'start the game. Wingman won\'t need admin after that.') if cleared and not left
                                 else 'Could not change that setting. Restart Wingman as admin for now.')
            flat_button(admin_box, 'Fix it', fix, fill=True).pack(side='left', padx=(0, 8))
        flat_button(admin_box, 'Restart Wingman as admin', lambda: go_admin(resume),
                    fill=not fixable).pack(side='left')
        def always():
            c = load_settings(); c['admin_auto'] = True; save_settings(c); go_admin(resume)
        flat_button(admin_box, 'Always', always).pack(side='left', padx=(8, 0))
        bind_all(admin_box); admin_box.grid()

    def host(send_only=False):
        if st.get('hosting'):                              # the button reads Stop while running
            STOP.set(); host_msg.config(text='Stopping...'); return
        if not waiting_now[0]:
            # it clicks through the game's menus: never while a match is on screen
            host_msg.config(text='The ranked invite works from the main menu, not during a game.', fg=MUT)
            foot_fit(); return
        hide_admin()
        resume = 'send' if send_only else 'party'
        try: blocked = game_needs_admin()
        except Exception as e: log('admin check: %r' % (e,)); blocked = None
        if blocked:
            log('game is elevated, clicks would be blocked')
            if load_settings().get('admin_auto'): go_admin(resume)
            else: show_admin(resume)
            return
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
    if '--resume' in sys.argv:                             # restarted as admin part way through: carry on
        try: what = sys.argv[sys.argv.index('--resume') + 1]
        except IndexError: what = 'party'
        if what == 'live':
            log('restarted as admin, carrying on with Go Live')
            root.after(2500, lambda: st['live_start'](True))
        else:
            log('restarted as admin, resuming the %s invite' % what)
            root.after(2500, lambda: host(what == 'send'))

    # ------------------------------------------------------------ publish by itself
    # Only on Ash's own setup, where Publish-Wingman.cmd sits above this copy: when a new build
    # lands in the incoming folder, run the publish script (commit, push dev, merge and push
    # Prod), then restart into the new copy the next time you are at the menu, never mid game.
    def find_publish():
        """The folder with Publish-Wingman.cmd in it: above this copy, or the usual spot on the desktop."""
        here = os.path.dirname(os.path.abspath(self_path()))
        tops = [os.path.dirname(here), here]
        for desk in (os.path.join(HOME, 'Desktop'), os.path.join(HOME, 'OneDrive*', 'Desktop')):
            tops += sorted(glob.glob(os.path.join(desk, 'Claude', 'AoE2 Map Overlay')))
        for t in tops:
            if os.path.isfile(os.path.join(t, 'Publish-Wingman.cmd')): return t
        log('auto publish: off, no Publish-Wingman.cmd near %s' % here)
        return None

    def home_copy():
        """The copy to run: this one if it sits in the repo, else the repo's Prod copy. A copy
        left in Downloads never gets the updates, so it hands over to Prod."""
        top = find_publish()
        me = os.path.normcase(os.path.abspath(self_path()))
        if not top or me.startswith(os.path.normcase(os.path.abspath(top)) + os.sep): return self_path()
        prod = os.path.join(top, 'Prod', BAT_NAME)
        return prod if os.path.isfile(prod) else self_path()

    def auto_publish():
        top = find_publish()
        if not top: return
        if not FROZEN and os.path.normcase(home_copy()) != os.path.normcase(self_path()):
            log('auto publish: this copy is outside the repo, handing over to %s at the menu' % home_copy())
            st['restart_into'] = 'the Prod copy'
        pub = os.path.join(top, 'Publish-Wingman.cmd')
        inc = os.path.join(top, 'incoming', BAT_NAME)
        import subprocess
        log('auto publish: watching %s' % inc)
        last, tried = None, None
        while True:
            time.sleep(4)
            try:
                if not os.path.isfile(inc): last = None; continue
                st_ = os.stat(inc); sig = (st_.st_size, int(st_.st_mtime))
                if sig != last: last = sig; continue              # still landing: wait for it to settle
                if sig == tried: continue                         # that one already failed once
                ver = script_version(inc) or '?'
                log('auto publish: %s is waiting, publishing it' % ver)
                out = os.path.join(os.path.dirname(LOG), 'wingman_publish.log')
                env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
                with open(out, 'w', encoding='utf-8', errors='replace') as fh:
                    # one string with the whole thing in an extra pair of quotes, which cmd /c
                    # strips, so the quotes round the path and the message survive
                    r = subprocess.run('cmd /c ""%s" "auto publish" /auto"' % pub, cwd=top, env=env,
                                       stdout=fh, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                       creationflags=0x08000000, timeout=300)
                if r.returncode != 0 or os.path.isfile(inc):
                    tried = sig
                    log('auto publish: %s did not go through (see wingman_publish.log)' % ver)
                    root.after(0, lambda v=ver: host_msg.config(
                        text='Could not publish %s by itself. Run Publish-Wingman.cmd to see why.' % v))
                    continue
                log('auto publish: %s is on dev and Prod' % ver)
                if FROZEN:
                    log('auto publish: the exe for %s builds on GitHub, the bar will offer it' % ver)
                elif _sha(home_copy()) != SELF_SHA:
                    st['restart_into'] = ver
                else:
                    log('auto publish: this copy (%s) is not the one that changed, no restart' % self_path())
            except subprocess.TimeoutExpired:
                tried = last; log('auto publish: took too long, left it for you to run')
            except Exception as e:
                log('auto publish: %r' % (e,)); time.sleep(20)

    def settings_open():
        w = st.get('settings_win')
        try: return bool(w) and bool(w.winfo_exists())
        except Exception: return False

    def restart_when_free():
        ver = st.get('restart_into')
        if ver and waiting_now[0] and not st.get('live_busy') and not st.get('hosting') \
                and not st.get('updating') and not settings_open():
            log('auto publish: restarting into %s' % ver)
            try: restart_app(home_copy())
            except Exception as e:
                log('restart failed: %r' % (e,)); st['restart_into'] = None
            else:
                try: root.destroy()
                finally: os._exit(0)
        root.after(3000, restart_when_free)
    threading.Thread(target=auto_publish, daemon=True).start()
    root.after(5000, restart_when_free)

    # Remote tests, on Ash's setup only: a file named wingman_test.txt in the incoming folder
    # holds one word, and Wingman does that and writes what happened to its log.
    #   live   - the Discord half of Go Live (no pause, no chat)
    #   stop   - Stop Streaming
    #   dump   - write what Discord is showing to discord_dump.txt beside the log
    #   restart- start this copy again
    def test_watch():
        top = find_publish()
        if not top: return
        cmd_file = os.path.join(top, 'incoming', 'wingman_test.txt')
        while True:
            time.sleep(2)
            try:
                if not os.path.isfile(cmd_file): continue
                with open(cmd_file, encoding='utf-8', errors='replace') as fh: what = fh.read().strip().lower()
                try: os.remove(cmd_file)
                except OSError: os.replace(cmd_file, cmd_file + '.done')
                log('test: %s' % what)
                if what.startswith('live'):
                    root.after(0, lambda g_=('game' in what): st['live_start'](g_))
                elif what == 'stop':
                    log('test: stop streaming %s' % ('done' if discord_stop() else 'found nothing to stop'))
                elif what == 'dump':
                    out = os.path.join(os.path.dirname(LOG), 'discord_dump.txt')
                    log('test: wrote %d controls to %s' % (discord_dump(out), out))
                elif what == 'restart':
                    st['restart_into'] = 'the same copy'
            except Exception as e:
                log('test: %r' % (e,))
    threading.Thread(target=test_watch, daemon=True).start()

    # A newer public release: say so on the bar at the menu, one click to take it. The exe swaps
    # itself; a .bat takes Prod. Ash's own setup publishes and restarts by itself, so not there.
    clear_old_exe()
    # The exe: put it in the Start menu and on the Desktop the first time it runs, then keep those
    # pointing at it if it moves. Done quietly; pinning to the taskbar is the player's call.
    def shortcuts_once():
        cfg_ = load_settings()
        if cfg_.get('shortcuts_made'):
            make_shortcuts(only_fix=True); return
        made = make_shortcuts()
        if not made: return
        cfg_ = load_settings(); cfg_['shortcuts_made'] = True; save_settings(cfg_)   # quietly: no message
    if FROZEN: threading.Thread(target=shortcuts_once, daemon=True).start()
    def nudge_update():
        time.sleep(NUDGE_AFTER)
        rel = newer_release()
        if not rel or (not FROZEN and find_publish()): return
        def take():
            st['actions'].pop(host_msg, None)                     # one click only, and the line stops being a link
            if st.get('updating'): return
            if not waiting_now[0]:
                host_msg.config(text='Update after this game: click here at the menu.', fg=MUT)
                st['actions'][host_msg] = take; return
            st['updating'] = True
            host_msg.config(text='Getting %s...' % rel['ver'], fg=MUT)
            def work():
                try:
                    if FROZEN:
                        path_ = update_exe(rel)
                        start_fresh_exe(path_, '--wait-turn')
                    else:
                        ok_, text_, path_ = update_from_github('Prod')
                        if not path_:
                            st['updating'] = False
                            root.after(0, lambda t=text_, c=(MUT if ok_ else REDC): host_msg.config(text=t, fg=c))
                            return
                        restart_app(path_)
                    root.after(0, lambda: (root.destroy(), os._exit(0)))
                except Exception as e:
                    log('update from the bar: %r' % (e,))
                    st['updating'] = False
                    root.after(0, lambda t='Could not update: %s' % e: host_msg.config(text=t, fg=REDC))
            threading.Thread(target=work, daemon=True).start()
        def show():
            if host_msg.cget('text').strip():                     # something more pressing is up
                root.after(30000, show); return
            host_msg.config(text='\u2191 Wingman %s is out. Click here to update.' % rel['ver'], fg=GOLDD)
            st['actions'][host_msg] = take; bind_all(host_msg)
            foot_fit()
        try: root.after(0, show)
        except Exception: pass
    threading.Thread(target=nudge_update, daemon=True).start()

    def show_opponents(players):
        for w in opp_area.winfo_children(): w.destroy()
        for w in [w for w in st['actions'] if not _alive(w)]:
            st['actions'].pop(w, None)                 # clicks for widgets that no longer exist
        opp_area.grid_configure(pady=(0, 0))
        opp_area.config(width=1, height=1)         # an emptied frame keeps its old size unless told otherwise,
                                                   # which left the panel tall after a game
        mine = next((p for p in players if p['human'] and p['profile'] == me), None)
        opps = [p for p in players if p is not mine and (mine is None or p['team'] <= 1 or p['team'] != mine['team'])]
        team_game = len(players) > 2
        if not opps:
            opp_area.grid_remove(); return
        opp_area.grid(); opp_area.grid_configure(pady=(6, 0))
        cap = tk.Label(opp_area, text='OPPONENTS' if len(opps) > 1 else 'OPPONENT', fg=BRONZE, bg=PANEL,
                       font=F_TINY, anchor='w')
        cap.grid(row=0, column=0, sticky='w', pady=(0, 3)); bind_all(cap)
        def scouting_report(box, pr, col):
            """One line: a bar split by how often they open each way, the usual one named with
            its count, then their usual Feudal and Castle times. As your own game clock comes up
            to one of those times it turns amber with a countdown, then red while it is due."""
            for w in box.winfo_children(): w.destroy()
            line1 = tk.Frame(box, bg=PANEL); line1.pack(fill='x', anchor='w')
            ic = tk.Canvas(line1, width=13, height=13, bg=PANEL, highlightthickness=0)
            draw_icon(ic, 'clock', 13, BRONZE); ic.pack(side='left', padx=(0, 5))
            W, H = 54, 7
            bar = tk.Canvas(line1, width=W, height=H, bg=INK, highlightthickness=1, highlightbackground=RIM)
            x, total = 0.0, float(sum(n for _, n in pr['dist'])) or 1.0
            for k, (lab, n) in enumerate(pr['dist']):
                w_ = W * n / total
                bar.create_rectangle(x, 0, x + w_, H, width=0,
                                     fill=col if k == 0 else (MUT if k == 1 else RIM))
                x += w_
            bar.pack(side='left', padx=(0, 6))
            lead = tk.Label(line1, text='%s %d/%d' % (pr['opening'], pr['observed'], pr['matches']),
                            fg=GOLDD, bg=PANEL, font=(DISPLAY, 9, 'bold'))
            lead.pack(side='left')
            when = tk.Label(line1, text='', fg=MUT, bg=PANEL, font=F_SMALL)
            when.pack(side='left', padx=(8, 0))
            for w in (box, line1, ic, bar, lead, when): bind_all(w)
            # and what to do about it: a stock answer to the way they usually open
            ans = opening_answer(pr['opening'])
            if ans:
                line2 = tk.Frame(box, bg=PANEL); line2.pack(fill='x', anchor='w', pady=(2, 0))
                # a small gold reply arrow: what to do back
                sh = tk.Canvas(line2, width=16, height=14, bg=PANEL, highlightthickness=0)
                sh.create_line(4, 1, 4, 9, 14, 9, fill=GOLDC, width=2, arrow='last', arrowshape=(5, 6, 3),
                               capstyle='round', joinstyle='round')
                sh.pack(side='left', padx=(0, 5), anchor='n', pady=(1, 0))
                al = tk.Label(line2, text=ans, fg='#e6d9b0', bg=PANEL, font=F_SMALL, anchor='w', justify='left',
                              wraplength=340)
                al.pack(side='left', fill='x')
                for w in (line2, sh, al): bind_all(w)
            marks = [(nm_, sec) for nm_, sec in (('Feudal', pr.get('feudal')), ('Castle', pr.get('castle'))) if sec]
            def tick_():
                try:
                    if not when.winfo_exists(): return
                except Exception:
                    return
                now_s = tcw.game_minutes(time.time()) * 60 if tcw.active else None
                bits, colour = [], MUT
                for nm_, sec in marks:
                    left = sec - now_s if now_s is not None else None
                    if left is not None and 0 < left <= 90:
                        bits.append('%s ~%s (in %s)' % (nm_, mmss(sec), mmss(left))); colour = GOLDD
                    elif left is not None and -150 < left <= 0:
                        bits.append('%s due ~%s' % (nm_, mmss(sec))); colour = REDC
                    elif left is None or left > 0:
                        bits.append('%s ~%s' % (nm_, mmss(sec)))
                when.config(text='  \u00b7  '.join(bits[:2]), fg=colour)
                root.after(3000, tick_)
            tick_()
            box.grid()

        folded = bool(load_settings().get('opp_folded', False))    # how you left it last time
        opp_area.columnconfigure(0, weight=1)                      # the rating stays hard right, folded or not
        for i, p in enumerate(opps):
            name, text = civ_text(p['civ'], strings, icons)
            tone = name_colour(p.get('colour'), RED)        # the colour the game writes their name in
            solid = player_colour(p.get('colour'))[0] or tone   # and the one it paints them in
            nm = {'shown': p['name'] if len(p['name']) <= 20 else p['name'][:19] + '\u2026'}
            row = tk.Frame(opp_area, bg=PANEL)
            row.grid(row=i + 1, column=0, sticky='we', pady=(3 if i else 0, 0))
            row.columnconfigure(0, weight=1)

            # The player's line: who they are, their civ, what they open with, and their ladder
            # rating. 1v1 is the number that matters, so it is the big one; the team rating sits
            # beside it, quieter. Click the line and everything under it folds away.
            top = tk.Frame(row, bg=PANEL); top.grid(row=0, column=0, sticky='we')
            top.columnconfigure(4, weight=1)
            dot = tk.Canvas(top, width=11, height=11, bg=PANEL, highlightthickness=0, cursor='hand2')
            dot.create_oval(1, 1, 10, 10, fill=solid, outline=RIM)
            # (no coloured dot: the name is already in their colour)
            who = tk.Label(top, text='', fg=tone, bg=PANEL, font=F_HEAD, anchor='w', cursor='hand2')
            who.grid(row=0, column=1, sticky='w')
            # the civ's name opens the notes on that civ, with a small arrow to say it does
            civf = tk.Frame(top, bg=PANEL, cursor='hand2')
            civf.grid(row=0, column=2, sticky='w', padx=(8, 0), pady=(2, 0))
            civl = tk.Label(civf, text=name.upper(), fg=TXT, bg=PANEL, font=(DISPLAY, 9, 'bold'),
                            anchor='w', cursor='hand2')
            civl.pack(side='left')
            u3 = tk.Label(civf, text='\u25be', fg=MUT, bg=PANEL, font=F_SMALL, cursor='hand2', padx=3)
            u3.pack(side='left')
            opn = tk.Frame(top, bg=PANEL)
            opn.grid(row=0, column=3, sticky='w', padx=(8, 0))
            elo1 = tk.Label(top, text='', fg=GOLDD, bg=PANEL, font=(DISPLAY, 11, 'bold'), anchor='e')
            elo1.grid(row=0, column=5, sticky='e')
            elo2 = tk.Label(top, text='', fg=MUT, bg=PANEL, font=F_TINY, anchor='e')
            elo2.grid(row=0, column=6, sticky='e', padx=(6, 0))

            # Under it: what beats their unique unit, and behind that line the notes on the civ.
            more = tk.Frame(row, bg=PANEL)
            more.grid(row=1, column=0, sticky='we', padx=(18, 0))
            beat = tk.Frame(more, bg=PANEL)
            beat.grid(row=0, column=0, sticky='w', pady=(2, 0))
            # The scouting report: their usual opening as a bar of how often, and when they
            # usually reach Feudal and Castle, counting down against your own game clock.
            intel = tk.Frame(more, bg=PANEL)
            intel.grid(row=1, column=0, sticky='w', pady=(3, 0)); intel.grid_remove()
            det = tk.Label(more, text=text, fg='#cfc8b6', bg=PANEL, font=F_SMALL, anchor='w',
                           justify='left', wraplength=380)
            det.grid(row=2, column=0, sticky='w', pady=(2, 0)); det.grid_remove()
            if folded: more.grid_remove()

            def mark(parent, kind, col):
                c = tk.Canvas(parent, width=14, height=14, bg=PANEL, highlightthickness=0)
                draw_icon(c, kind, 14, col); c.pack(side='left', padx=(0, 6))
                bind_all(c); return c

            uu, beats = uu_counter(p['civ'], strings, icons)
            try:                                   # their unique unit: a small drawn sword
                from PIL import ImageTk
                if 'uu_img' not in st: st['uu_img'] = ImageTk.PhotoImage(draw_step_icon('sword', 16, PANEL))
                c_ = tk.Label(beat, image=st['uu_img'], bg=PANEL, bd=0); c_.pack(side='left', padx=(0, 6))
                bind_all(c_)
            except Exception:
                mark(beat, 'swords', BRONZE)
            u1 = tk.Label(beat, text=uu or 'Civ notes', fg='#e6d9b0', bg=PANEL, font=F_SMALL, cursor='hand2')
            u1.pack(side='left')
            u2 = tk.Label(beat, text=('  \u2192 ' + beats) if beats else '',
                          fg=GREEN if beats else FAINT, bg=PANEL, font=F_SMALL, cursor='hand2')
            u2.pack(side='left')

            def name_now(h=who, box=more, nm=nm):
                h.config(text=nm['shown'])                 # the fold shows for itself: no arrows needed
            def fold(box=more, show=name_now):
                """A click on the player's line: everything under it folds away, or comes back.
                It is remembered, so the next game starts the way you left this one."""
                toggle(box); show()
                try:
                    c = load_settings(); c['opp_folded'] = not box.winfo_manager(); save_settings(c)
                except Exception as e:
                    log('could not remember the fold: %r' % (e,))
            def notes(dt=det, arrow=u3, box=more):
                """A click on the civ's name (or the unique unit's line): the notes on the civ."""
                if not box.winfo_manager(): box.grid()          # folded away: open it to show them
                toggle(dt); arrow.config(text='\u25b4' if dt.winfo_manager() else '\u25be')
            def fit(line=top, box=opn, nm=nm, show=name_now):
                """Keep the player's line inside the panel. The second opening goes first, then
                the end of a long name."""
                for _ in range(24):
                    line.update_idletasks()
                    if line.winfo_reqwidth() <= 400: break
                    kids = [w for w in box.winfo_children() if isinstance(w, tk.Frame)]
                    if len(kids) > 1: kids[-1].destroy()
                    elif len(nm['shown']) > 9: nm['shown'] = nm['shown'][:-3].rstrip('\u2026') + '\u2026'; show()
                    else: break
            name_now()
            hover(who, tone, lighten(tone, 0.35))
            for w in (top, dot, who, opn): st['actions'][w] = fold
            for w in [beat] + beat.winfo_children() + [civf, civl, u3]: st['actions'][w] = notes
            hover(civl, TXT, GOLDD); hover(u3, MUT, GOLDD)
            for w in (row, top, dot, who, civf, civl, opn, more, beat, det, u1, u2, u3): bind_all(w)

            # the civ's usual openings until their own games have been read
            def chips(box, tops, lead_colour, click, after):
                for w in box.winfo_children(): w.destroy()
                for n_, (lab, cnt) in enumerate(tops):
                    lead = n_ == 0
                    # quiet tags: a dark plate, the usual one lit in their colour, no heavy boxes
                    c = tk.Frame(box, bg=INK, cursor='hand2')
                    bar_ = tk.Frame(c, bg=lead_colour if lead else EDGE, width=2)
                    bar_.pack(side='left', fill='y')
                    t = tk.Label(c, text=lab.upper(), fg=GOLDD if lead else MUT, bg=INK,
                                 font=(F_SMALL[0], F_SMALL[1], 'bold'), padx=6, pady=1)
                    t.pack(side='left')
                    bits = [t, bar_]
                    if cnt:
                        x = tk.Label(c, text='\u00d7%d' % cnt, fg=FAINT, bg=INK, font=F_TINY, pady=1)
                        x.pack(side='left', padx=(0, 6)); bits.append(x)
                    c.pack(side='left', padx=(0, 4))
                    for w in [c] + bits:
                        st['actions'][w] = click; bind_all(w)
                box.grid(); after()

            def note(box, txt, click, after, col=FAINT):
                for w in box.winfo_children(): w.destroy()
                lb = tk.Label(box, text=txt, fg=col, bg=PANEL, font=F_SMALL, anchor='w')
                lb.pack(side='left'); st['actions'][lb] = click; bind_all(lb)
                box.grid(); after()

            typical = [(x, 0) for x in civ_typical(name)]
            if typical: chips(opn, typical, RIM, fold, fit)
            else: note(opn, 'no openings on file', fold, fit)

            if p.get('human'):
                def look(pp=p, a=elo1, b=elo2, fit_=fit):
                    e = fetch_elo(pp.get('profile') or None, pp['name'])
                    def put():
                        try:
                            if e.get('1v1'): a.config(text=str(e['1v1']))
                            if e.get('tg'): b.config(text='TG %d' % e['tg'])
                            if not e.get('1v1') and e.get('tg'):
                                a.config(text=str(e['tg'])); b.config(text='TG')
                            fit_()
                        except Exception: pass
                    try: root.after(0, put)
                    except Exception: pass
                threading.Thread(target=look, daemon=True).start()

                def habits(pp=p, box=opn, dt=det, base=text, tone_=tone, civ_=name, fold_=fold, fit_=fit,
                           chips_=chips, note_=note, report_=lambda pr, col, f=intel: scouting_report(f, pr, col)):
                    def post(fn):
                        for _ in range(40):
                            try: root.after(0, calm(fn)); return
                            except RuntimeError: time.sleep(0.25)   # the window is still starting up
                    try:
                        post(lambda: note_(box, 'reading their games\u2026', fold_, fit_))
                        rows = opponent_openings(pp['profile'], 'TG' if team_game else '1v1',
                                                 5 if team_game else OPEN_GAMES)
                        tops = top_openings(rows)
                        detail = '\n'.join(openings_lines(rows, pp['civ'], strings))
                        pred = intel_predict(rows, pp['civ'])
                        def done():
                            try:
                                if pred: report_(pred, tone_)
                                if tops: chips_(box, tops, tone_, fold_, fit_)
                                else:
                                    back = [(x, 0) for x in civ_typical(civ_)]
                                    if back: chips_(box, back, RIM, fold_, fit_)
                                    else: note_(box, 'no recent games', fold_, fit_)
                                if detail: dt.config(text=base + '\n' + detail)
                            except Exception: pass
                        post(done)
                    except Exception as e:
                        log('openings lookup failed: %r' % (e,))
                if pp_ok(p, i): threading.Thread(target=habits, daemon=True).start()
    show_opponents = calm(show_opponents)

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

    def wake_check():
        """A second start asked us to show ourselves: back on screen, on top, solid."""
        try:
            if not os.path.exists(WAKE_FILE): return
            os.remove(WAKE_FILE)
        except Exception:
            return
        try:
            log('opened again: showing the overlay (was %s, %s, seen %s, alpha %s)' % (
                root.geometry(), root.state(), root.winfo_viewable(), root.attributes('-alpha')))
            x_, y_ = root.winfo_x(), root.winfo_y()
            if not (-60 <= x_ <= root.winfo_screenwidth() - 80 and -20 <= y_ <= root.winfo_screenheight() - 40):
                root.geometry('+20+120')
            root.deiconify()
            root.attributes('-alpha', 0.97); st['alpha'] = 0.97
            root.attributes('-topmost', False); root.attributes('-topmost', True); root.lift()
            hold_now()
        except Exception as e:
            log('showing the overlay: %r' % (e,))

    def fast():
        try:
            wake_check()
            refresh(); hover_fade(); foot_fit()
            try: feudal_reminder(); castle_reminder()
            except Exception as e: log('reminder: %r' % (e,))
        except Exception as e:
            if not st.get('fast_err'): st['fast_err'] = 1; log('fast tick: %r' % (e,))
        finally:
            root.after(500, fast)

    def tick():
        try:
            f = newest_replay()
            if f is not None and f == st.get('ended'):              # that game is over (end screen seen)
                if called_over_too_soon(st, f):
                    st['ended'] = None; log('that game is still being recorded, so it was not over: back in it')
                else:
                    f = None
            if f is None:
                if st['last'] is not None:
                    st['was'] = st['last']                 # a pause can look like the end: remember which game it was
                    st['last'] = None; st['first'] = None; st['herd'] = None; watcher.active = False
                    bo['voice_at'] = None                  # nothing more to say until the next game starts
                    tcw.active = False
                    scout.active = False; scout.stop_game(); score_off()
                    title.config(text=HEAD_NAME); idle_size(True)
                    state.config(text='WAITING', fg=MUT)
                    rec_line.config(text=''); rec_line.grid_remove(); show_footer(True)
                    stats_btn.grid()
                    show_opponents([])
            elif f != st['last']:
                try: lob = read_lobby(f)
                except Exception as e_: lob = None; log('could not read the recording: %r' % (e_,))
                fails_ = st.setdefault('read_fail', {})
                if not lob and fails_.get(f, 0) < 6:
                    # often just too early (the file is still empty): try again next tick
                    fails_[f] = fails_.get(f, 0) + 1
                    root.after(POLL_MS, tick); return
                st['last'] = f
                log('game seen: %s, %s' % (os.path.basename(f), ('%d players' % len(lob['players'])) if lob else 'settings unreadable'))
                if lob:
                    name, desc, herd = map_text(maps, strings, lob['selected'], lob['resolved'], lob.get('size'), len(lob['players']))
                    if f == st.get('was'):                 # the same game carrying on (unpaused, or called over too soon)
                        log('back in the same game: counts kept')
                        if not bo['voice_at']: bo['voice_at'] = time.time()
                    else:
                        watcher.reset(); st['extra'] = 0; st['castle_note'] = False; st['feudal_note'] = False
                        if st.get('rolled'): toggle_roll()          # a new game: open up again
                        bo_game_start(f)
                    game_started(f)
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
                    st['watch_t'] = time.time()
                    if mine_p is None: log('you are not in the player list (profile %s), so the in-game alerts stay off' % me)
                    start_scout(lob['players'], mine_p, strings, same_game=(f == st.get('was')), recording=f)
                    scorew.reset(([mine_p['name']] + list(mine)) if mine_p else [],
                                 [p['name'] for p in lob['players'] if p is not mine_p], len(lob['players']),
                                 [p['name'] for p in lob['players'] if mine_p and p is not mine_p
                                  and mine_p.get('team', 0) > 1 and p.get('team') == mine_p.get('team')])
                    scorew.active = mine_p is not None                 # not while watching someone else
                    rec_line.config(text=''); rec_line.grid_remove()   # not while you are playing
                    hide_card()                                       # last game's result is history now
                    close_post_game()                                # never cover a new live match
                    stats_btn.grid_remove()
        except Exception as e:
            body.config(text='Could not read the game settings: %s' % e)
        root.after(POLL_MS, tick)
    bo['name'] = load_settings().get('build_order') or None
    bo['hidden'] = bool(load_settings().get('build_order_hidden'))
    bo['voice'] = bool(load_settings().get('build_voice')); bo_voice_draw()

    bo_draw()                                     # after foot_fit exists, so the card can resize

    tick(); fast(); root.mainloop()

if __name__ == '__main__':
    main()
