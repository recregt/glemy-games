import gleam/list
import gleam/option.{None, Some}
import glemy_games/games/breakout/brick.{Brick}
import glemy/physics/rect.{Rect}
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/vector2.{type Vector2, Vector2}

const field = Rect(min: Vector2(0.0, 0.0), max: Vector2(100.0, 100.0))

pub fn grid_produces_rows_times_columns_bricks_test() {
  let bricks =
    brick.grid(
      rows: 3,
      columns: 4,
      bounds: field,
      top_margin: 10.0,
      brick_height: 5.0,
      spacing: 2.0,
      score_per_brick: 10,
    )

  assert list.length(bricks) == 12
}

pub fn grid_lays_out_bricks_evenly_spanning_the_field_width_test() {
  let bricks =
    brick.grid(
      rows: 1,
      columns: 2,
      bounds: field,
      top_margin: 10.0,
      brick_height: 5.0,
      spacing: 2.0,
      score_per_brick: 10,
    )

  // field width 100.0, spacing 2.0, 2 columns -> brick_width =
  // (100.0 - 2.0*3) / 2 = 47.0. First brick starts 2.0 in from the left
  // edge; the second starts immediately after the first plus one gap.
  assert bricks
    == [
      Brick(
        id: 0,
        rect: Rect(min: Vector2(2.0, 85.0), max: Vector2(49.0, 90.0)),
        score: 10,
      ),
      Brick(
        id: 1,
        rect: Rect(min: Vector2(51.0, 85.0), max: Vector2(98.0, 90.0)),
        score: 10,
      ),
    ]
}

pub fn grid_assigns_stable_row_major_ids_test() {
  let bricks =
    brick.grid(
      rows: 2,
      columns: 3,
      bounds: field,
      top_margin: 10.0,
      brick_height: 5.0,
      spacing: 2.0,
      score_per_brick: 10,
    )

  assert list.map(bricks, fn(b) { b.id }) == [0, 1, 2, 3, 4, 5]
}

pub fn grid_stacks_rows_downward_from_the_top_margin_test() {
  let bricks =
    brick.grid(
      rows: 2,
      columns: 1,
      bounds: field,
      top_margin: 10.0,
      brick_height: 5.0,
      spacing: 2.0,
      score_per_brick: 10,
    )

  let assert [row_0, row_1] = bricks
  // Row 0's top edge is at bounds.max.y - top_margin (90.0); row 1
  // starts one brick_height + spacing further down.
  assert row_0.rect.max.y == 90.0
  assert row_1.rect.max.y == 90.0 -. { 5.0 +. 2.0 }
}

pub fn grid_carries_the_given_score_on_every_brick_test() {
  let bricks =
    brick.grid(
      rows: 1,
      columns: 3,
      bounds: field,
      top_margin: 10.0,
      brick_height: 5.0,
      spacing: 2.0,
      score_per_brick: 25,
    )

  assert list.all(bricks, fn(b) { b.score == 25 })
}

fn ball_at(position: Vector2, velocity: Vector2) -> Entity {
  Entity(
    position: position,
    velocity: velocity,
    radius: 1.0,
    kind: 0,
    resting_time: 0.0,
  )
}

const brick_rect = Rect(min: Vector2(0.0, 0.0), max: Vector2(10.0, 10.0))

pub fn reflect_flips_horizontal_velocity_when_hit_from_the_side_test() {
  let ball = ball_at(Vector2(15.0, 5.0), Vector2(-3.0, 4.0))

  let reflected = brick.reflect(ball, brick_rect)

  assert reflected.velocity == Vector2(3.0, 4.0)
}

pub fn reflect_flips_vertical_velocity_when_hit_from_above_test() {
  let ball = ball_at(Vector2(5.0, 15.0), Vector2(3.0, -4.0))

  let reflected = brick.reflect(ball, brick_rect)

  assert reflected.velocity == Vector2(3.0, 4.0)
}

pub fn reflect_does_not_change_position_test() {
  // Unlike paddle.reflect, brick.reflect needs no position correction --
  // the brick it hit is about to be removed from the game entirely.
  let ball = ball_at(Vector2(15.0, 5.0), Vector2(-3.0, 4.0))

  let reflected = brick.reflect(ball, brick_rect)

  assert reflected.position == ball.position
}

pub fn resolve_first_hit_with_no_overlap_is_none_test() {
  let ball = ball_at(Vector2(500.0, 500.0), Vector2(1.0, 1.0))
  let bricks = [Brick(id: 0, rect: brick_rect, score: 10)]

  assert brick.resolve_first_hit(ball, bricks) == None
}

pub fn resolve_first_hit_with_an_empty_list_is_none_test() {
  let ball = ball_at(Vector2(5.0, 5.0), Vector2(1.0, 1.0))

  assert brick.resolve_first_hit(ball, []) == None
}

pub fn resolve_first_hit_removes_exactly_the_hit_brick_test() {
  let ball = ball_at(Vector2(5.0, 5.0), Vector2(0.0, -4.0))
  let hit_brick = Brick(id: 7, rect: brick_rect, score: 10)
  let bricks = [hit_brick]

  let assert Some(hit) = brick.resolve_first_hit(ball, bricks)

  assert hit.remaining == []
  assert hit.score == 10
  assert hit.destroyed_id == 7
}

pub fn resolve_first_hit_leaves_non_overlapping_bricks_in_place_test() {
  let ball = ball_at(Vector2(5.0, 5.0), Vector2(0.0, -4.0))
  let hit_brick = Brick(id: 1, rect: brick_rect, score: 10)
  let far_away =
    Brick(
      id: 2,
      rect: Rect(min: Vector2(500.0, 500.0), max: Vector2(510.0, 510.0)),
      score: 20,
    )
  let bricks = [far_away, hit_brick]

  let assert Some(hit) = brick.resolve_first_hit(ball, bricks)

  assert hit.remaining == [far_away]
  assert hit.score == 10
  assert hit.destroyed_id == 1
}

pub fn resolve_first_hit_resolves_only_the_first_overlapping_brick_in_list_order_test() {
  // Two overlapping (adjacent) bricks the ball's own position happens to
  // overlap simultaneously -- only the first in list order is resolved;
  // the second is left completely untouched for next frame.
  let overlapping_a = Brick(id: 0, rect: brick_rect, score: 10)
  let overlapping_b =
    Brick(
      id: 1,
      rect: Rect(min: Vector2(9.0, 0.0), max: Vector2(19.0, 10.0)),
      score: 20,
    )
  let ball = ball_at(Vector2(9.5, 5.0), Vector2(0.0, -4.0))

  let assert Some(hit) =
    brick.resolve_first_hit(ball, [overlapping_a, overlapping_b])

  assert hit.remaining == [overlapping_b]
  assert hit.score == 10
  assert hit.destroyed_id == 0
}

pub fn resolve_first_hit_preserves_bricks_before_the_hit_one_test() {
  // A brick earlier in the list than the one actually hit stays in
  // place, in its original relative position -- resolve_first_hit's own
  // recursion has to thread it back through correctly, not just drop or
  // reorder it.
  let before =
    Brick(
      id: 0,
      rect: Rect(min: Vector2(500.0, 500.0), max: Vector2(510.0, 510.0)),
      score: 5,
    )
  let hit_brick = Brick(id: 1, rect: brick_rect, score: 10)
  let ball = ball_at(Vector2(5.0, 5.0), Vector2(0.0, -4.0))

  let assert Some(hit) = brick.resolve_first_hit(ball, [before, hit_brick])

  assert hit.remaining == [before]
}
