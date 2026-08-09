# glemy-games

Reference games — Tiers, Breakout, Platformer — built on
[glemy](https://github.com/recregt/glemy), a Gleam physics/game engine.
Each game has its own HTML entry point (`index.html`, `breakout.html`,
`platformer.html`) and compiles for both the Erlang and JavaScript
targets.

See `ARCHITECTURE.md` for how this repo is organized and how it relates
to glemy, and `CLAUDE.md` for the standing verification checklist.

## Running a game locally

```sh
gleam deps download
gleam build --target javascript
deno run --allow-net --allow-read jsr:@std/http/file-server .
```

Then open `index.html` / `breakout.html` / `platformer.html` in a
browser.

## Testing

```sh
gleam test               # Erlang target
gleam test --target javascript
deno task check-warnings
deno task browser-check            # Tiers
deno task browser-check-breakout
deno task browser-check-platformer
```
