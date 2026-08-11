//// Covers the pure wire-protocol logic `game_breakout_multiplayer.gleam`
//// exposes as `pub` specifically for this -- the WebSocket/render/input
//// loop around it is a "live-system" concern (a real `requestAnimationFrame`
//// loop, a real socket), not something `gleam test` can exercise for
//// real; see this repo's smoke-test notes for how that part is verified
//// instead. These decoders are the client-side mirror of
//// `game_breakout_server_test.gleam`'s own encoder tests -- together
//// they're the closest thing this pilot has to an end-to-end protocol
//// contract test, without needing a live socket on either side.

import gleam/json
import glemy_games/game_breakout_multiplayer.{SnapshotMsg, WelcomeMsg}
import glemy_games/games/breakout.{
  BallBounced, BallLost, BrickDestroyed, Input, Lost, Model, Playing,
}
import glemy/physics/bounds.{Bounds}
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/rect.{Rect}
import glemy/physics/vector2.{Vector2}

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

pub fn encode_input_round_trips_through_the_servers_own_shape_test() {
  assert game_breakout_multiplayer.encode_input(Input(
      move_left: True,
      move_right: False,
    ))
    == "{\"move_left\":true,\"move_right\":false}"
}

pub fn welcome_decoder_reads_ball_paddle_bricks_score_and_status_test() {
  let payload =
    "{\"type\":\"welcome\",\"ball\":{\"x\":0.0,\"y\":0.0,\"vx\":1.0,\"vy\":2.0},\"paddle_x\":50.0,\"bricks\":[{\"id\":1,\"min_x\":0.0,\"min_y\":0.0,\"max_x\":5.0,\"max_y\":5.0}],\"score\":10,\"status\":\"playing\"}"

  let assert Ok(WelcomeMsg(model, bricks)) =
    json.parse(payload, game_breakout_multiplayer.server_message_decoder())

  assert model
    == Model(
      ball: ball_at(0.0, 0.0),
      bounds: box,
      paddle_x: 50.0,
      bricks: [],
      score: 10,
      status: Playing,
    )
  assert bricks == [#(1, Rect(min: Vector2(0.0, 0.0), max: Vector2(5.0, 5.0)))]
}

pub fn snapshot_decoder_reads_events_including_a_brick_destroyed_id_test() {
  let payload =
    "{\"type\":\"snapshot\",\"ball\":{\"x\":10.0,\"y\":20.0,\"vx\":1.0,\"vy\":2.0},\"paddle_x\":40.0,\"score\":20,\"status\":\"lost\",\"events\":[{\"type\":\"ball_bounced\"},{\"type\":\"brick_destroyed\",\"id\":7},{\"type\":\"ball_lost\"}]}"

  let assert Ok(SnapshotMsg(model, events)) =
    json.parse(payload, game_breakout_multiplayer.server_message_decoder())

  assert model
    == Model(
      ball: ball_at(10.0, 20.0),
      bounds: box,
      paddle_x: 40.0,
      bricks: [],
      score: 20,
      status: Lost,
    )
  assert events == [BallBounced, BrickDestroyed(id: 7), BallLost]
}

pub fn server_message_decoder_rejects_malformed_json_test() {
  let assert Error(_) =
    json.parse("not json", game_breakout_multiplayer.server_message_decoder())
}
