//// Breakout's game runner.
////
//// JavaScript-target only (like `io`, `render`): owns the actual
//// `requestAnimationFrame` loop and glues `io` → `glemy/games/breakout` →
//// `render` together each frame -- same split, same testability
//// reasoning as `glemy/game_tiers` (see that module's own doc comment).
//// Only the ball renders via the real WebGPU pipeline
//// (`render.render_entities_to_canvas`); the paddle and bricks aren't
//// `physics` entities (decision 0052), so they're positioned as CSS
//// overlay elements from `game_breakout_ffi.mjs` instead -- the same
//// category of technique `game_tiers_ffi.mjs`'s `setDangerLinePosition`
//// already uses for its own overlay, just applied every frame (the
//// paddle) and event-driven (bricks) instead of once at startup.

import gleam/int
import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{type Option, None, Some}
import glemy_games/games/breakout.{type Model}
import glemy/io
import glemy/physics/bounds.{Bounds}
import glemy/physics/rect
import glemy/physics/vector2.{Vector2}
import glemy/render.{type Canvas}

/// Formats `score` for the on-page score display. Pure and
/// target-agnostic, matching `glemy/game_tiers.format_score`'s own
/// reasoning for staying untagged.
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
/// Sets `breakout.html`'s `#glemy-score` element's text directly to
/// `text` -- same non-branching-DOM-write reasoning as
/// `game_tiers_ffi.mjs`'s `setScoreText`.
@external(javascript, "./game_breakout_ffi.mjs", "setScoreText")
fn set_score_text(text: String) -> Nil

@target(javascript)
@external(javascript, "./game_ffi.mjs", "setElementVisibilityMessage")
fn set_element_visibility_message(
  element_id: String,
  visible: Bool,
  message: String,
) -> Nil

@target(javascript)
/// Sets `breakout.html`'s `#glemy-status` element's text to `message`
/// and its visibility to `visible` -- covers both `Won` and `Lost`
/// (the caller decides `message`), same non-branching-DOM-write
/// reasoning as `set_score_text`. A thin wrapper over the shared
/// `set_element_visibility_message` (decision 0063) so every existing
/// call site keeps this game's own name/2-argument shape.
fn set_status_message(visible: Bool, message: String) -> Nil {
  set_element_visibility_message("glemy-status", visible, message)
}

@target(javascript)
/// Positions `breakout.html`'s `#glemy-paddle` overlay element at the
/// CSS box `rect.to_css` computes -- called every frame, since the
/// paddle moves every frame `move_left`/`move_right` is held.
@external(javascript, "./game_breakout_ffi.mjs", "setPaddleBox")
fn set_paddle_box(left: Float, top: Float, width: Float, height: Float) -> Nil

@target(javascript)
/// Creates one `<div>` per brick inside `breakout.html`'s
/// `#glemy-bricks`, keyed by each brick's own stable `id` -- called once
/// at startup (see `main`), not every frame: bricks are static, only
/// destroyed (see `hide_brick_element`), never moved or added.
@external(javascript, "./game_breakout_ffi.mjs", "createBrickElements")
fn create_brick_elements(
  bricks: List(#(Int, Float, Float, Float, Float)),
) -> Nil

@target(javascript)
/// Hides the one brick `<div>` keyed by `id` -- see
/// `glemy/games/breakout.Brick`'s own doc comment for why `id`, not a
/// list position, is the safe key here.
@external(javascript, "./game_breakout_ffi.mjs", "hideBrickElement")
fn hide_brick_element(id: Int) -> Nil

@target(javascript)
/// A short blip for the ball bouncing off a wall or the paddle --
/// `breakout.BallBounced`.
@external(javascript, "./game_breakout_ffi.mjs", "playBounceSound")
fn play_bounce_sound() -> Nil

@target(javascript)
/// A short blip for a brick being destroyed -- `breakout.BrickDestroyed`.
@external(javascript, "./game_breakout_ffi.mjs", "playBrickSound")
fn play_brick_sound() -> Nil

@target(javascript)
/// Plays/shows whichever feedback `event` calls for, and -- for
/// `BrickDestroyed` specifically -- retires that brick's own `<div>`.
/// Same reasoning as `glemy/game_tiers.play_sound_event`: the one place
/// `breakout.GameEvent` gets translated into actual FFI calls, only
/// ever called from `loop`'s per-frame sweep over the events
/// `tick_and_render` returns.
fn play_game_event(event: breakout.GameEvent) -> Nil {
  case event {
    breakout.BallBounced -> play_bounce_sound()
    breakout.BrickDestroyed(id) -> {
      play_brick_sound()
      hide_brick_element(id)
    }
    breakout.BallLost -> Nil
  }
}

@target(javascript)
/// One frame's worth of work: advances the game (`breakout.tick`), then
/// renders the ball -- the only real `physics` entity this game has --
/// directly onto `canvas`'s own WebGPU context
/// (`render.render_entities_to_canvas`). Returns the new `Model` and
/// this frame's `GameEvent`s regardless of whether rendering succeeded,
/// alongside the render `Result`, same contract as
/// `glemy/game_tiers.tick_and_render`.
pub fn tick_and_render(
  model: Model,
  dt: Float,
  input: breakout.Input,
  canvas: Canvas,
) -> Promise(#(Model, List(breakout.GameEvent), Result(List(Int), String))) {
  let #(next_model, events) = breakout.tick(model, dt, input)
  render.render_entities_to_canvas(
    breakout.colored_ball(next_model),
    next_model.bounds,
    canvas,
  )
  |> promise.map(fn(result) { #(next_model, events, result) })
}

@target(javascript)
/// Starts the loop from `initial_model`, presenting each frame onto
/// `canvas`. Never returns in any observable sense, same shape as
/// `glemy/game_tiers.start`.
pub fn start(initial_model: Model, canvas: Canvas) -> Nil {
  loop(initial_model, canvas, None)
}

@target(javascript)
fn loop(model: Model, canvas: Canvas, previous_timestamp: Option(Float)) -> Nil {
  request_frame(fn(timestamp) {
    let dt = case previous_timestamp {
      // First frame: no prior timestamp to diff against -- same
      // reasoning as glemy/game_tiers's own loop.
      None -> 0.0
      Some(previous) -> { timestamp -. previous } /. 1000.0
    }
    let input =
      breakout.Input(
        move_left: io.is_key_down("ArrowLeft"),
        move_right: io.is_key_down("ArrowRight"),
      )
    tick_and_render(model, dt, input, canvas)
    |> promise.map(fn(triple) {
      let #(next_model, events, _render_result) = triple
      set_score_text(format_score(next_model.score))
      case next_model.status {
        breakout.Won -> set_status_message(True, "You win!")
        breakout.Lost -> set_status_message(True, "Game over!")
        breakout.Playing -> Nil
      }
      let #(left, top, width, height) =
        rect.to_css(breakout.paddle_rect(next_model), next_model.bounds)
      set_paddle_box(left, top, width, height)
      list.each(events, play_game_event)
      loop(next_model, canvas, Some(timestamp))
    })
    Nil
  })
}

@target(javascript)
/// A concrete, ready-to-run game: `breakout.html` calls this directly;
/// `start` above stays a reusable, scene-agnostic entry point for any
/// other initial `Model`.
pub fn main() -> Nil {
  let bounds = Bounds(min: vector2.zero, max: Vector2(100.0, 100.0))
  let initial_model = breakout.new(bounds)
  let canvas = render.get_canvas("glemy-canvas")

  // Brick divs are created once, up front -- they're static and only
  // ever destroyed (hide_brick_element, above), never added or moved
  // after this.
  create_brick_elements(
    list.map(initial_model.bricks, fn(b) {
      let #(left, top, width, height) = rect.to_css(b.rect, bounds)
      #(b.id, left, top, width, height)
    }),
  )
  start(initial_model, canvas)
}
