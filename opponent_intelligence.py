"""Historical opponent tendencies using public matches only.

These frequencies describe past games and never reveal hidden live-game actions.
"""
from collections import Counter
from dataclasses import dataclass
from statistics import median


@dataclass(frozen=True)
class OpeningPrediction:
    opening: str
    observed: int
    matches: int
    feudal_seconds: int | None
    castle_seconds: int | None


def predict_opening(matches, civ=None, map_name=None, min_samples=3):
    """Summarise match dictionaries: opening, civ, map, feudal_seconds, castle_seconds.

    Prefer matching civ/map only when the sample remains large enough.
    Returns None for insufficient labelled history.
    """
    if min_samples < 1:
        raise ValueError("min_samples must be positive")
    rows = list(matches)
    for field, desired in (("civ", civ), ("map", map_name)):
        if desired:
            filtered = [row for row in rows
                        if str(row.get(field, "")).casefold() == desired.casefold()]
            if sum(bool(row.get("opening")) for row in filtered) >= min_samples:
                rows = filtered
    valid = [row for row in rows
             if isinstance(row.get("opening"), str) and row["opening"].strip()]
    if len(valid) < min_samples:
        return None
    counts = Counter(row["opening"].strip().casefold() for row in valid)
    chosen, count = sorted(counts.items(), key=lambda x: (-x[1], x[0]))[0]

    def median_time(key):
        values = [row[key] for row in valid
                  if isinstance(row.get(key), (int, float))
                  and not isinstance(row[key], bool) and row[key] > 0]
        return int(median(values)) if values else None

    return OpeningPrediction(
        opening=next(row["opening"].strip() for row in valid
                     if row["opening"].strip().casefold() == chosen),
        observed=count,
        matches=len(valid),
        feudal_seconds=median_time("feudal_seconds"),
        castle_seconds=median_time("castle_seconds"),
    )


def format_brief(prediction):
    """Return a compact, clearly historical overlay label."""
    if prediction is None:
        return "Opponent opening: insufficient public history"
    label = f"Past openings: {prediction.opening} ({prediction.observed}/{prediction.matches})"
    for name, seconds in (("Feudal", prediction.feudal_seconds),
                          ("Castle", prediction.castle_seconds)):
        if seconds is not None:
            minutes, remainder = divmod(seconds, 60)
            label += f" | {name} ~{minutes}:{remainder:02d}"
    return label
