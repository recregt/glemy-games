//// The platformer's game runner.
////
//// JavaScript-target only (like `io`, `render`): owns the actual
//// `requestAnimationFrame` loop and glues `io` → `glemy/games/platformer` →
//// `render` together each frame -- same split, same testability
//// reasoning as `glemy/game_tiers`/`glemy/game_breakout` (see either
//// module's own doc comment). Only the player renders via the real
//// WebGPU pipeline (`render.render_entities_to_canvas`); the platforms
//// and goal aren't `physics` entities (same reasoning as Breakout's
//// paddle/bricks, decision 0052), so they're positioned as CSS overlay
//// elements from `game_platformer_ffi.mjs` instead. Simpler than
//// Breakout's own overlay wiring in one real way: platforms/the goal
//// are static and never destroyed, so every overlay `<div>` is created
//// once at startup and never touched again -- no
//// `Brick.id`/event-driven-hide problem to solve here at all.

import gleam/javascript/promise.{type Promise}
import gleam/list
import gleam/option.{type Option, None, Some}
import glemy_games/games/platformer.{type Model}
import glemy/io
import glemy/physics/bounds.{Bounds}
import glemy/physics/rect
import glemy/physics/vector2.{Vector2}
import glemy/render.{type Canvas}

@target(javascript)
@external(javascript, "./game_ffi.mjs", "requestFrame")
fn request_frame(callback: fn(Float) -> Nil) -> Nil

@target(javascript)
@external(javascript, "./game_ffi.mjs", "setElementVisibilityMessage")
fn set_element_visibility_message(
  element_id: String,
  visible: Bool,
  message: String,
) -> Nil

@target(javascript)
/// Sets `platformer.html`'s `#glemy-status` element's text to `message`
/// and its visibility to `visible` -- covers both `Won` and `Lost` (the
/// caller decides `message`), same non-branching-DOM-write reasoning as
/// `game_breakout.gleam`'s own `set_status_message`. A thin wrapper
/// over the shared `set_element_visibility_message` (decision 0063) so
/// every existing call site keeps this game's own name/2-argument
/// shape.
fn set_status_message(visible: Bool, message: String) -> Nil {
  set_element_visibility_message("glemy-status", visible, message)
}

@target(javascript)
/// Creates one `<div>` per platform inside `platformer.html`'s
/// `#glemy-platforms`, plus one for the goal in `#glemy-goal` -- called
/// once at startup (see `main`), never again: platforms and the goal
/// are static, unlike Breakout's own destructible bricks.
@external(javascript, "./game_platformer_ffi.mjs", "createLevelElements")
fn create_level_elements(
  platforms: List(#(Float, Float, Float, Float)),
  goal: #(Float, Float, Float, Float),
) -> Nil

@target(javascript)
/// A short blip for the player jumping -- `platformer.Jumped`.
@external(javascript, "./game_platformer_ffi.mjs", "playJumpSound")
fn play_jump_sound() -> Nil

@target(javascript)
/// A short blip for the player landing -- `platformer.Landed`.
@external(javascript, "./game_platformer_ffi.mjs", "playLandSound")
fn play_land_sound() -> Nil

@target(javascript)
/// Plays whichever feedback `event` calls for -- same reasoning as
/// `glemy/game_breakout.play_game_event`: the one place
/// `platformer.GameEvent` gets translated into actual FFI calls, only
/// ever called from `loop`'s per-frame sweep over the events
/// `tick_and_render` returns. `Fell` has no sound of its own -- the
/// status message covers the game-over feedback.
fn play_game_event(event: platformer.GameEvent) -> Nil {
  case event {
    platformer.Jumped -> play_jump_sound()
    platformer.Landed -> play_land_sound()
    platformer.Fell -> Nil
  }
}

@target(javascript)
/// One frame's worth of work: advances the game (`platformer.tick`),
/// then renders the player -- the only real `physics` entity this game
/// has -- directly onto `canvas`'s own WebGPU context
/// (`render.render_entities_to_canvas`). Returns the new `Model` and
/// this frame's `GameEvent`s regardless of whether rendering succeeded,
/// alongside the render `Result`, same contract as
/// `glemy/game_breakout.tick_and_render`.
pub fn tick_and_render(
  model: Model,
  dt: Float,
  input: platformer.Input,
  canvas: Canvas,
) -> Promise(#(Model, List(platformer.GameEvent), Result(List(Int), String))) {
  let #(next_model, events) = platformer.tick(model, dt, input)
  render.render_entities_to_canvas(
    platformer.colored_player(next_model),
    next_model.bounds,
    canvas,
  )
  |> promise.map(fn(result) { #(next_model, events, result) })
}

@target(javascript)
/// Starts the loop from `initial_model`, presenting each frame onto
/// `canvas`. Never returns in any observable sense, same shape as
/// `glemy/game_breakout.start`.
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
      platformer.Input(
        move_left: io.is_key_down("ArrowLeft"),
        move_right: io.is_key_down("ArrowRight"),
        jump: io.is_key_down(" "),
      )
    tick_and_render(model, dt, input, canvas)
    |> promise.map(fn(triple) {
      let #(next_model, events, _render_result) = triple
      case next_model.status {
        platformer.Won -> set_status_message(True, "You win!")
        platformer.Lost -> set_status_message(True, "You fell!")
        platformer.Playing -> Nil
      }
      list.each(events, play_game_event)
      loop(next_model, canvas, Some(timestamp))
    })
    Nil
  })
}

@target(javascript)
/// A concrete, ready-to-run game: `platformer.html` calls this
/// directly; `start` above stays a reusable, scene-agnostic entry point
/// for any other initial `Model`.
pub fn main() -> Nil {
  let bounds = Bounds(min: vector2.zero, max: Vector2(100.0, 100.0))
  let initial_model = platformer.new(bounds)
  let canvas = render.get_canvas("glemy-canvas")

  // Platform/goal divs are created once, up front -- they're static and
  // never destroyed or moved, unlike Breakout's own bricks.
  create_level_elements(
    list.map(initial_model.platforms, fn(p) { rect.to_css(p, bounds) }),
    rect.to_css(initial_model.goal, bounds),
  )
  start(initial_model, canvas)
}
