import gleam/float
import glemy_games/games/breakout/paddle
import glemy/physics/rect.{Rect}
import glemy/physics/bounds.{Bounds}
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/vector2.{type Vector2, Vector2}

const play_bounds = Bounds(min: Vector2(0.0, 0.0), max: Vector2(100.0, 100.0))

pub fn move_left_decreases_x_test() {
  assert paddle.move(50.0, 0.1, True, False, 10.0, play_bounds)
    == 50.0 -. paddle.speed *. 0.1
}

pub fn move_right_increases_x_test() {
  assert paddle.move(50.0, 0.1, False, True, 10.0, play_bounds)
    == 50.0 +. paddle.speed *. 0.1
}

pub fn move_both_held_cancels_out_test() {
  assert paddle.move(50.0, 0.1, True, True, 10.0, play_bounds) == 50.0
}

pub fn move_neither_held_stays_put_test() {
  assert paddle.move(50.0, 0.1, False, False, 10.0, play_bounds) == 50.0
}

pub fn move_clamps_at_the_left_edge_test() {
  // Effective range for half_width 10.0 in a 0.0-100.0 field is
  // [10.0, 90.0]. Starting near the edge with a large dt overshoots it.
  assert paddle.move(12.0, 1.0, True, False, 10.0, play_bounds) == 10.0
}

pub fn move_clamps_at_the_right_edge_test() {
  assert paddle.move(88.0, 1.0, False, True, 10.0, play_bounds) == 90.0
}

const paddle_rect = Rect(min: Vector2(40.0, 0.0), max: Vector2(60.0, 5.0))

fn ball_at(position: Vector2, velocity: Vector2, radius: Float) -> Entity {
  Entity(
    position: position,
    velocity: velocity,
    radius: radius,
    kind: 0,
    resting_time: 0.0,
  )
}

pub fn reflect_hit_dead_center_has_zero_horizontal_velocity_test() {
  let ball = ball_at(Vector2(50.0, 3.0), Vector2(0.0, -8.0), 1.0)

  let reflected = paddle.reflect(ball, paddle_rect)

  assert reflected.velocity.x == 0.0
  assert reflected.velocity.y == 8.0
}

pub fn reflect_hit_at_the_right_edge_deflects_maximally_right_test() {
  let ball = ball_at(Vector2(60.0, 3.0), Vector2(0.0, -8.0), 1.0)

  let reflected = paddle.reflect(ball, paddle_rect)

  assert reflected.velocity.x == 1.0 *. 0.9 *. 8.0
}

pub fn reflect_hit_at_the_left_edge_deflects_maximally_left_test() {
  let ball = ball_at(Vector2(40.0, 3.0), Vector2(0.0, -8.0), 1.0)

  let reflected = paddle.reflect(ball, paddle_rect)

  assert reflected.velocity.x == -1.0 *. 0.9 *. 8.0
}

pub fn reflect_clamps_hit_positions_beyond_the_paddle_edge_test() {
  // A hit position past the paddle's own edge -- a real scenario, since
  // the ball's own radius means contact can register slightly beyond
  // the paddle's rect -- deflects at the same maximum as exactly at the
  // edge, not further.
  let ball = ball_at(Vector2(65.0, 3.0), Vector2(0.0, -8.0), 1.0)

  let reflected = paddle.reflect(ball, paddle_rect)

  assert reflected.velocity.x == 1.0 *. 0.9 *. 8.0
}

pub fn reflect_preserves_total_speed_test() {
  let ball = ball_at(Vector2(55.0, 3.0), Vector2(3.0, -8.0), 1.0)
  let incoming_speed = vector2.length(ball.velocity)

  let reflected = paddle.reflect(ball, paddle_rect)

  let outgoing_speed = vector2.length(reflected.velocity)
  assert float.loosely_equals(outgoing_speed, incoming_speed, 0.0001)
}

pub fn reflect_vertical_velocity_is_always_positive_test() {
  // Even if the incoming ball is already moving downward when it hits
  // (a real scenario -- e.g. after a shallow-angle brick bounce sends
  // it back toward the paddle), the outgoing vy is always positive,
  // toward the bricks.
  let ball = ball_at(Vector2(50.0, 3.0), Vector2(2.0, -6.0), 1.0)

  let reflected = paddle.reflect(ball, paddle_rect)

  assert reflected.velocity.y >. 0.0
}

pub fn reflect_corrects_the_balls_position_just_above_the_paddle_test() {
  let ball = ball_at(Vector2(50.0, 4.5), Vector2(0.0, -8.0), 1.0)

  let reflected = paddle.reflect(ball, paddle_rect)

  assert reflected.position == Vector2(50.0, 5.0 +. 1.0)
}

pub fn reflect_does_not_change_horizontal_position_test() {
  let ball = ball_at(Vector2(55.0, 3.0), Vector2(0.0, -8.0), 1.0)

  let reflected = paddle.reflect(ball, paddle_rect)

  assert reflected.position.x == 55.0
}
