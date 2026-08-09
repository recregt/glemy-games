//// Tiers' game runner.
////
//// JavaScript-target only (like `io`, `render`): owns the actual
//// `requestAnimationFrame` loop and glues `io` → `glemy/games/tiers` →
//// `render` together each frame, per the game-loop architecture in
//// docs/development-plan.jsonl (RM-004). Split deliberately in two, by
//// testability: `tick_and_render` is the actual per-frame logic (spawn,
//// physics, render/present) and is fully covered by `gleam test
//// --target javascript` — using a real `OffscreenCanvas` and Deno's
//// native `"webgpu"` context, no browser or third-party automation
//// library needed (see `game_tiers_test.gleam`, decision 0015 in
//// docs/decisions.jsonl). `loop`/`start` are the thin
//// `requestAnimationFrame` scheduling wrapper around it — this part
//// stays genuinely untestable under Deno (no native RAF), but there's
//// very little logic left in it to get wrong.
////
//// This is glemy's reference-game runner for Tiers specifically, not a
//// core module (see `glemy/games/tiers`'s own doc comment, decision
//// 0047). A second game gets its own runner shaped like this one,
//// gluing `io`/`render` to its own tick function -- `glemy/game_breakout`
//// is the current example (decision 0051): both share the genuinely
//// generic `game_ffi.mjs` (`requestFrame`, canvas-layout FFI), while each
//// keeps its own game-specific DOM/sound writes in its own `<game>_ffi.mjs`.

import gleam/float
import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{type Option, None, Some}
import glemy_games/games/tiers.{type Model}
import glemy_games/games/tiers/rules
import glemy/io
import glemy/physics
import glemy/physics/bounds.{Bounds}
import glemy/physics/entity.{Entity}
import glemy/physics/vector2.{Vector2}
import glemy/render.{type Canvas}

/// Formats `score` for the on-page score display. Pure and
/// target-agnostic (not `@target(javascript)`, unlike the rest of this
/// module) even though only the JS-only `loop` below ever actually
/// calls it -- plain string formatting has no target-specific need,
/// and keeping it untagged means it's covered by `gleam test` on both
/// targets rather than JavaScript alone.
/// ```gleam
/// format_score(1234)
/// // -> "Score: 1234"
/// ```
pub fn format_score(score: Int) -> String {
  "Score: " <> int.to_string(score)
}

@target(javascript)
@external(javascript, "./game_ffi.mjs", "requestFrame")
fn request_frame(callback: fn(Float) -> Nil) -> Nil

@target(javascript)
/// The canvas's `getBoundingClientRect().left`/`.width`, in the same
/// viewport-relative CSS-pixel space as `io.mouse_position()` — needed
/// to convert a click into a canvas-local, then world-space, x
/// coordinate (`bounds.x_from_canvas_pixel`). See `loop` below.
@external(javascript, "./game_ffi.mjs", "canvasBoundingRectLeftAndWidth")
fn canvas_bounding_rect_left_and_width(canvas: Canvas) -> #(Float, Float)

@target(javascript)
/// Sets `index.html`'s `#glemy-score` element's text directly to
/// `text` — a non-branching DOM write, the one kind of FFI logic
/// decision 0016 accepts without needing to be pushed into Gleam
/// (there's no `text` *computation* here to move; `format_score` above
/// already did that part).
@external(javascript, "./game_tiers_ffi.mjs", "setScoreText")
fn set_score_text(text: String) -> Nil

@target(javascript)
@external(javascript, "./game_ffi.mjs", "setElementVisibilityMessage")
fn set_element_visibility_message(
  element_id: String,
  visible: Bool,
  message: String,
) -> Nil

@target(javascript)
/// Sets `index.html`'s `#glemy-game-over` element's text to `message`
/// and its visibility to `visible` — same non-branching-DOM-write
/// reasoning as `set_score_text`. A thin wrapper over the shared
/// `set_element_visibility_message` (decision 0063) so every existing
/// call site keeps this game's own name/2-argument shape.
fn set_game_over(visible: Bool, message: String) -> Nil {
  set_element_visibility_message("glemy-game-over", visible, message)
}

@target(javascript)
/// Positions `index.html`'s `#glemy-danger-line` overlay at
/// `fraction_from_top` (a `0.0`-`1.0` CSS `top` percentage, already
/// fully computed on the Gleam side by
/// `bounds.y_fraction_from_top(tiers.danger_line_y(bounds), bounds)`) --
/// same non-branching-DOM-write reasoning as `set_score_text`. Called
/// once at startup (see `main`), not every frame, since the danger
/// line's world-y never changes for the life of a running game.
@external(javascript, "./game_tiers_ffi.mjs", "setDangerLinePosition")
fn set_danger_line_position(fraction_from_top: Float) -> Nil

@target(javascript)
/// Sets `index.html`'s `#glemy-next-tier` swatch's background color to
/// `css` (already a fully-formed CSS color string --
/// `rules.color_css(model.next_tier)`) — same non-branching-DOM-write
/// reasoning as `set_score_text`. Called every frame like
/// `set_score_text`/`set_game_over` (unlike `set_danger_line_position`,
/// which is startup-only): `next_tier` changes over the game's
/// lifetime, every time a drop happens.
@external(javascript, "./game_tiers_ffi.mjs", "setNextTierColor")
fn set_next_tier_color(css: String) -> Nil

@target(javascript)
/// Plays a short, synthesized (no audio files -- see `game_ffi.mjs`)
/// blip for a piece landing (`tiers.Dropped`).
@external(javascript, "./game_tiers_ffi.mjs", "playDropSound")
fn play_drop_sound() -> Nil

@target(javascript)
/// Plays a short, synthesized blip for a successful merge (`tiers.Merged`).
@external(javascript, "./game_tiers_ffi.mjs", "playMergeSound")
fn play_merge_sound() -> Nil

@target(javascript)
/// Briefly flashes `index.html`'s `#glemy-canvas-wrap` for
/// `tiers.Merged` -- a real, honest visual "pop" for a merge without
/// needing the collision sweep to expose merge *positions* (which a
/// per-merge particle burst would need, a larger change than this
/// visual feedback's value justifies on its own -- see decision 0036).
@external(javascript, "./game_tiers_ffi.mjs", "triggerMergeFlash")
fn trigger_merge_flash() -> Nil

@target(javascript)
/// Plays/shows whichever feedback `event` calls for -- the one place
/// `tiers.GameEvent` gets translated into actual FFI calls, matching
/// `glemy/games/tiers` having no concept of audio or DOM effects itself
/// (see that type's own doc comment). Only ever called from `loop`'s
/// per-frame sweep over the events `tick_and_render` returns, never
/// from `tick_and_render` directly, so `tick_and_render` stays fully
/// `gleam test`-covered without needing a real AudioContext/DOM under
/// Deno.
fn play_sound_event(event: tiers.GameEvent) -> Nil {
  case event {
    tiers.Dropped -> play_drop_sound()
    tiers.Merged -> {
      play_merge_sound()
      trigger_merge_flash()
    }
  }
}

@target(javascript)
/// One frame's worth of work: spawns/integrates/collides
/// (`tiers.tick`), then renders the result directly onto `canvas`'s own
/// WebGPU context (`render.render_entities_to_canvas` — GPU-resident
/// presentation, no CPU roundtrip). Returns the new `Model` and this
/// frame's `GameEvent`s regardless of whether rendering succeeded,
/// alongside the render `Result`, so a caller can choose to keep
/// simulating even through a dropped frame (which is exactly what
/// `loop` below does) while still letting tests inspect the physics
/// outcome, what happened, and the rendered pixels.
///
/// Renders `tiers.preview_entity(next_model)` alongside the real
/// entities (unless the game has ended -- nothing more is ever going to
/// drop): the hovering next-piece preview every real Suika-style game
/// shows, so a player can see where a piece will land before committing
/// to the drop, not just after.
pub fn tick_and_render(
  model: Model,
  dt: Float,
  input: tiers.Input,
  canvas: Canvas,
) -> Promise(#(Model, List(tiers.GameEvent), Result(List(Int), String))) {
  let #(next_model, events) = tiers.tick(model, dt, input)
  let entities_to_render = case next_model.game_over {
    True -> next_model.physics.entities
    False -> [tiers.preview_entity(next_model), ..next_model.physics.entities]
  }
  render.render_entities_to_canvas(
    tiers.colored_entities(entities_to_render),
    next_model.physics.bounds,
    canvas,
  )
  |> promise.map(fn(result) { #(next_model, events, result) })
}

@target(javascript)
/// Starts the loop from `initial_model`, presenting each frame onto
/// `canvas`. Never returns in any observable sense — each frame
/// re-schedules the next one via `requestAnimationFrame` once its
/// render finishes, for as long as the page stays open.
pub fn start(initial_model: Model, canvas: Canvas) -> Nil {
  loop(initial_model, canvas, None)
}

@target(javascript)
fn loop(
  model: Model,
  canvas: Canvas,
  previous_timestamp: Option(Float),
) -> Nil {
  request_frame(fn(timestamp) {
    let dt = case previous_timestamp {
      // First frame: no prior timestamp to diff against, so nothing has
      // moved yet — matches `entity.integrate`'s already-tested `dt =
      // 0.0` no-op behaviour, rather than guessing a fake first delta.
      None -> 0.0
      Some(previous) -> { timestamp -. previous } /. 1000.0
    }
    // The cursor's x is converted from a raw viewport pixel (`clientX`)
    // into world-space via the canvas's real on-page position/size --
    // tracked every frame (not just while the mouse is held) since the
    // drop preview needs to follow the cursor even before a drop is
    // requested.
    let click = io.mouse_position()
    let #(rect_left, rect_width) = canvas_bounding_rect_left_and_width(canvas)
    let cursor_x =
      bounds.x_from_canvas_pixel(
        click.x -. rect_left,
        rect_width,
        model.physics.bounds,
      )
    let input =
      tiers.Input(
        cursor_x: cursor_x,
        drop_requested: io.is_mouse_button_down(0),
        next_tier_random: float.random(),
      )
    tick_and_render(model, dt, input, canvas)
    |> promise.map(fn(triple) {
      let #(next_model, events, _render_result) = triple
      set_score_text(format_score(next_model.score))
      set_game_over(next_model.game_over, "Game Over!")
      set_next_tier_color(rules.color_css(next_model.next_tier))
      list.each(events, play_sound_event)
      loop(next_model, canvas, Some(timestamp))
    })
    Nil
  })
}

@target(javascript)
/// A concrete, ready-to-run scene: a handful of entities inside a bounded
/// box, falling under gravity, colliding with each other and the walls.
/// Click (and hold) anywhere on the canvas to spawn more. `index.html`
/// calls this directly; `start` above stays a reusable, scene-agnostic
/// entry point for any other initial `Model`.
pub fn main() -> Nil {
  let bounds = Bounds(min: vector2.zero, max: Vector2(100.0, 100.0))
  // Well above real-world gravity -- an abstract-unit box, not physical
  // accuracy (nothing here claims "1 unit = 1 metre"). Raised from -98.0
  // (decision 0029, ~1.7s full-height fall) to -250.0 after a direct user
  // report that the descent still felt too slow -- combined with
  // entity.velocity_damping's own increase (0.98 -> 0.997, see that
  // constant's doc comment), the real measured full-height fall time
  // dropped to well under a second. See decision 0032.
  let gravity = Vector2(0.0, -250.0)
  let entities = [
    Entity(
      resting_time: 0.0,
      position: Vector2(30.0, 80.0),
      velocity: vector2.zero,
      radius: 5.0,
      kind: 0,
    ),
    Entity(
      resting_time: 0.0,
      position: Vector2(50.0, 60.0),
      velocity: vector2.zero,
      radius: 8.0,
      kind: 0,
    ),
    Entity(
      resting_time: 0.0,
      position: Vector2(70.0, 85.0),
      velocity: vector2.zero,
      radius: 4.0,
      kind: 0,
    ),
  ]
  let canvas = render.get_canvas("glemy-canvas")
  let initial_model =
    tiers.Model(
      danger_timer: 0.0,
      game_over: False,
      physics: physics.Model(entities: entities, bounds: bounds, gravity: gravity),
      score: 0,
      current_tier: 0,
      // Fixed, not randomized: main()'s starting Model is constructed
      // before the first real frame has run, so there's no `float.random()`
      // call to reach for yet (the drop mechanic's own randomness only
      // kicks in from `loop`'s per-frame Input onward) -- an arbitrary
      // but reasonable, low starting tier is fine either way.
      next_tier: 1,
      // Bounds' own x-midpoint -- as good a starting guess as any before
      // the first real frame reports where the cursor actually is.
      preview_x: 50.0,
      cooldown_remaining: 0.0,
    )
  set_danger_line_position(bounds.y_fraction_from_top(
    tiers.danger_line_y(bounds),
    bounds,
  ))
  // Also set once here, not just every frame inside `loop` -- otherwise
  // the swatch would show as empty/unstyled until the very first frame
  // finishes rendering.
  set_next_tier_color(rules.color_css(initial_model.next_tier))
  start(initial_model, canvas)
}
