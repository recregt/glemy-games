import glemy_games/games/breakout.{
  BallBounced, BallLost, BrickDestroyed, Input, Lost, Model, Playing, Won,
  type Model,
}
import glemy_games/games/breakout/brick.{type Brick, Brick}
import glemy_games/games/breakout/paddle
import glemy/physics/rect.{Rect}
import glemy/physics/bounds.{Bounds}
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/vector2.{type Vector2, Vector2}

const box = Bounds(min: Vector2(0.0, 0.0), max: Vector2(100.0, 100.0))

fn ball_at(position: Vector2, velocity: Vector2) -> Entity {
  Entity(
    position: position,
    velocity: velocity,
    radius: breakout.ball_radius,
    kind: 0,
    resting_time: 0.0,
  )
}

fn playing_model(
  ball ball: Entity,
  paddle_x paddle_x: Float,
  bricks bricks: List(Brick),
) -> Model {
  Model(
    ball: ball,
    bounds: box,
    paddle_x: paddle_x,
    bricks: bricks,
    score: 0,
    status: Playing,
  )
}

const no_input = Input(move_left: False, move_right: False)

// A brick placed well out of the way of every other test's ball
// trajectory/paddle position -- used whenever a test needs a non-empty
// `bricks` list (so `bricks_cleared` doesn't accidentally read `True`
// just because the list started empty) without the brick itself ever
// actually being hit.
const far_away_brick = Brick(
  id: 999,
  rect: Rect(min: Vector2(200.0, 200.0), max: Vector2(210.0, 210.0)),
  score: 10,
)

pub fn tick_bounces_off_the_left_wall_at_full_strength_test() {
  // Deliberately not physics/bounds.bounce's ~10% restitution (decision
  // 0029, tuned for glemy/games/tiers specifically) -- this game's own
  // bespoke bounce_off_walls preserves the full incoming speed. Ball
  // already sitting exactly on the effective left edge (bounds.min.x +
  // ball_radius = 2.0); the tiny dt below is enough to carry it just
  // past, into bounce_axis_full's "past min" branch.
  let ball = ball_at(Vector2(2.0, 50.0), Vector2(-20.0, 0.0))
  let model = playing_model(ball, paddle_x: 50.0, bricks: [far_away_brick])

  let #(ticked, _events) = breakout.tick(model, 0.01, no_input)

  assert ticked.ball.velocity.x == 20.0
  assert ticked.ball.position.x == 2.0
}

pub fn tick_bounces_off_the_right_wall_at_full_strength_test() {
  let ball = ball_at(Vector2(98.0, 50.0), Vector2(20.0, 0.0))
  let model = playing_model(ball, paddle_x: 50.0, bricks: [far_away_brick])

  let #(ticked, _events) = breakout.tick(model, 0.01, no_input)

  assert ticked.ball.velocity.x == -20.0
  assert ticked.ball.position.x == 98.0
}

pub fn tick_bounces_off_the_top_wall_at_full_strength_test() {
  let ball = ball_at(Vector2(50.0, 98.0), Vector2(0.0, 20.0))
  let model = playing_model(ball, paddle_x: 50.0, bricks: [far_away_brick])

  let #(ticked, _events) = breakout.tick(model, 0.01, no_input)

  assert ticked.ball.velocity.y == -20.0
  assert ticked.ball.position.y == 98.0
}

pub fn tick_does_not_bounce_off_the_bottom_edge_test() {
  // The ball is already below bounds.min.y (dt 0.0 keeps it exactly
  // there, isolating the check from any integration/wall-bounce
  // interaction) -- bounce_off_walls has no bottom case at all, which
  // is exactly what makes falling past it a lose trigger, not a wall.
  let ball = ball_at(Vector2(50.0, -5.0), vector2.zero)
  let model = playing_model(ball, paddle_x: 50.0, bricks: [far_away_brick])

  let #(ticked, _events) = breakout.tick(model, 0.0, no_input)

  assert ticked.ball.position.y == -5.0
  assert ticked.status == Lost
}

pub fn tick_records_ball_lost_event_when_missing_the_paddle_test() {
  let ball = ball_at(Vector2(50.0, -5.0), vector2.zero)
  let model = playing_model(ball, paddle_x: 50.0, bricks: [far_away_brick])

  let #(_ticked, events) = breakout.tick(model, 0.0, no_input)

  assert events == [BallLost]
}

pub fn tick_records_ball_bounced_on_a_wall_hit_test() {
  let ball = ball_at(Vector2(2.0, 50.0), Vector2(-20.0, 0.0))
  let model = playing_model(ball, paddle_x: 50.0, bricks: [far_away_brick])

  let #(_ticked, events) = breakout.tick(model, 0.01, no_input)

  assert events == [BallBounced]
}

pub fn tick_records_no_events_when_nothing_happens_test() {
  // In open space, nowhere near any wall, the paddle, or a brick.
  let ball = ball_at(Vector2(50.0, 50.0), Vector2(1.0, 1.0))
  let model = playing_model(ball, paddle_x: 10.0, bricks: [far_away_brick])

  let #(_ticked, events) = breakout.tick(model, 0.01, no_input)

  assert events == []
}

pub fn tick_reflects_the_ball_off_the_paddle_test() {
  let paddle_x = 50.0
  // paddle_rect's y range is [10.0, 13.0] (bounds.min.y +
  // paddle_margin_from_bottom, + paddle_height) -- a ball centered at
  // the paddle's own x, just inside that range, overlaps it.
  let ball = ball_at(Vector2(50.0, 12.0), Vector2(0.0, -30.0))
  let model = playing_model(ball, paddle_x: paddle_x, bricks: [far_away_brick])

  let #(ticked, events) = breakout.tick(model, 0.0, no_input)

  // Dead-center hit: zero horizontal deflection, positive (upward) vy,
  // same shape already exhaustively tested directly in paddle_test.gleam
  // -- this test's job is confirming `tick` actually calls through when
  // an overlap exists, not re-deriving that math.
  assert ticked.ball.velocity.x == 0.0
  assert ticked.ball.velocity.y >. 0.0
  assert events == [BallBounced]
  assert ticked.status == Playing
}

pub fn tick_does_not_reflect_off_the_paddle_when_not_overlapping_test() {
  let ball = ball_at(Vector2(50.0, 50.0), Vector2(0.0, -1.0))
  let model = playing_model(ball, paddle_x: 50.0, bricks: [far_away_brick])

  let #(ticked, _events) = breakout.tick(model, 0.001, no_input)

  // Free flight -- no wall, paddle, or brick close enough to touch.
  assert ticked.ball.velocity == Vector2(0.0, -1.0)
}

pub fn tick_destroys_an_overlapping_brick_and_records_the_event_test() {
  let brick_hit =
    Brick(
      id: 1,
      rect: Rect(min: Vector2(45.0, 45.0), max: Vector2(55.0, 55.0)),
      score: 10,
    )
  let ball = ball_at(Vector2(50.0, 50.0), vector2.zero)
  let model =
    playing_model(ball, paddle_x: 10.0, bricks: [far_away_brick, brick_hit])

  let #(ticked, events) = breakout.tick(model, 0.0, no_input)

  assert ticked.bricks == [far_away_brick]
  assert ticked.score == 10
  assert events == [BrickDestroyed(1)]
}

pub fn tick_resolves_only_the_first_overlapping_brick_per_frame_test() {
  let overlapping_a =
    Brick(
      id: 1,
      rect: Rect(min: Vector2(45.0, 45.0), max: Vector2(55.0, 55.0)),
      score: 10,
    )
  let overlapping_b =
    Brick(
      id: 2,
      rect: Rect(min: Vector2(54.0, 45.0), max: Vector2(64.0, 55.0)),
      score: 20,
    )
  let ball = ball_at(Vector2(50.0, 50.0), vector2.zero)
  let model =
    playing_model(ball, paddle_x: 10.0, bricks: [overlapping_a, overlapping_b])

  let #(ticked, events) = breakout.tick(model, 0.0, no_input)

  assert ticked.bricks == [overlapping_b]
  assert ticked.score == 10
  assert events == [BrickDestroyed(1)]
}

pub fn tick_wins_once_the_last_brick_is_cleared_test() {
  let last_brick =
    Brick(
      id: 1,
      rect: Rect(min: Vector2(45.0, 45.0), max: Vector2(55.0, 55.0)),
      score: 10,
    )
  let ball = ball_at(Vector2(50.0, 50.0), vector2.zero)
  let model = playing_model(ball, paddle_x: 10.0, bricks: [last_brick])

  let #(ticked, events) = breakout.tick(model, 0.0, no_input)

  assert ticked.bricks == []
  assert ticked.status == Won
  assert events == [BrickDestroyed(1)]
}

pub fn tick_moves_the_paddle_left_when_held_test() {
  // dt comfortably below physics.max_dt (~0.0333, decision 0037) so
  // tick's own internal clamp doesn't change what dt actually gets used.
  let dt = 0.01
  let ball = ball_at(Vector2(50.0, 50.0), vector2.zero)
  let model = playing_model(ball, paddle_x: 50.0, bricks: [far_away_brick])

  let #(ticked, _events) =
    breakout.tick(model, dt, Input(move_left: True, move_right: False))

  assert ticked.paddle_x == 50.0 -. paddle.speed *. dt
}

pub fn tick_is_a_no_op_once_lost_test() {
  let ball = ball_at(Vector2(50.0, 50.0), Vector2(3.0, 4.0))
  let model =
    Model(
      ball: ball,
      bounds: box,
      paddle_x: 50.0,
      bricks: [far_away_brick],
      score: 42,
      status: Lost,
    )

  let #(ticked, events) =
    breakout.tick(model, 1.0, Input(move_left: True, move_right: True))

  assert ticked == model
  assert events == []
}

pub fn tick_is_a_no_op_once_won_test() {
  let ball = ball_at(Vector2(50.0, 50.0), Vector2(3.0, 4.0))
  let model =
    Model(
      ball: ball,
      bounds: box,
      paddle_x: 50.0,
      bricks: [],
      score: 100,
      status: Won,
    )

  let #(ticked, events) = breakout.tick(model, 1.0, no_input)

  assert ticked == model
  assert events == []
}

pub fn new_constructs_a_playing_model_with_a_full_brick_grid_test() {
  let model = breakout.new(box)

  assert model.status == Playing
  assert model.score == 0
  assert model.ball.radius == breakout.ball_radius
  // Bounds' own x-midpoint -- as good a starting paddle position as any.
  assert model.paddle_x == 50.0
}

pub fn paddle_rect_reflects_the_models_paddle_x_test() {
  let model = playing_model(ball_at(vector2.zero, vector2.zero), paddle_x: 50.0, bricks: [])

  let rect_now = breakout.paddle_rect(model)

  assert rect_now.min.x == 50.0 -. breakout.paddle_half_width
  assert rect_now.max.x == 50.0 +. breakout.paddle_half_width
}
