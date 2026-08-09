//// The paddle: player-controlled, moved by held keys (not cursor-follow
//// -- see this game's own doc comment for why), and the ball's
//// hit-position-dependent bounce off it. Game-specific, not core
//// physics (decision 0052) -- built on `glemy/physics/rect`'s Core
//// detection math, same reasoning as `glemy/games/breakout/brick`.

import gleam/float
import glemy/physics/rect.{type Rect}
import glemy/physics/bounds.{type Bounds}
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/vector2.{Vector2}

/// World units per second the paddle moves while a direction key is
/// held. Tuning deferred to hands-on play, matching this project's
/// standing practice for other feel constants (e.g.
/// `glemy/games/tiers`'s `drop_cooldown`) -- this is a reasonable,
/// clearly-responsive starting value.
pub const speed = 80.0

/// Moves `paddle_x` by `speed *. dt` in whichever direction is held
/// (`move_left`/`move_right` both `True`, or both `False`, cancel out to
/// no movement), then clamps the result into `play_bounds` via
/// `glemy/physics/bounds.clamp_x` -- the same clamp a circle's center
/// uses, reused directly here: it only ever cares about a symmetric
/// half-extent from center to edge, nothing circle-specific about it
/// despite the parameter being named `radius` there.
pub fn move(
  paddle_x: Float,
  dt: Float,
  move_left: Bool,
  move_right: Bool,
  half_width: Float,
  play_bounds: Bounds,
) -> Float {
  let direction = case move_left, move_right {
    True, False -> -1.0
    False, True -> 1.0
    _, _ -> 0.0
  }
  bounds.clamp_x(paddle_x +. direction *. speed *. dt, half_width, play_bounds)
}

/// Caps how much of the ball's total speed can go into the horizontal
/// component on a paddle bounce, so the vertical component can never
/// collapse toward zero -- a ball leaving the paddle nearly horizontal
/// is a known Breakout failure mode (it can bounce wall-to-wall at a
/// fixed height forever, never climbing back toward the bricks). `0.9`
/// always leaves at least `sqrt(1 - 0.9²) ≈ 0.436` of the total speed as
/// upward vy -- a comfortably steep angle, never grazing.
const max_deflection = 0.9

/// Reflects `ball` off `paddle_rect`: the horizontal velocity component
/// is derived from *where* on the paddle it was hit (offset from the
/// paddle's own center, scaled by `max_deflection`), not a flat
/// mirror-bounce -- genre convention, and the one piece of hit-dependent
/// reflection this project doesn't already have elsewhere. Trig-free
/// (`gleam/float` has no `sin`/`cos`): the vertical component is
/// whichever positive value keeps the ball's total speed unchanged
/// (`vy = sqrt(speed² - vx²)`), always the *positive* root, matching
/// this project's "`bounds.max.y` is world 'top'" convention -- the ball
/// must always leave the paddle heading toward increasing y (the
/// bricks).
///
/// Unlike `glemy/games/breakout/brick.reflect`, this also corrects
/// `ball`'s position (snapping it to just above `paddle_rect`): the
/// paddle is permanent, so a slow-moving ball whose new upward velocity
/// hasn't cleared the paddle within one frame's `dt` would otherwise
/// still read as overlapping next frame too, causing a double-bounce or
/// sticking bug. A destroyed brick has no such problem -- it's gone.
pub fn reflect(ball: Entity, paddle_rect: Rect) -> Entity {
  let center_x = { paddle_rect.min.x +. paddle_rect.max.x } /. 2.0
  let half_width = { paddle_rect.max.x -. paddle_rect.min.x } /. 2.0
  let offset = ball.position.x -. center_x
  let normalized = float.clamp(offset /. half_width, min: -1.0, max: 1.0)
  let speed = vector2.length(ball.velocity)
  let vx = normalized *. max_deflection *. speed
  let assert Ok(vy) = float.square_root(speed *. speed -. vx *. vx)
  let corrected_y = paddle_rect.max.y +. ball.radius
  Entity(
    ..ball,
    position: Vector2(ball.position.x, corrected_y),
    velocity: Vector2(vx, vy),
  )
}
