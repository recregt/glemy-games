import gleam/javascript/promise
import gleam/list
import glemy_games/game_breakout
import glemy_games/games/breakout.{type Model, Input, Model, Playing}
import glemy/physics/bounds.{Bounds}
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/vector2.{Vector2}
import glemy/render.{type Canvas}

@target(javascript)
@external(javascript, "./game_breakout_test_ffi.mjs", "createOffscreenCanvas")
fn create_offscreen_canvas(width: Int, height: Int) -> Canvas

@target(javascript)
@external(javascript, "./game_breakout_test_ffi.mjs", "createCanvasWithNoWebgpuContext")
fn create_canvas_with_no_webgpu_context(width: Int, height: Int) -> Canvas

const box = Bounds(min: Vector2(0.0, 0.0), max: Vector2(100.0, 100.0))

pub fn format_score_at_zero_test() {
  assert game_breakout.format_score(0) == "Score: 0"
}

pub fn format_score_with_a_positive_value_test() {
  assert game_breakout.format_score(1234) == "Score: 1234"
}

fn playing_model(ball: Entity) -> Model {
  Model(
    ball: ball,
    bounds: box,
    paddle_x: 50.0,
    bricks: [],
    score: 0,
    status: Playing,
  )
}

fn center_pixel_rgb(bytes: List(Int)) -> #(Int, Int, Int) {
  let assert [r, g, b, _a] =
    bytes |> list.drop({ 32 * 64 + 32 } * 4) |> list.take(4)
  #(r, g, b)
}

const no_input = Input(move_left: False, move_right: False)

@target(javascript)
pub fn tick_and_render_advances_physics_and_renders_the_ball_test() {
  // Real end-to-end coverage of glemy/game_breakout's actual per-frame
  // logic -- no requestAnimationFrame or real browser involved, just a
  // real OffscreenCanvas and Deno's native WebGPU (decision 0015).
  let ball =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 50.0),
      velocity: vector2.zero,
      radius: 20.0,
    )
  let model = playing_model(ball)
  let canvas = create_offscreen_canvas(64, 64)

  use #(_next_model, _events, render_result) <- promise.map(
    game_breakout.tick_and_render(model, 0.0, no_input, canvas),
  )

  // A 20-radius ball dead-center should cover the canvas's own center
  // pixel, rendered white (breakout.ball_color).
  let assert Ok(bytes) = render_result
  assert center_pixel_rgb(bytes) == #(255, 255, 255)
}

@target(javascript)
pub fn tick_and_render_still_advances_the_model_when_rendering_fails_test() {
  // Documented contract: physics keeps running even through a dropped
  // frame -- same reasoning as glemy/game_tiers's own equivalent test.
  // dt is comfortably below physics.max_dt (~0.0333, decision 0037) so
  // breakout.tick's own internal clamp doesn't change what dt actually
  // gets used.
  let dt = 0.01
  let ball =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 50.0),
      velocity: Vector2(5.0, 0.0),
      radius: 2.0,
    )
  let model = playing_model(ball)
  let broken_canvas = create_canvas_with_no_webgpu_context(64, 64)

  use #(next_model, _events, render_result) <- promise.map(
    game_breakout.tick_and_render(model, dt, no_input, broken_canvas),
  )

  assert render_result == Error("canvas has no webgpu context")
  assert next_model.ball.position == Vector2(50.0 +. 5.0 *. dt, 50.0)
}
