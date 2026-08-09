import gleam/javascript/promise
import gleam/list
import glemy_games/game_platformer
import glemy_games/games/platformer.{type Model, Input, Model, Playing}
import glemy/physics/bounds.{Bounds}
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/rect.{Rect}
import glemy/physics/vector2.{Vector2}
import glemy/render.{type Canvas}

@target(javascript)
@external(javascript, "./game_platformer_test_ffi.mjs", "createOffscreenCanvas")
fn create_offscreen_canvas(width: Int, height: Int) -> Canvas

@target(javascript)
@external(javascript, "./game_platformer_test_ffi.mjs", "createCanvasWithNoWebgpuContext")
fn create_canvas_with_no_webgpu_context(width: Int, height: Int) -> Canvas

const box = Bounds(min: Vector2(0.0, 0.0), max: Vector2(100.0, 100.0))

fn playing_model(player: Entity) -> Model {
  Model(
    player: player,
    bounds: box,
    platforms: [],
    goal: Rect(min: Vector2(200.0, 200.0), max: Vector2(210.0, 210.0)),
    grounded: False,
    status: Playing,
  )
}

fn center_pixel_rgb(bytes: List(Int)) -> #(Int, Int, Int) {
  let assert [r, g, b, _a] =
    bytes |> list.drop({ 32 * 64 + 32 } * 4) |> list.take(4)
  #(r, g, b)
}

const no_input = Input(move_left: False, move_right: False, jump: False)

@target(javascript)
pub fn tick_and_render_advances_physics_and_renders_the_player_test() {
  // Real end-to-end coverage of glemy/game_platformer's actual per-frame
  // logic -- no requestAnimationFrame or real browser involved, just a
  // real OffscreenCanvas and Deno's native WebGPU (decision 0015).
  let player =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 50.0),
      velocity: vector2.zero,
      radius: 20.0,
    )
  let model = playing_model(player)
  let canvas = create_offscreen_canvas(64, 64)

  use #(_next_model, _events, render_result) <- promise.map(
    game_platformer.tick_and_render(model, 0.0, no_input, canvas),
  )

  // A 20-radius player dead-center should cover the canvas's own center
  // pixel, rendered green (platformer.player_color -- the green channel
  // (1.0) is an exact edge value, same as Breakout's own white-ball
  // test; the red/blue channels (0.2/0.3) aren't asserted exactly,
  // since their float-to-u8 rounding isn't pinned down elsewhere in
  // this project, only that they're visibly non-background).
  let assert Ok(bytes) = render_result
  let #(r, g, b) = center_pixel_rgb(bytes)
  assert g == 255
  assert r != 0
  assert b != 0
}

@target(javascript)
pub fn tick_and_render_still_advances_the_model_when_rendering_fails_test() {
  // Documented contract: physics keeps running even through a dropped
  // frame -- same reasoning as glemy/game_breakout's own equivalent
  // test. dt is comfortably below physics.max_dt (~0.0333, decision
  // 0037) so platformer.tick's own internal clamp doesn't change what
  // dt actually gets used. Falls under gravity, not horizontal drift --
  // unlike Breakout's ball, this game's own tick sets horizontal
  // velocity directly from held input every frame (never preserved
  // from the incoming model), so a horizontal-drift assertion here
  // would test the wrong thing entirely.
  let dt = 0.01
  let player =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 50.0),
      velocity: vector2.zero,
      radius: 2.0,
    )
  let model = playing_model(player)
  let broken_canvas = create_canvas_with_no_webgpu_context(64, 64)

  use #(next_model, _events, render_result) <- promise.map(
    game_platformer.tick_and_render(model, dt, no_input, broken_canvas),
  )

  assert render_result == Error("canvas has no webgpu context")
  let expected_vy = platformer.gravity.y *. dt
  assert next_model.player.velocity == Vector2(0.0, expected_vy)
  assert next_model.player.position == Vector2(50.0, 50.0 +. expected_vy *. dt)
}
