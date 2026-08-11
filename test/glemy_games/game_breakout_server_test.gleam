//// Covers the pure protocol/merge logic `game_breakout_server.gleam`
//// exposes as `pub` specifically for this -- the actor/socket wiring
//// around it (room lifecycle, `mist` handlers) is a "live-system"
//// concern per this repo's own `ARCHITECTURE.md` DevOps-tooling section,
//// not something `gleam test` can exercise for real; see this repo's
//// smoke-test notes for how that part is verified instead.

import gleam/erlang/process
import glemy_games/game_breakout_server
import glemy_games/games/breakout.{
  BallBounced, BallLost, BrickDestroyed, Input, Model, Playing, Won,
}
import glemy_games/games/breakout/brick.{Brick}
import glemy/physics/bounds.{Bounds}
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/rect.{Rect}
import glemy/physics/vector2.{Vector2}

const no_input = Input(move_left: False, move_right: False)

@target(erlang)
pub fn merge_inputs_with_no_players_is_all_false_test() {
  assert game_breakout_server.merge_inputs([]) == no_input
}

@target(erlang)
pub fn merge_inputs_ors_every_players_held_keys_test() {
  let left_player = process.new_subject()
  let right_player = process.new_subject()
  let inputs = [
    #(left_player, Input(move_left: True, move_right: False)),
    #(right_player, Input(move_left: False, move_right: True)),
  ]

  assert game_breakout_server.merge_inputs(inputs)
    == Input(move_left: True, move_right: True)
}

@target(erlang)
pub fn merge_inputs_with_nobody_holding_anything_is_all_false_test() {
  let player = process.new_subject()
  let inputs = [#(player, no_input)]

  assert game_breakout_server.merge_inputs(inputs) == no_input
}

@target(erlang)
pub fn decode_input_reads_a_valid_payload_test() {
  assert game_breakout_server.decode_input(
      "{\"move_left\":true,\"move_right\":false}",
    )
    == Ok(Input(move_left: True, move_right: False))
}

@target(erlang)
pub fn decode_input_rejects_malformed_json_test() {
  assert game_breakout_server.decode_input("not json") == Error(Nil)
}

@target(erlang)
pub fn decode_input_rejects_a_payload_missing_a_field_test() {
  assert game_breakout_server.decode_input("{\"move_left\":true}") == Error(Nil)
}

const box = Bounds(min: Vector2(0.0, 0.0), max: Vector2(100.0, 100.0))

fn ball_at(x: Float, y: Float) -> Entity {
  Entity(
    position: Vector2(x, y),
    velocity: Vector2(1.0, 2.0),
    radius: breakout.ball_radius,
    kind: 0,
    resting_time: 0.0,
  )
}

@target(erlang)
pub fn encode_snapshot_matches_the_documented_wire_shape_test() {
  let model =
    Model(
      ball: ball_at(10.0, 20.0),
      bounds: box,
      paddle_x: 50.0,
      bricks: [],
      score: 30,
      status: Won,
    )

  assert game_breakout_server.encode_snapshot(model, [
      BallBounced,
      BrickDestroyed(id: 3),
      BallLost,
    ])
    == "{\"type\":\"snapshot\",\"ball\":{\"x\":10.0,\"y\":20.0,\"vx\":1.0,\"vy\":2.0},\"paddle_x\":50.0,\"score\":30,\"status\":\"won\",\"events\":[{\"type\":\"ball_bounced\"},{\"type\":\"brick_destroyed\",\"id\":3},{\"type\":\"ball_lost\"}]}"
}

@target(erlang)
pub fn encode_welcome_includes_still_standing_bricks_test() {
  let model =
    Model(
      ball: ball_at(0.0, 0.0),
      bounds: box,
      paddle_x: 50.0,
      bricks: [
        Brick(
          id: 1,
          rect: Rect(min: Vector2(0.0, 0.0), max: Vector2(5.0, 5.0)),
          score: 10,
        ),
      ],
      score: 0,
      status: Playing,
    )

  assert game_breakout_server.encode_welcome(model)
    == "{\"type\":\"welcome\",\"ball\":{\"x\":0.0,\"y\":0.0,\"vx\":1.0,\"vy\":2.0},\"paddle_x\":50.0,\"bricks\":[{\"id\":1,\"min_x\":0.0,\"min_y\":0.0,\"max_x\":5.0,\"max_y\":5.0}],\"score\":0,\"status\":\"playing\"}"
}
