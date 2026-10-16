# Why the Wingman pull requests exist

This is a reviewer handoff for Claude and other maintainers. It explains intent rather than asking anyone to merge code just because it exists.

## PR #1 — Opponent intelligence foundation (merged into dev)
https://github.com/Ashley-Pettit/aoe2-wingman/pull/1

**Purpose:** Add a small, independently testable helper that summarizes an opponent's *historical public matches*: common opening, frequency, and typical Feudal/Castle timings.

**Player value:** More actionable pre-game scouting without pretending to know the opponent's hidden, current-game actions.

**Integration status:** The PR originally only added the calculation module and tests; v113 subsequently wired scouting information into the Wingman opponent UI. This is not an endorsement of prediction accuracy.

**Claude review requests:** Check whether the fallback logic duplicates the module; verify civ filtering, sample size, timing calculations, and UI behavior when match history is missing or sparse. Label predictions clearly as historical estimates. Test live-game UI separately.

## PR #3 — Player-friendly download website (merged into dev)
https://github.com/Ashley-Pettit/aoe2-wingman/pull/3

**Purpose:** Give nontechnical players a simple landing page, screenshot and obvious Windows/Python download choices.

**Player value:** Easier onboarding; people should not have to understand GitHub source files to run Wingman.

**Integration status:** The site HTML and GitHub Pages deployment workflow were merged into dev. This does **not** prove that GitHub Pages is enabled/live, nor that a release EXE exists.

**Claude review requests:** Confirm Pages deployment/URL, screenshots, release links and accessibility. Keep documentation honest when a Windows release asset is unavailable.

## PR #4 — Publish EXE in GitHub Releases (closed, NOT merged)
https://github.com/Ashley-Pettit/aoe2-wingman/pull/4

**Purpose:** Package Wingman.exe for nontechnical users, run the Windows startup smoke check, then attach the EXE to a GitHub Release.

**Player value:** Download and double-click instead of installing Python.

**Status / caveats:** This PR was closed without merging. The existing dev Windows workflow already builds an Actions artifact; that is not the same as a GitHub Release download. The EXE is unsigned, so Windows SmartScreen warns on first run (More info > Run anyway). Note: a tag push runs the workflow file in the tagged commit, so a release workflow on dev does trigger for `exe-*` tags; only scheduled and manual-dispatch-from-the-UI runs need the default branch.

**Claude review requests:** Reassess whether another publishing workflow is needed before reviving this idea. Avoid two competing EXE pipelines. Confirm smoke tests cover meaningful startup behavior and ensure clear Windows security guidance.

## Where this landed (v115)

- **One EXE pipeline:** the existing dev `windows-executable.yml` builds, smoke tests and, on an `exe-*` tag, attaches `Wingman.exe` and `AoE2 Wingman.bat` to a GitHub Release. `Release-Exe.cmd` pushes that tag. PR #4's separate workflow was not needed.
- **In the app:** Settings has an Update card (your version, exe or .bat, newest release), a one-click "Get the newest Wingman.exe" that swaps the exe in place, and a "Share with mates" button that copies the download page link. The bar shows a click-to-update line when a newer release is out.
- **Both launch methods kept:** the .bat still updates from Prod or dev.
- **Still to switch on:** GitHub Pages (Settings > Pages > Source: GitHub Actions) and the first `exe-*` release.

## Practical review guidance

1. **Avoid duplication.** Keep existing working Wingman behavior; prefer reusing current helpers and packaging automation over parallel implementations.
2. **Separate concerns.** Opponent scouting is a player feature; site/EXE work is distribution infrastructure. Do not interpret backend tests as proof the UI works in a real match.
3. **Test before Prod.** Verify the Windows app starts, the scouting panel renders with realistic sample history, and links lead to actual artifacts.
4. **Preserve both launch methods.** The EXE should be optional; the existing .bat/Python path should remain available.
5. **No automatic merge request.** Claude and Ashley decide whether each change is worthwhile.

Authorship: Ashley Pettit, assisted by OpenAI ChatGPT. This document explains prior PR intent; it is not a new player feature.
