# Wingman — player-facing feature roadmap and UI acceptance criteria

**For Claude, Ashley and future contributors.** The intention is to make Wingman more useful *inside an actual match*, not merely add backend modules. A feature is **not done** until its visible placement, interaction, empty state and Windows behavior are tested.

## Existing UI contract (dev v117)

Wingman is a compact Tkinter always-on-top overlay, not a full-screen dashboard. Reuse its current visual language: dark `BG`/`PANEL`, bronze/gold text highlights, green action hints, red urgent alerts, tiny icons via `draw_icon`, folding opponent rows, settings cog, build-order strip and W/L record view.

**Do not add eight permanent panels.** Put information where a player already looks:
- **Opponent row (expanded):** enemy civ/rating; unique-unit counter; historical scouting line; brief actionable advice. Preserve the existing click-to-fold behavior.
- **Build strip:** one actionable build-order step at a time, keyed off population; contextual coaching can be a brief second line.
- **Alert area:** urgent information only, concise and dismissible/suppressible.
- **Between games / W/L window:** analysis, training goals and historical trends.
- **Settings:** opt-in voice features, coaching frequency, alert preferences and privacy/help.

Existing `show_opponents` renders `scouting_report` (a historical opening bar, age-up timing/countdowns and `opening_answer` recommendation) in the expanded row. `uu_counter` already lists unique-unit counters. Build-order strip, idle TC and housing alerts exist. **Extend these; do not introduce competing copies.**

### Illustrative UI sketches — not screenshots or proof of implementation

**A. Existing opponent panel, enhanced in place (approximate layout):**
```text
┌────────────── WINGMAN ──────────────┐
│ Arabia                  12:34       │
│ Red  MONGOLS            1480 ELO   │
│ Mangudai → Camels · Skirms          │
│ ▰▰▰▰▱  Scouts 6/9 (past games)      │
│ Feudal ~9:05   Castle ~16:40        │
│ 🛡 Prepare spears; protect berries  │
│ [More matchup details ▾]           │
├────────────────────────────────────┤
│ BUILD 19 pop: Loom → click Feudal   │
└────────────────────────────────────┘
```
When folded, leave **only** the existing compact opponent header/chips. Do not show a “67% chance” without a sufficient and well-labeled history sample. The “prepare spears” line is an example, not a universal Mongols counter.

**B. Urgent nudge uses existing alert mechanism, not a chat transcript:**
```text
│ ⚠ Town Center idle — queue villager │
```
Only one highest-priority actionable alert should dominate at a time; a player must be able to reduce/disable guidance in Settings.

**C. Post-game / W-L expansion:**
```text
YOUR LAST MATCH — Arabia · 34:12
✓ Castle timing improved vs recent games
! TC idle periods: review at 08:20–09:15
Next goal: keep TC producing through Feudal
[Review evidence] [Dismiss]
```
Only show metrics supported by actually collected match data; unavailable metrics should read “Not tracked,” not fabricated values.

## Eight features

### 1. Historical opponent strategy prediction — integrated, needs validation
**Why:** Know an opponent’s *observed past habits* early enough to prepare, without implying access to fog-of-war or hidden actions.

**In-app placement:** existing expanded opponent row, alongside the scouting report and current actionable `opening_answer`.

**Player experience:** “Scouts 6/9 past games” plus other opening breakdown behind an optional expansion; a concise relevant preparation hint.

**Acceptance:**
- Shows sample size and historical wording; insufficient history shows “Not enough recent games” or existing fallback, never an invented forecast.
- Correctly handles opponent civ filtering versus whole-player history; explains if the sample is pooled.
- No duplicate prediction lines or width overflow around the existing ~400px opponent row; folded state remains compact.
- Tests for missing data, ties, late arrival of API results, multiple opponents and stale history.

### 2. Civilization-aware unit counter assistant — partially implemented
**Why:** Players need **a counter they can actually produce**, not simply the generic ideal counter.

**In-app placement:** retain the existing unique-unit counter `uu_counter` row; allow click to expand alternatives with explanations.

**Player experience:** “Mangudai → Camels / Skirms (your civ has both)” or “No camels available → Skirms + positioning.” Add age and required upgrades when material.

**Acceptance:**
- Picks only units available to the *player's* civ and current age; tech-tree data is verified and sources kept traceable.
- Distinguishes soft from hard counters and avoids claiming reliable counter matchups with weak evidence.
- Works without live enemy unit detection by framing the advice conditionally: “If they make Mangudai…”
- Compact default display; no new fixed panel; tests across civs with and without camels/knights.

### 3. Opponent age-up predictions — Feudal/Castle integrated, needs testing
**Why:** Historical timings can help a player decide when to scout or prepare defenses.

**In-app placement:** current scouting report’s Feudal/Castle label beside opponent history; existing amber/red emphasis.

**Player experience:** “Castle historically ~16:40” then “~1:00 until typical Castle timing.”

**Acceptance:**
- Describes past median timing, not knowledge of opponent’s live age; no certainty language or unsupported Imperial claim.
- Missing age-up time omits that label instead of inventing a number.
- Countdown tied correctly to in-game clock, with resets at game end; avoid permanently red “overdue” states.
- No repetitive notifications at each refresh; mock clock tests and Windows game test.

### 4. Adaptive coaching alerts — partially implemented
**Why:** Useful reminders should help decision-making without interrupting micro.

**In-app placement:** current idle-TC / house / age-building alert area, plus one-line build strip; controls in Settings.

**Player experience:** “You're about to be housed; start a house,” not five simultaneous flashing alerts.

**Acceptance:**
- Alert priorities, cooldowns, debouncing and explicit user enable/disable controls.
- No claim a technology is missing unless actually detectable; otherwise frame as a check, e.g. “Consider Double-Bit Axe.”
- Advice changes with phase of game where reliable, but never hijacks focus/clicks.
- Validate false-positive rate, cooldown and interaction while playing.

### 5. Post-game coach — missing as an evidence-based review
**Why:** Turn match logs into a few practical things to improve next match.

**In-app placement:** new **Review** subsection inside existing W/L record window, not another in-game floating overlay.

**Player experience:** 2–3 actionable findings, timestamps and “why this matters,” grounded in recorded data.

**Acceptance:**
- Works only from data actually available (public post-match events / legitimately captured on-screen data / consented logs).
- Explicit “Not tracked” rather than estimating TC idle or upgrades without reliable measurements.
- Links findings to observed events and supports a “next goal.”
- Privacy-respecting local retention, opt-in data sharing if ever proposed; no fabricated coaching narrative.

### 6. Map-specific strategy advisor — partially implemented
**Why:** The best opening and scouting priority depend on map, civs and available resources.

**In-app placement:** existing map section at game start + current build-order picker; do not create a map sidebar.

**Player experience:** on Arabia: “Open map; scout early; consider Scouts or Archers” with appropriate civ/matchup qualifier.

**Acceptance:**
- Starts with factual map resources from existing map metadata; map-specific advice grounded and distinguished from facts.
- Recommends only viable builds and supports switching manually.
- No forced strategy or auto-switching; one short line by default, expansion for rationale.
- Test representative open, closed, water and nomad maps; graceful fallback for new/custom maps.

### 7. Voice-controlled Wingman — not implemented as Q&A
**Why:** Hands-free queries can help while the player is microing.

**In-app placement:** optional mic icon in existing top bar and an opt-in Settings section; no large chat window.

**Player experience:** push-to-talk “What counters Mangudai?” → short spoken answer + small caption; no need to leave game.

**Acceptance:**
- Never listens continuously by default; obvious enabled/listening state, push-to-talk or equivalent.
- Clear distinction from existing *outbound* spoken “Red found” alerts; those are not voice Q&A.
- Fast timeout, mute/cancel, graceful offline fallback; avoid capturing private Discord audio inadvertently.
- Only answer source-backed game questions. Request permission before any external speech service or audio upload.

### 8. Personalized training goals — not implemented as feedback loop
**Why:** A player needs measurable improvement, not merely a W/L statistic.

**In-app placement:** existing W/L screen’s trends area and a tiny next-match reminder optionally in waiting state.

**Player experience:** “Goal: avoid early housed time in 3 of next 5 games,” with a progress indicator only if housed time is actually tracked.

**Acceptance:**
- Goals tied to available measurements and previous performance; no false precision.
- One active goal by default; reset/change/dismiss controls.
- Visible trend over recent matches and clear indication of missing data.
- No cloud account or complex AI infrastructure required for an initial local implementation.

## Delivery approach for Claude

**Order:** (1) verify existing scouting UI + data; (2) expand unit counters using existing row; (3) improve alert relevance; (4) map-aware advice; then (5) evidence-backed post-game review and (8) training; (7) optional voice Q&A last due to permissions and implementation complexity.

**Definition of done for every new gameplay PR:**
1. Rationale and precise player problem.
2. **Frontend design within the current Tk overlay**: exact existing widget/placement; default, expanded, folded, loading, missing-data and error states; approx. 400px layout constraint.
3. Data source, provenance and honest uncertainty labels.
4. Unit tests **plus visible UI smoke test** and at least one practical AoE2 match check before Prod.
5. No unnecessary duplicate feature, no layout crowding, no noisy new notification stream.
6. PR conversation comment beginning **“Claude, please read”** with why it matters, tests and concerns.

**Authorship:** Product vision guided by Ashley Pettit; documentation prepared with OpenAI ChatGPT assistance. This is a *roadmap documentation change only*; no gameplay code is modified.
