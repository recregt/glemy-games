# glemy-games — Architecture

This repository holds the reference games (Tiers, Breakout, Platformer)
built on top of [glemy](https://github.com/recregt/glemy), the
physics/game engine they share. It was split out of glemy itself once a
third, genre-distinct game (Platformer) made the engine/game boundary a
real package boundary worth enforcing, not just a folder convention —
see glemy's own `docs/technical-architecture.md` §2.3 (the extraction
trigger this split executes) and `docs/decisions.jsonl` for the split
decision itself.

glemy is consumed here as a normal Gleam dependency (`gleam.toml`'s
`[dependencies]` — currently a git dependency pinned to a specific
commit SHA, not yet a Hex dependency; see glemy's own
`docs/decisions.jsonl` for when/whether that changes). Every import of
`glemy/physics`, `glemy/render`, `glemy/io`, etc. resolves there.
Everything under `glemy_games/` in this repo's own `src/`/`test/` trees
is genre-specific game code that glemy itself deliberately has no
knowledge of.

## Where new code goes

This repo inherits glemy's Functional-Core/Imperative-Shell split
one level up, applied entirely within game code (glemy's own Core —
`physics`, `render`, `io` — is out of scope here; changes to *that*
belong in glemy's own repository, following glemy's own
`ARCHITECTURE.md`):

1. **A specific game's own rules, state, or per-frame `tick`** (tier
   progression, scoring, a drop cooldown, a win/lose condition) →
   `src/glemy_games/games/<name>.gleam` (that game's own `Model`, which
   wraps glemy's `physics.Model` as a field or holds its own bare
   `Entity` depending on the game's shape — see glemy's `physics.update`
   doc comment for why that split exists), or a pure module under
   `src/glemy_games/games/<name>/` for a self-contained sub-concept of
   that game specifically (e.g. `games/tiers/rules.gleam`:
   tier radii/color/score/merge rules; `games/breakout/brick.gleam`/
   `paddle.gleam`: what a brick/paddle *is* and what happens on a hit).
   Pure, no FFI — a second game gets its own sibling
   `games/<other-name>/` tree, never reaching into another game's own
   tree.
2. **Only possible with a browser API** (DOM events, WebGPU,
   `requestAnimationFrame`, a DOM text write, a synthesized sound) →
   that game's own `game_<name>.gleam` + `game_<name>_ffi.mjs`, or the
   shared `game_ffi.mjs` if every runner needs the exact same thing
   (currently: `requestFrame`, `setElementVisibilityMessage` — promoted
   there only once three games needed byte-identical code, see glemy's
   decision 0063 for the reasoning this repo inherits).
3. **A dev-time tool, not part of the shipped game** (a real-browser
   regression check, the compiler-warnings gate) → `tools/`.

## Testing mirrors source, exactly

`test/glemy_games/<path>` mirrors `src/glemy_games/<path>` file-for-file
— same rule as glemy's own Core/Shell testing convention. A
`*_test_ffi.mjs` alongside a `*_test.gleam` follows the same FFI-
minimality rule as production code.

## The FFI minimality rule

Every `*_ffi.mjs` file here exists only to wrap something Gleam
genuinely cannot express. No branching or game-logic decisions belong
in a `.mjs` file — that decision belongs in Gleam, with the FFI export
shrunk to just the raw capability it needs. Every Gleam-callable JS
export gets wrapped by a real `@external` Gleam function, never called
raw from another `.mjs` file. See glemy's own `ARCHITECTURE.md` "The FFI
minimality rule" section for the full reasoning (decision 0016) — this
repo follows the identical rule, just for game-specific FFI instead of
engine FFI.

## Real-browser checks and the compiler-warnings gate

`tools/browser_check*.ts` (one per game, sharing bootstrap logic via
`tools/browser_check_shared.ts`) and `tools/check_warnings.ts` are this
repo's own copies of the identical tools glemy itself uses, checking
this repo's own code and its own `tools/testdata/expected_warnings.json`
baseline — see glemy's `ARCHITECTURE.md` "DevOps tooling organization"
and "Compiler warnings" sections for why each exists and how to use
them; the reasoning is identical here, only the target code differs.

## Adding a new game

1. `src/glemy_games/games/<name>.gleam` (+ any `games/<name>/`
   sub-modules) — pure rules/state/tick, built on glemy's `physics`/
   `physics/*`.
2. `src/glemy_games/game_<name>.gleam` + `game_<name>_ffi.mjs` — the
   Shell runner: the real `requestAnimationFrame` loop, wiring `io` →
   `games/<name>` → `render` together each frame.
3. `<name>.html` at the repo root — the entry point, importing
   `./build/dev/javascript/glemy/glemy/render.mjs` (the engine,
   unchanged) and `./build/dev/javascript/glemy_games/glemy_games/game_<name>.mjs`
   (this repo's own compiled output).
4. `test/glemy_games/games/<name>_test.gleam` + `test/glemy_games/game_<name>_test.gleam`
   mirroring the source tree exactly.
5. `tools/browser_check_<name>.ts`, wired into `deno.json`'s
   `browser-check-<name>` task.

## Bumping the glemy dependency

`gleam.toml`'s `glemy` git dependency is pinned to a specific commit SHA
deliberately, not a branch — bump it as a real, reviewed change (mirrors
glemy-website's own `STABLE_GLEMY_REF` "deliberate promotion" precedent)
whenever this repo wants to pick up an engine change, never silently or
automatically.
