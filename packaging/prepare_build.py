"""Extract the Python portion of Wingman's batch/Python hybrid for PyInstaller.

The frozen edition deliberately disables the script self-updater, since it
is designed to download and replace a .bat file, not a running executable.
"""
import ast
from pathlib import Path

root = Path(__file__).resolve().parents[1]
source = (root / "AoE2 Wingman.bat").read_text(encoding="utf-8-sig")
lines = source.splitlines(keepends=True)
if not lines or not lines[0].startswith("@("):
    raise SystemExit("Unexpected Wingman batch/Python launcher format")
body = "".join(lines[1:])
needle = "def update_from_github(branch, me_=None, running=None):\n"
if body.count(needle) != 1:
    raise SystemExit("Updater signature changed: review frozen app safety")
body = body.replace(
    needle,
    needle + "    if getattr(sys, 'frozen', False):\n"
             + "        return False, 'Use the latest executable release to update this edition.', None\n",
    1,
)
ast.parse(body)
out = root / "build" / "wingman_frozen.py"
out.parent.mkdir(exist_ok=True)
out.write_text(body, encoding="utf-8")
print(f"Extracted and compiled {out}")
