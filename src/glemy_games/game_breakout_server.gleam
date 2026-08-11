//// Breakout's multiplayer server runner.
////
//// Erlang-target only (mirrors how `game_breakout.gleam` is JavaScript-
//// target only, and `glemy/io`'s own "every single function gated"
//// pattern for a fully single-target module): one OTP actor ("the
//// room") holds the single authoritative
//// `glemy_games/games/breakout.Model` and calls the exact same
//// `breakout.tick` the single-player browser runner calls, on a
//// fixed-rate self-scheduled loop -- no server-side reimplementation of
//// the game rules to drift from the client. Every connected player's
//// held-key state is merged (boolean OR) into one `breakout.Input` each
//// tick, which is what makes this co-op rather than requiring a second
//// paddle: any number of players share control of the one paddle.
////
//// One process per WebSocket connection (managed by `mist`) forwards
//// that connection's input to the room and relays the room's broadcast
//// snapshots back out as text frames -- `mist` requires frames to be
//// sent from the connection's own process (see `mist.send_text_frame`'s
//// own doc comment), so the room can't push to a socket directly; it
//// sends a `ClientMessage` to that connection's own mailbox instead,
//// which its `mist.websocket` selector picks up.

import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process.{type Subject}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option.{type Option, Some}
import gleam/otp/actor
import gleam/result
import glemy/physics
import glemy/physics/bounds.{Bounds}
import glemy/physics/entity.{type Entity}
import glemy/physics/vector2.{Vector2}
import glemy_games/games/breakout.{type Model}
import glemy_games/games/breakout/brick.{type Brick}
import mist.{type Connection, type ResponseData}

@target(erlang)
/// The play field every room is created with -- fixed and identical to
/// the single-player runner's own `main` (`game_breakout.gleam`), since
/// there's currently no shared constant for it there either (each
/// runner's `main` hardcodes its own, matching `game_tiers.gleam`'s
/// same pattern). A client must construct the identical `Bounds` itself
/// to interpret world-space coordinates the same way.
pub const play_bounds = Bounds(min: vector2.zero, max: Vector2(100.0, 100.0))

@target(erlang)
/// How often the room ticks, in milliseconds -- `physics.max_dt` (1/30s)
/// rounded to the nearest millisecond, used below as the tick's fixed
/// `dt` too. A real fixed-timestep loop (unlike the browser runner's own
/// `requestAnimationFrame`-measured `dt`): the room is the only
/// timekeeper here, so there's no real elapsed time to measure against.
const tick_interval_ms = 33

@target(erlang)
/// Messages the room actor receives -- from connection processes only,
/// plus its own self-scheduled `Tick`.
pub type RoomMessage {
  Tick
  Join(client: Subject(ClientMessage))
  Leave(client: Subject(ClientMessage))
  PlayerInput(client: Subject(ClientMessage), input: breakout.Input)
}

@target(erlang)
/// Messages the room sends to one connection's own process, which that
/// connection's `mist.websocket` handler relays out as a text frame --
/// see this module's own doc comment for why it can't send the frame
/// itself. `Welcome` is sent once, right after `Join`, carrying enough
/// state (including still-standing bricks) for a newly-connected client
/// to draw a game already in progress; `Snapshot` is sent every tick
/// after that.
pub type ClientMessage {
  Welcome(json: String)
  Snapshot(json: String)
}

@target(erlang)
type RoomState {
  RoomState(
    self: Subject(RoomMessage),
    model: Model,
    players: List(Subject(ClientMessage)),
    inputs: List(#(Subject(ClientMessage), breakout.Input)),
  )
}

@target(erlang)
fn start_room() -> actor.StartResult(Subject(RoomMessage)) {
  actor.new_with_initialiser(1000, fn(self) {
    process.send_after(self, tick_interval_ms, Tick)
    actor.initialised(RoomState(
      self: self,
      model: breakout.new(play_bounds),
      players: [],
      inputs: [],
    ))
    |> actor.returning(self)
    |> Ok
  })
  |> actor.on_message(handle_room_message)
  |> actor.start()
}

@target(erlang)
fn handle_room_message(
  state: RoomState,
  message: RoomMessage,
) -> actor.Next(RoomState, RoomMessage) {
  case message {
    Join(client) -> {
      process.send(client, Welcome(encode_welcome(state.model)))
      actor.continue(RoomState(..state, players: [client, ..state.players]))
    }

    Leave(client) ->
      actor.continue(
        RoomState(
          ..state,
          players: list.filter(state.players, fn(p) { p != client }),
          inputs: list.filter(state.inputs, fn(pair) { pair.0 != client }),
        ),
      )

    PlayerInput(client, input) ->
      actor.continue(
        RoomState(..state, inputs: upsert_input(state.inputs, client, input)),
      )

    Tick -> {
      process.send_after(state.self, tick_interval_ms, Tick)
      case state.players {
        // Nobody connected to catch the ball -- leave the model exactly
        // as it was rather than let the game free-fall to `Lost` (and
        // freeze there, per `breakout.tick`'s own documented contract)
        // before a first player ever gets a chance to play. Still
        // reschedules the next `Tick` above so play resumes the instant
        // someone joins, rather than needing a second message kind to
        // re-arm the loop.
        [] -> actor.continue(state)
        _ -> {
          let merged = merge_inputs(state.inputs)
          let #(next_model, events) =
            breakout.tick(state.model, physics.max_dt, merged)
          let snapshot = encode_snapshot(next_model, events)
          list.each(state.players, fn(client) {
            process.send(client, Snapshot(snapshot))
          })
          actor.continue(RoomState(..state, model: next_model))
        }
      }
    }
  }
}

@target(erlang)
fn upsert_input(
  inputs: List(#(Subject(ClientMessage), breakout.Input)),
  client: Subject(ClientMessage),
  input: breakout.Input,
) -> List(#(Subject(ClientMessage), breakout.Input)) {
  [#(client, input), ..list.filter(inputs, fn(pair) { pair.0 != client })]
}

@target(erlang)
/// Every connected player's held keys, OR'd together -- see this
/// module's own doc comment for why that's what makes this co-op. `pub`
/// purely for direct testability: the actor/socket wiring around this
/// isn't practically unit-testable (see this repo's own
/// `game_breakout_server_test.gleam`), but the merge rule itself is pure
/// and worth testing directly, the same category as
/// `glemy_games/games/breakout`'s own pure helpers.
pub fn merge_inputs(
  inputs: List(#(Subject(ClientMessage), breakout.Input)),
) -> breakout.Input {
  list.fold(
    inputs,
    breakout.Input(move_left: False, move_right: False),
    fn(acc, pair) {
      breakout.Input(
        move_left: acc.move_left || pair.1.move_left,
        move_right: acc.move_right || pair.1.move_right,
      )
    },
  )
}

@target(erlang)
fn encode_ball(ball: Entity) -> json.Json {
  json.object([
    #("x", json.float(ball.position.x)),
    #("y", json.float(ball.position.y)),
    #("vx", json.float(ball.velocity.x)),
    #("vy", json.float(ball.velocity.y)),
  ])
}

@target(erlang)
fn encode_status(status: breakout.GameStatus) -> json.Json {
  json.string(case status {
    breakout.Playing -> "playing"
    breakout.Won -> "won"
    breakout.Lost -> "lost"
  })
}

@target(erlang)
fn encode_event(event: breakout.GameEvent) -> json.Json {
  case event {
    breakout.BallBounced -> json.object([#("type", json.string("ball_bounced"))])
    breakout.BrickDestroyed(id) ->
      json.object([
        #("type", json.string("brick_destroyed")),
        #("id", json.int(id)),
      ])
    breakout.BallLost -> json.object([#("type", json.string("ball_lost"))])
  }
}

@target(erlang)
fn encode_brick(b: Brick) -> json.Json {
  json.object([
    #("id", json.int(b.id)),
    #("min_x", json.float(b.rect.min.x)),
    #("min_y", json.float(b.rect.min.y)),
    #("max_x", json.float(b.rect.max.x)),
    #("max_y", json.float(b.rect.max.y)),
  ])
}

@target(erlang)
/// Sent once, right after `Join` -- includes `bricks` (this room's
/// currently-standing ones only) so a client joining mid-game can create
/// exactly the brick elements still in play, not a full fresh grid. Every
/// later `Snapshot` omits `bricks` entirely: a client learns of a brick's
/// destruction from that tick's own `events` instead (see
/// `encode_snapshot`), the same way the single-player runner already
/// drives `hide_brick_element` from `breakout.BrickDestroyed`, not from
/// diffing a bricks list.
pub fn encode_welcome(model: Model) -> String {
  json.object([
    #("type", json.string("welcome")),
    #("ball", encode_ball(model.ball)),
    #("paddle_x", json.float(model.paddle_x)),
    #("bricks", json.array(model.bricks, encode_brick)),
    #("score", json.int(model.score)),
    #("status", encode_status(model.status)),
  ])
  |> json.to_string
}

@target(erlang)
pub fn encode_snapshot(model: Model, events: List(breakout.GameEvent)) -> String {
  json.object([
    #("type", json.string("snapshot")),
    #("ball", encode_ball(model.ball)),
    #("paddle_x", json.float(model.paddle_x)),
    #("score", json.int(model.score)),
    #("status", encode_status(model.status)),
    #("events", json.array(events, encode_event)),
  ])
  |> json.to_string
}

@target(erlang)
fn input_decoder() -> decode.Decoder(breakout.Input) {
  use move_left <- decode.field("move_left", decode.bool)
  use move_right <- decode.field("move_right", decode.bool)
  decode.success(breakout.Input(move_left:, move_right:))
}

@target(erlang)
pub fn decode_input(text: String) -> Result(breakout.Input, Nil) {
  json.parse(text, input_decoder()) |> result.replace_error(Nil)
}

@target(erlang)
type ConnState {
  ConnState(room: Subject(RoomMessage), client: Subject(ClientMessage))
}

@target(erlang)
fn on_init(
  room: Subject(RoomMessage),
) -> #(ConnState, Option(process.Selector(ClientMessage))) {
  let client = process.new_subject()
  process.send(room, Join(client))
  let selector = process.new_selector() |> process.select(client)
  #(ConnState(room: room, client: client), Some(selector))
}

@target(erlang)
fn on_close(state: ConnState) -> Nil {
  process.send(state.room, Leave(state.client))
}

@target(erlang)
fn handle_ws_message(
  state: ConnState,
  message: mist.WebsocketMessage(ClientMessage),
  connection: mist.WebsocketConnection,
) -> mist.Next(ConnState, ClientMessage) {
  case message {
    mist.Text(text) -> {
      case decode_input(text) {
        Ok(input) -> process.send(state.room, PlayerInput(state.client, input))
        Error(Nil) -> Nil
      }
      mist.continue(state)
    }
    mist.Custom(Welcome(json)) | mist.Custom(Snapshot(json)) -> {
      let _ = mist.send_text_frame(connection, json)
      mist.continue(state)
    }
    mist.Binary(_) -> mist.continue(state)
    mist.Closed | mist.Shutdown -> mist.stop()
  }
}

@target(erlang)
fn handle_request(
  room: Subject(RoomMessage),
  req: Request(Connection),
) -> Response(ResponseData) {
  case request.path_segments(req) {
    ["ws", "breakout"] ->
      mist.websocket(
        request: req,
        handler: handle_ws_message,
        on_init: fn(_connection) { on_init(room) },
        on_close: on_close,
      )
    _ ->
      response.new(404)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

@target(erlang)
/// Starts the room actor, then a `mist` HTTP server whose only real route
/// is the `/ws/breakout` WebSocket upgrade -- static files (the compiled
/// client, `breakout_multiplayer.html`) are served the same way this
/// repo's other games already are in development (`deno run
/// jsr:@std/http/file-server`), not by this server.
pub fn main() -> Nil {
  let assert Ok(room) = start_room()
  let assert Ok(_) =
    mist.new(handle_request(room.data, _))
    |> mist.port(4001)
    |> mist.start()
  process.sleep_forever()
}
