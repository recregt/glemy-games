import gleam/javascript/promise
import gleam/list
import glemy_games/game_tiers
import glemy_games/games/tiers.{Input, Model}
import glemy_games/games/tiers/rules
import glemy/physics
import glemy/physics/bounds.{Bounds}
import glemy/physics/entity.{Entity}
import glemy/physics/vector2.{Vector2}
import glemy/render.{type Canvas}

@target(javascript)
@external(javascript, "./game_tiers_test_ffi.mjs", "createOffscreenCanvas")
fn create_offscreen_canvas(width: Int, height: Int) -> Canvas

@target(javascript)
@external(javascript, "./game_tiers_test_ffi.mjs", "createCanvasWithNoWebgpuContext")
fn create_canvas_with_no_webgpu_context(width: Int, height: Int) -> Canvas

const box = Bounds(min: Vector2(0.0, 0.0), max: Vector2(100.0, 100.0))

pub fn format_score_at_zero_test() {
  assert game_tiers.format_score(0) == "Score: 0"
}

pub fn format_score_with_a_positive_value_test() {
  assert game_tiers.format_score(1234) == "Score: 1234"
}

pub fn format_score_with_a_single_digit_test() {
  assert game_tiers.format_score(1) == "Score: 1"
}

fn center_pixel_rgb(bytes: List(Int)) -> #(Int, Int, Int) {
  let assert [r, g, b, _a] =
    bytes |> list.drop({ 32 * 64 + 32 } * 4) |> list.take(4)
  #(r, g, b)
}

fn any_pixel_is_red(bytes: List(Int)) -> Bool {
  case bytes {
    [255, 0, 0, _a, ..] -> True
    [_r, _g, _b, _a, ..rest] -> any_pixel_is_red(rest)
    _ -> False
  }
}

@target(javascript)
pub fn tick_and_render_advances_physics_and_renders_test() {
  // Real end-to-end coverage of glemy/game's actual per-frame logic --
  // no requestAnimationFrame or real browser involved, just a real
  // OffscreenCanvas and Deno's native WebGPU (decision 0015).
  let falling =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 50.0),
      velocity: vector2.zero,
      radius: 20.0,
    )
  let model =
    Model(
      danger_timer: 0.0,
      game_over: False,
      current_tier: 0,
      next_tier: 0,
      preview_x: 50.0,
      cooldown_remaining: 0.0,
      score: 0,
      physics: physics.Model(
        entities: [falling],
        bounds: box,
        gravity: Vector2(0.0, -10.0),
      ),
    )
  let canvas = create_offscreen_canvas(64, 64)

  // dt is physics.max_dt itself, not some larger arbitrary value that would
  // now get silently clamped away by tiers.tick (decision 0037).
  let dt = physics.max_dt
  use #(next_model, _events, render_result) <- promise.map(game_tiers.tick_and_render(
    model,
    dt,
    Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
    canvas,
  ))

  // Physics: matches what entity.integrate/physics.update would produce
  // directly (already extensively tested on their own) -- this test's
  // job is confirming tick_and_render actually calls through, not
  // re-deriving that math.
  let assert [result_entity] = next_model.physics.entities
  // tiers.tick settles every entity every frame (entity.settle) --
  // one frame of gravity, then damped.
  assert result_entity.velocity
    == Vector2(0.0, -10.0 *. dt *. entity.velocity_damping)
  assert result_entity.position == Vector2(50.0, 50.0 +. { -10.0 *. dt } *. dt)

  // Rendering: something was actually drawn, for real -- a 20-radius
  // entity a little below center should still cover the canvas's own
  // center pixel.
  let assert Ok(bytes) = render_result
  assert center_pixel_rgb(bytes) == #(255, 0, 0)
}

@target(javascript)
pub fn tick_and_render_drop_adds_an_entity_before_rendering_test() {
  let model =
    Model(
      danger_timer: 0.0,
      game_over: False,
      current_tier: 0,
      next_tier: 0,
      preview_x: 50.0,
      cooldown_remaining: 0.0,
      score: 0,
      physics: physics.Model(entities: [], bounds: box, gravity: vector2.zero),
    )
  let canvas = create_offscreen_canvas(64, 64)

  use #(next_model, _events, render_result) <- promise.map(game_tiers.tick_and_render(
    model,
    0.0,
    Input(cursor_x: 50.0, drop_requested: True, next_tier_random: 0.0),
    canvas,
  ))

  let assert [spawned] = next_model.physics.entities
  // cursor_x 50.0 is already within tier 0's clamp range, so preview_x
  // (and therefore the drop's x) stays 50.0; y is the fixed spawn
  // height (bounds.max.y - 15.0 = 85.0), not the cursor's y at all.
  assert spawned.position == Vector2(50.0, 85.0)
  assert spawned.radius == rules.radius(0)
  assert spawned.kind == 0

  // The newly dropped entity was rendered in the same frame it
  // appeared -- not left invisible until a following frame. Checked by
  // presence anywhere in the frame (not a specific pixel): the entity's
  // spawn position isn't the texture's center this time.
  let assert Ok(bytes) = render_result
  assert any_pixel_is_red(bytes)
}

@target(javascript)
pub fn tick_and_render_still_advances_the_model_when_rendering_fails_test() {
  // Documented contract: physics keeps running even through a dropped
  // frame (loop relies on exactly this to keep simulating rather than
  // getting stuck retrying a broken canvas forever) -- proven here with
  // a canvas genuinely unable to render (already bound to a different
  // context type, same technique as render_test.gleam's equivalent
  // error-path test), not just claimed in a comment.
  let falling =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 50.0),
      velocity: vector2.zero,
      radius: 5.0,
    )
  let model =
    Model(
      danger_timer: 0.0,
      game_over: False,
      current_tier: 0,
      next_tier: 0,
      preview_x: 50.0,
      cooldown_remaining: 0.0,
      score: 0,
      physics: physics.Model(
        entities: [falling],
        bounds: box,
        gravity: Vector2(0.0, -10.0),
      ),
    )
  let broken_canvas = create_canvas_with_no_webgpu_context(64, 64)

  // dt is physics.max_dt itself, not some larger arbitrary value that would
  // now get silently clamped away by tiers.tick (decision 0037).
  let dt = physics.max_dt
  use #(next_model, _events, render_result) <- promise.map(game_tiers.tick_and_render(
    model,
    dt,
    Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
    broken_canvas,
  ))

  assert render_result == Error("canvas has no webgpu context")
  let assert [result_entity] = next_model.physics.entities
  // tiers.tick settles every entity every frame (entity.settle) --
  // one frame of gravity, then damped.
  assert result_entity.velocity
    == Vector2(0.0, -10.0 *. dt *. entity.velocity_damping)
  assert result_entity.position == Vector2(50.0, 50.0 +. { -10.0 *. dt } *. dt)
}
