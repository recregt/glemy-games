# Working in glemy-games

Read `ARCHITECTURE.md` before adding or moving any code — it's the
current-state map of where things go and why, and how this repo relates
to [glemy](https://github.com/recregt/glemy) (the engine it depends on).
`docs/decisions.jsonl` (schema in glemy's `docs/decisions.md`) is this
repo's own append-only decision history, starting fresh from the split
from glemy — see glemy's own `docs/decisions.jsonl` for everything
before that point. Log a new decision via glemy's `tools/decisions`
CLI, pointed at this repo's own log file, whenever you make a real
architectural call, not just a mechanical change.

## Before declaring any task finished

1. **Run `gleam build` and `gleam test` on both targets**
   (`gleam test`, `gleam test --target javascript`) — both must be
   green. This transitively builds glemy too, via the git dependency —
   a failure here can mean either repo.
2. **Run the warnings gate**: `deno task check-warnings`. It must
   `PASS`. If it fails, don't reach for `--update` as a way to make the
   failure go away — investigate first. A genuinely new warning is
   either a real bug (fix it) or a confirmed target-gating artifact
   (see glemy's `ARCHITECTURE.md` "Compiler warnings" section for the
   full reasoning; only then, `--update` the baseline, and say so in
   your summary — never fix that silently).
3. If the change touches a `game_<name>.gleam` runner, WebGPU
   rendering, or real-browser behavior, run the matching
   `deno task browser-check-<name>` too — `gleam test` alone can't
   verify a real `requestAnimationFrame` loop or real click
   coordinates.
4. Remove any diagnostic/scratch test code before finishing — this
   project keeps `gleam test` free of throwaway debug scaffolding.

None of this is optional or a "nice to have" — a task isn't done until
all four pass, every time, not just for large changes.
