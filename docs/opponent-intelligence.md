# Opponent intelligence (initial module)

This is a **standalone foundation**, not yet wired into the Wingman UI.

`opponent_intelligence.py` takes previously labelled, public match-history
records and returns the most common opening, its observed sample frequency, and
median Feudal/Castle timing. It does not fetch match history, parse replays, or
read hidden live-game state. Frequencies are descriptive, not probabilities.

Example:

```python
from opponent_intelligence import predict_opening, format_brief

games = [
    {"opening": "Scouts", "civ": "Franks", "map": "Arabia", "feudal_seconds": 590},
    {"opening": "Scouts", "civ": "Franks", "map": "Arabia", "feudal_seconds": 610},
    {"opening": "Archers", "civ": "Franks", "map": "Arabia", "feudal_seconds": 620},
]
print(format_brief(predict_opening(games, civ="Franks", map_name="Arabia")))
```

Run unit tests from the repository root:

```sh
python -m unittest discover -s tests
```

Next integration: adapt Wingman's existing recent-opponent-opening data into
these records and render a brief in the opponent panel. Do not merge as a
finished user-facing feature until that integration is verified on Windows.
