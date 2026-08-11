//// Breakout's multiplayer *client* runner.
////
//// JavaScript-target only, same split as `game_breakout.gleam`. Unlike
//// that single-player runner, this one never calls `breakout.tick`
//// itself -- `game_breakout_server.gleam`'s room actor is the sole
//// simulation authority (see that module's own doc comment), so this
//// runner has exactly two jobs, running independently of each other:
////
//// - **Input**: an ordinary `requestAnimationFrame` loop polls held keys
////   (`glemy/io`, same as the single-player runner) and sends a message
////   to the server only when the held state actually changes, not every
////   frame.
//// - **Render**: driven by the WebSocket itself, not by the frame loop
////   -- every `welcome`/`snapshot` message decoded off the wire is a
////   complete description of what to draw, so a render happens exactly
////   when a new one arrives.
////
//// Reuses `glemy_games/games/breakout`'s own `paddle_rect`/`colored_ball`
//// (both operate on a `breakout.Model`) by wrapping each decoded
//// snapshot in one with `bricks: []` -- bricks aren't needed by either
//// function (see this module's own `synced_model`), and this repo has
//// no reason to duplicate that rectangle math client-side just because
//// the ball/paddle themselves now arrive over the network instead of
//// from a local `tick` call.

import gleam/dynamic/decode
import gleam/javascript/promise
import gleam/json
import gleam/list
import glemy/io
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/rect
import glemy/physics/bounds.{Bounds}
import glemy/physics/vector2.{Vector2}
import glemy/render.{type Canvas}
import glemy_games/game_breakout
import glemy_games/games/breakout

/// The play field this client renders into -- must match
/// `game_breakout_server.gleam`'s own `play_bounds` exactly (see that
/// constant's own doc comment for why this isn't sent over the wire).
const play_bounds = Bounds(min: vector2.zero, max: Vector2(100.0, 100.0))

/// Fixed, single-room dev address -- this pilot has no matchmaking or
/// multiple rooms (see the multiplayer architecture writeup this module
/// implements), just one `mist` server on a well-known port.
const server_url = "ws://localhost:4001/ws/breakout"

/// `pub` purely for direct testability of `server_message_decoder` below
/// -- the same reasoning `game_breakout_server.gleam`'s own protocol
/// functions are `pub` for.
pub type ServerMessage {
  WelcomeMsg(model: breakout.Model, bricks: List(#(Int, rect.Rect)))
  SnapshotMsg(model: breakout.Model, events: List(breakout.GameEvent))
}

/// Wraps a decoded ball/paddle/score/status in a `breakout.Model` so this
/// module can reuse `breakout.paddle_rect`/`breakout.colored_ball`
/// directly -- `bricks: []` is fine, see this module's own doc comment.
fn synced_model(
  ball: Entity,
  paddle_x: Float,
  score: Int,
  status: breakout.GameStatus,
) -> breakout.Model {
  breakout.Model(
    ball: ball,
    bounds: play_bounds,
    paddle_x: paddle_x,
    bricks: [],
    score: score,
    status: status,
  )
}

fn ball_decoder() -> decode.Decoder(Entity) {
  use x <- decode.field("x", decode.float)
  use y <- decode.field("y", decode.float)
  use vx <- decode.field("vx", decode.float)
  use vy <- decode.field("vy", decode.float)
  decode.success(Entity(
    position: Vector2(x, y),
    velocity: Vector2(vx, vy),
    radius: breakout.ball_radius,
    kind: 0,
    resting_time: 0.0,
  ))
}

fn status_decoder() -> decode.Decoder(breakout.GameStatus) {
  use tag <- decode.then(decode.string)
  case tag {
    "won" -> decode.success(breakout.Won)
    "lost" -> decode.success(breakout.Lost)
    _ -> decode.success(breakout.Playing)
  }
}

fn brick_decoder() -> decode.Decoder(#(Int, rect.Rect)) {
  use id <- decode.field("id", decode.int)
  use min_x <- decode.field("min_x", decode.float)
  use min_y <- decode.field("min_y", decode.float)
  use max_x <- decode.field("max_x", decode.float)
  use max_y <- decode.field("max_y", decode.float)
  decode.success(#(
    id,
    rect.Rect(min: Vector2(min_x, min_y), max: Vector2(max_x, max_y)),
  ))
}

fn event_decoder() -> decode.Decoder(breakout.GameEvent) {
  use tag <- decode.field("type", decode.string)
  case tag {
    "brick_destroyed" -> {
      use id <- decode.field("id", decode.int)
      decode.success(breakout.BrickDestroyed(id))
    }
    "ball_lost" -> decode.success(breakout.BallLost)
    _ -> decode.success(breakout.BallBounced)
  }
}

fn welcome_decoder() -> decode.Decoder(ServerMessage) {
  use ball <- decode.field("ball", ball_decoder())
  use paddle_x <- decode.field("paddle_x", decode.float)
  use bricks <- decode.field("bricks", decode.list(brick_decoder()))
  use score <- decode.field("score", decode.int)
  use status <- decode.field("status", status_decoder())
  decode.success(WelcomeMsg(
    synced_model(ball, paddle_x, score, status),
    bricks,
  ))
}

fn snapshot_decoder() -> decode.Decoder(ServerMessage) {
  use ball <- decode.field("ball", ball_decoder())
  use paddle_x <- decode.field("paddle_x", decode.float)
  use score <- decode.field("score", decode.int)
  use status <- decode.field("status", status_decoder())
  use events <- decode.field("events", decode.list(event_decoder()))
  decode.success(SnapshotMsg(
    synced_model(ball, paddle_x, score, status),
    events,
  ))
}

pub fn server_message_decoder() -> decode.Decoder(ServerMessage) {
  use tag <- decode.field("type", decode.string)
  case tag {
    "welcome" -> welcome_decoder()
    _ -> snapshot_decoder()
  }
}

pub fn encode_input(input: breakout.Input) -> String {
  json.object([
    #("move_left", json.bool(input.move_left)),
    #("move_right", json.bool(input.move_right)),
  ])
  |> json.to_string
}

@target(javascript)
@external(javascript, "./game_ffi.mjs", "requestFrame")
fn request_frame(callback: fn(Float) -> Nil) -> Nil

@target(javascript)
@external(javascript, "./game_breakout_ffi.mjs", "setScoreText")
fn set_score_text(text: String) -> Nil

@target(javascript)
@external(javascript, "./game_ffi.mjs", "setElementVisibilityMessage")
fn set_element_visibility_message(
  element_id: String,
  visible: Bool,
  message: String,
) -> Nil

@target(javascript)
fn set_status_message(visible: Bool, message: String) -> Nil {
  set_element_visibility_message("glemy-status", visible, message)
}

@target(javascript)
@external(javascript, "./game_breakout_ffi.mjs", "setPaddleBox")
fn set_paddle_box(left: Float, top: Float, width: Float, height: Float) -> Nil

@target(javascript)
@external(javascript, "./game_breakout_ffi.mjs", "createBrickElements")
fn create_brick_elements(
  bricks: List(#(Int, Float, Float, Float, Float)),
) -> Nil

@target(javascript)
@external(javascript, "./game_breakout_ffi.mjs", "hideBrickElement")
fn hide_brick_element(id: Int) -> Nil

@target(javascript)
@external(javascript, "./game_breakout_ffi.mjs", "playBounceSound")
fn play_bounce_sound() -> Nil

@target(javascript)
@external(javascript, "./game_breakout_ffi.mjs", "playBrickSound")
fn play_brick_sound() -> Nil

@target(javascript)
fn play_game_event(event: breakout.GameEvent) -> Nil {
  case event {
    breakout.BallBounced -> play_bounce_sound()
    breakout.BrickDestroyed(id) -> {
      play_brick_sound()
      hide_brick_element(id)
    }
    breakout.BallLost -> Nil
  }
}

/// A raw JS `WebSocket` handle -- opaque, since nothing on the Gleam side
/// ever inspects it directly, only passes it back to `ws_send`.
@target(javascript)
type WebSocketHandle

@target(javascript)
@external(javascript, "./game_breakout_multiplayer_ffi.mjs", "wsConnect")
fn ws_connect(
  url: String,
  on_message: fn(String) -> Nil,
  on_open: fn() -> Nil,
) -> WebSocketHandle

@target(javascript)
@external(javascript, "./game_breakout_multiplayer_ffi.mjs", "wsSend")
fn ws_send(socket: WebSocketHandle, text: String) -> Nil

@target(javascript)
fn render_and_update(model: breakout.Model, canvas: Canvas) -> Nil {
  render.render_entities_to_canvas(
    breakout.colored_ball(model),
    model.bounds,
    canvas,
  )
  |> promise.map(fn(_result) { Nil })
  set_score_text(game_breakout.format_score(model.score))
  case model.status {
    breakout.Won -> set_status_message(True, "You win!")
    breakout.Lost -> set_status_message(True, "Game over!")
    breakout.Playing -> Nil
  }
  let #(left, top, width, height) =
    rect.to_css(breakout.paddle_rect(model), model.bounds)
  set_paddle_box(left, top, width, height)
}

@target(javascript)
fn on_server_message(text: String, canvas: Canvas) -> Nil {
  case json.parse(text, server_message_decoder()) {
    Ok(WelcomeMsg(model, bricks)) -> {
      create_brick_elements(
        list.map(bricks, fn(pair) {
          let #(id, brick_rect) = pair
          let #(left, top, width, height) = rect.to_css(brick_rect, play_bounds)
          #(id, left, top, width, height)
        }),
      )
      render_and_update(model, canvas)
    }
    Ok(SnapshotMsg(model, events)) -> {
      list.each(events, play_game_event)
      render_and_update(model, canvas)
    }
    Error(_) -> Nil
  }
}

@target(javascript)
fn input_loop(socket: WebSocketHandle, last_sent: breakout.Input) -> Nil {
  request_frame(fn(_timestamp) {
    let input =
      breakout.Input(
        move_left: io.is_key_down("ArrowLeft"),
        move_right: io.is_key_down("ArrowRight"),
      )
    case input == last_sent {
      True -> Nil
      False -> ws_send(socket, encode_input(input))
    }
    input_loop(socket, input)
  })
}

@target(javascript)
/// Connects to `server_url`, then starts the input-polling loop -- see
/// this module's own doc comment for why rendering isn't driven from
/// here too.
pub fn start(canvas: Canvas) -> Nil {
  let socket =
    ws_connect(server_url, fn(text) { on_server_message(text, canvas) }, fn() {
      Nil
    })
  input_loop(socket, breakout.Input(move_left: False, move_right: False))
}

@target(javascript)
/// A concrete, ready-to-run game: `breakout_multiplayer.html` calls this
/// directly, mirroring `game_breakout.main`.
pub fn main() -> Nil {
  let canvas = render.get_canvas("glemy-canvas")
  start(canvas)
}
