//// A Breakout/Arkanoid-style paddle-and-brick game -- glemy's second
//// reference game, chosen specifically to stress-test the genuinely
//// genre-agnostic claims of `glemy/physics` (decisions 0047-0050) with
//// a real second, genre-distinct consumer: a win condition (not just
//// lose), a paddle whose bounce angle depends on *where* it's hit, and
//// collision against static rectangular obstacles.
////
//// Rectangles (the paddle, bricks) stay entirely inside this module
//// tree (`brick`/`paddle`) -- never `physics.Model` entities, never
//// touching `collision.gleam`/`collision_sweep.gleam`/`render.gleam`
//// (decision 0052). Only the ball is a real `physics` `Entity`. The
//// circle-vs-rectangle *detection* math itself (`Rect`, `overlaps`,
//// `penetration_axis`) moved to `glemy/physics/rect` once
//// `glemy/games/platformer` needed the identical math for a second
//// game (decision 0058) -- this game's own `brick.reflect`/
//// `paddle.reflect` resolution logic (what happens once a collision is
//// detected) stayed exactly where it was, still entirely game-local.
////
//// A real, useful negative result found while building this:
//// `physics.update` does not actually generalize to a second genre --
//// `physics/bounds.bounce`'s restitution ramp is tuned specifically for
//// `glemy/games/tiers`' fruit to "dead-plop" (decision 0029), which
//// would make a Breakout ball lose ~90% of its speed on the first wall
//// hit and grind to a halt within two or three bounces. `tick` below
//// composes `physics/entity.integrate` and
//// `physics/collision_sweep.resolve_all_collisions` directly instead --
//// both genuinely are genre-agnostic -- and writes its own bespoke,
//// near-elastic wall bounce (`bounce_off_walls`), rather than calling
//// `physics.update` at all. See decision 0052 for the full reasoning.

import gleam/float
import gleam/list
import gleam/option.{None, Some}
import glemy_games/games/breakout/brick.{type Brick}
import glemy_games/games/breakout/paddle
import glemy/physics/rect.{type Rect, Rect}
import glemy/physics
import glemy/physics/bounds.{type Bounds}
import glemy/physics/collision_sweep
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/vector2.{Vector2}

/// This game's outcome -- a sum type, not two independent `Bool`s
/// (`game_over`/`game_won`): the "both `True`" state a two-`Bool`
/// version would make representable is nonsensical, and Gleam rules it
/// out for free, same reasoning `physics/collision_sweep.PairInteraction`
/// already applies to `Bounce`/`Consume` being mutually exclusive.
pub type GameStatus {
  Playing
  Won
  Lost
}

/// This game's complete state: the ball (the only real `physics.Model`
/// entity this game has -- see this module's own doc comment), the play
/// field it moves inside of (also what the paddle and bricks are
/// positioned relative to), the paddle's own x position, the remaining
/// bricks, the running score, and the current outcome.
pub type Model {
  Model(
    ball: Entity,
    bounds: Bounds,
    paddle_x: Float,
    bricks: List(Brick),
    score: Int,
    status: GameStatus,
  )
}

/// Something `tick` decided happened this specific frame, purely for a
/// caller to react to (a sound, a visual cue) -- same reasoning as
/// `glemy/games/tiers.GameEvent`.
pub type GameEvent {
  /// The ball bounced off a wall or the paddle this tick.
  BallBounced
  /// A brick was destroyed this tick -- `id` is that brick's own stable
  /// `Brick.id` (see that type's own doc comment for why a renderer
  /// needs this specifically, not a list position), so a renderer can
  /// retire the one DOM element that brick owns without re-walking the
  /// whole remaining list.
  BrickDestroyed(id: Int)
  /// The ball fell past the paddle this tick -- `status` became `Lost`.
  BallLost
}

/// Per-frame input: held-key paddle movement, not cursor-follow -- see
/// this module's own doc comment for why (this game was picked
/// specifically to exercise `glemy/io.is_key_down`, which
/// `glemy/games/tiers` never needed).
pub type Input {
  Input(move_left: Bool, move_right: Bool)
}

/// Half the paddle's own width -- also what `physics/bounds.clamp_x`
/// clamps the paddle's center into `bounds` with (see `paddle.move`).
pub const paddle_half_width = 10.0

/// The paddle's fixed height.
pub const paddle_height = 3.0

/// How far above `bounds.min.y` the paddle's own bottom edge sits.
pub const paddle_margin_from_bottom = 10.0

/// The ball's fixed radius.
pub const ball_radius = 2.0

/// The ball's speed at the start of a game. Tuning deferred to hands-on
/// play, matching this project's standing practice for other feel
/// constants.
pub const initial_ball_speed = 60.0

const grid_rows = 5

const grid_columns = 8

const grid_top_margin = 10.0

const brick_height = 5.0

const brick_spacing = 2.0

const score_per_brick = 10

/// A fresh game: the ball centered above the paddle heading up and
/// slightly to one side, the paddle centered, a full brick grid, zero
/// score, `Playing`.
pub fn new(bounds: Bounds) -> Model {
  let center_x = { bounds.min.x +. bounds.max.x } /. 2.0
  let ball =
    Entity(
      position: Vector2(center_x, bounds.min.y +. paddle_margin_from_bottom +. paddle_height +. ball_radius +. 1.0),
      velocity: Vector2(initial_ball_speed *. 0.3, initial_ball_speed),
      radius: ball_radius,
      kind: 0,
      resting_time: 0.0,
    )
  let bricks =
    brick.grid(
      rows: grid_rows,
      columns: grid_columns,
      bounds: Rect(min: bounds.min, max: bounds.max),
      top_margin: grid_top_margin,
      brick_height: brick_height,
      spacing: brick_spacing,
      score_per_brick: score_per_brick,
    )
  Model(
    ball: ball,
    bounds: bounds,
    paddle_x: center_x,
    bricks: bricks,
    score: 0,
    status: Playing,
  )
}

/// The paddle's current rectangle, derived from `model.paddle_x` --
/// used both for collision (`tick`, below) and by a renderer to know
/// where to draw it (paddle/bricks aren't `physics` entities, so a
/// renderer can't get this from `model.ball` the way it gets the ball's
/// own shape).
pub fn paddle_rect(model: Model) -> Rect {
  paddle_rect_at(model.paddle_x, model.bounds)
}

fn paddle_rect_at(paddle_x: Float, bounds: Bounds) -> Rect {
  let bottom = bounds.min.y +. paddle_margin_from_bottom
  Rect(
    min: Vector2(paddle_x -. paddle_half_width, bottom),
    max: Vector2(paddle_x +. paddle_half_width, bottom +. paddle_height),
  )
}

/// The ball's color, matching `render.ColoredEntity` -- a solid, high-
/// contrast white against the renderer's black background, distinct
/// from any tier color `glemy/games/tiers` uses (this game has no tier
/// concept, so there's no clash to avoid, just a plain, deliberate
/// choice).
pub const ball_color = #(1.0, 1.0, 1.0)

/// `model.ball` paired with its color, ready to pass straight into
/// `glemy/render`'s `render_entities_to_bytes`/`render_entities_to_canvas`
/// -- the only real `physics` entity this game has (see this module's
/// own doc comment), so this is always a single-element list. Mirrors
/// `glemy/games/tiers.colored_entities`'s own reasoning: rendering has
/// no concept of what a color should be derived from, that's entirely
/// this game's decision.
pub fn colored_ball(model: Model) -> List(#(Entity, #(Float, Float, Float))) {
  [#(model.ball, ball_color)]
}

/// Composes one frame's worth of input with the ball's motion: moves
/// the paddle, integrates and bounces the ball off the walls (see this
/// module's own doc comment for why that's a bespoke function here, not
/// `physics.update`), resolves a paddle hit, resolves at most one brick
/// hit, then updates `status` (a brick grid that's now empty -> `Won`;
/// the ball having fallen past `bounds.min.y` -> `Lost`). Once `status`
/// isn't `Playing`, every subsequent `tick` call is a full no-op -- the
/// game freezes at the exact moment it ended, same convention
/// `glemy/games/tiers.tick` already uses.
pub fn tick(model: Model, dt: Float, input: Input) -> #(Model, List(GameEvent)) {
  let dt = float.min(dt, physics.max_dt)
  case model.status {
    Playing -> {
      let paddle_x =
        paddle.move(
          model.paddle_x,
          dt,
          input.move_left,
          input.move_right,
          paddle_half_width,
          model.bounds,
        )

      // Integrate, then bounce off the walls -- deliberately not
      // physics.update (see this module's own doc comment). Wrapping
      // this single ball through resolve_all_collisions anyway (rather
      // than skipping straight to the paddle/brick checks below) is a
      // real, if trivial, confirmation that it degrades gracefully with
      // nothing to pair against -- no crash, no-op, exactly as
      // physics/collision_sweep.gleam's own doc comment implies but
      // never had a genuinely single-entity real caller to prove.
      let integrated = entity.integrate(model.ball, vector2.zero, dt)
      let bounced = bounce_off_walls(integrated, model.bounds)
      let wall_bounced = bounced.velocity != integrated.velocity
      let #(swept, _) =
        collision_sweep.resolve_all_collisions([bounced], fn(_a, _b) {
          collision_sweep.Bounce
        })
      let assert [swept_ball] = swept

      let paddle_rect_now = paddle_rect_at(paddle_x, model.bounds)
      let #(after_paddle, paddle_hit) = case
        rect.overlaps(swept_ball, paddle_rect_now)
      {
        True -> #(paddle.reflect(swept_ball, paddle_rect_now), True)
        False -> #(swept_ball, False)
      }

      let brick_hit = brick.resolve_first_hit(after_paddle, model.bricks)
      let #(final_ball, remaining_bricks, score_gained) = case brick_hit {
        Some(hit) -> #(hit.ball, hit.remaining, hit.score)
        None -> #(after_paddle, model.bricks, 0)
      }

      let missed_paddle = final_ball.position.y <. model.bounds.min.y
      let bricks_cleared = remaining_bricks == []

      let status = case bricks_cleared, missed_paddle {
        True, _ -> Won
        _, True -> Lost
        _, _ -> Playing
      }

      let events =
        list.flatten([
          case wall_bounced || paddle_hit {
            True -> [BallBounced]
            False -> []
          },
          case brick_hit {
            Some(hit) -> [BrickDestroyed(hit.destroyed_id)]
            None -> []
          },
          case status == Lost {
            True -> [BallLost]
            False -> []
          },
        ])

      #(
        Model(
          ball: final_ball,
          bounds: model.bounds,
          paddle_x: paddle_x,
          bricks: remaining_bricks,
          score: model.score + score_gained,
          status: status,
        ),
        events,
      )
    }
    _ -> #(model, [])
  }
}

/// Reflects `ball` off left/right/top of `bounds` at (near-)full elastic
/// strength -- deliberately not `physics/bounds.bounce` (see this
/// module's own doc comment) -- and does nothing at the bottom, which is
/// what makes falling past `bounds.min.y` a lose trigger instead of a
/// wall. Built on `physics/bounds.resolve_axis`/`resolve_high_only`
/// (decision 0062): this game supplies only the velocity transform
/// (full-strength reflect), the clamp-and-branch shape itself is Core.
fn bounce_off_walls(ball: Entity, bounds: Bounds) -> Entity {
  let #(x, vx) =
    bounds.resolve_axis(
      ball.position.x,
      ball.velocity.x,
      bounds.min.x +. ball.radius,
      bounds.max.x -. ball.radius,
      float.absolute_value,
      fn(v) { float.negate(float.absolute_value(v)) },
    )
  let #(y, vy) =
    bounds.resolve_high_only(
      ball.position.y,
      ball.velocity.y,
      bounds.max.y -. ball.radius,
      fn(v) { float.negate(float.absolute_value(v)) },
    )
  Entity(..ball, position: Vector2(x, y), velocity: Vector2(vx, vy))
}
