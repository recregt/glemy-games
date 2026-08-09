import gleam/float
import glemy_games/games/platformer.{
  Fell, Input, Jumped, Landed, Lost, Model, Playing, Won, type Model,
}
import glemy/physics/bounds.{Bounds}
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/rect.{type Rect, Rect}
import glemy/physics/vector2.{type Vector2, Vector2}

const box = Bounds(min: Vector2(0.0, 0.0), max: Vector2(100.0, 100.0))

fn player_at(position: Vector2, velocity: Vector2) -> Entity {
  Entity(
    position: position,
    velocity: velocity,
    radius: platformer.player_radius,
    kind: 0,
    resting_time: 0.0,
  )
}

fn playing_model(
  player player: Entity,
  grounded grounded: Bool,
  platforms platforms: List(Rect),
) -> Model {
  Model(
    player: player,
    bounds: box,
    platforms: platforms,
    goal: Rect(min: Vector2(85.0, 85.0), max: Vector2(93.0, 93.0)),
    grounded: grounded,
    status: Playing,
  )
}

const no_input = Input(move_left: False, move_right: False, jump: False)

// A platform placed well out of the way of every other test's player
// position -- used whenever a test needs a non-empty `platforms` list
// without the platform itself ever actually being touched.
const far_away_platform = Rect(
  min: Vector2(200.0, 200.0),
  max: Vector2(210.0, 210.0),
)

pub fn tick_stops_at_the_left_wall_test() {
  // Player already sitting exactly on the effective left edge
  // (bounds.min.x + player_radius); a tiny dt is enough to carry it
  // just past, into stop_axis's "past min" branch. Deliberately not
  // physics/bounds.bounce's restitution ramp, or a bounce at all --
  // this game's own zero-restitution wall policy.
  let player =
    player_at(Vector2(platformer.player_radius, 50.0), Vector2(-20.0, 0.0))
  let model = playing_model(player, grounded: False, platforms: [far_away_platform])

  let #(ticked, _events) = platformer.tick(model, 0.01, no_input)

  assert ticked.player.velocity.x == 0.0
  assert ticked.player.position.x == platformer.player_radius
}

pub fn tick_stops_at_the_right_wall_test() {
  let right_edge = 100.0 -. platformer.player_radius
  let player = player_at(Vector2(right_edge, 50.0), Vector2(20.0, 0.0))
  let model = playing_model(player, grounded: False, platforms: [far_away_platform])

  let #(ticked, _events) = platformer.tick(model, 0.01, no_input)

  assert ticked.player.velocity.x == 0.0
  assert ticked.player.position.x == right_edge
}

pub fn tick_stops_at_the_ceiling_test() {
  let ceiling = 100.0 -. platformer.player_radius
  let player = player_at(Vector2(50.0, ceiling), Vector2(0.0, 20.0))
  let model = playing_model(player, grounded: False, platforms: [far_away_platform])

  let #(ticked, _events) = platformer.tick(model, 0.01, no_input)

  assert ticked.player.velocity.y == 0.0
  assert ticked.player.position.y == ceiling
}

pub fn tick_does_not_stop_at_the_bottom_edge_test() {
  // Already below bounds.min.y (dt 0.0 isolates this from any
  // integration/wall-stop interaction) -- stop_at_walls has no bottom
  // case at all, which is exactly what makes falling past it a lose
  // trigger, not a wall.
  let player = player_at(Vector2(50.0, -5.0), vector2.zero)
  let model = playing_model(player, grounded: False, platforms: [far_away_platform])

  let #(ticked, _events) = platformer.tick(model, 0.0, no_input)

  assert ticked.player.position.y == -5.0
  assert ticked.status == Lost
}

pub fn tick_records_fell_event_when_falling_past_the_bottom_test() {
  let player = player_at(Vector2(50.0, -5.0), vector2.zero)
  let model = playing_model(player, grounded: False, platforms: [far_away_platform])

  let #(_ticked, events) = platformer.tick(model, 0.0, no_input)

  assert events == [Fell]
}

pub fn tick_lands_on_a_platform_and_zeroes_vertical_velocity_test() {
  let platform = Rect(min: Vector2(5.0, 5.0), max: Vector2(35.0, 10.0))
  // Just barely overlapping from above, falling -- dt 0.0 isolates
  // collision resolution from integration.
  let resting_y = platform.max.y +. platformer.player_radius
  let player = player_at(Vector2(20.0, resting_y -. 0.1), Vector2(0.0, -20.0))
  let model = playing_model(player, grounded: False, platforms: [platform])

  let #(ticked, events) = platformer.tick(model, 0.0, no_input)

  assert ticked.player.position.y == resting_y
  assert ticked.player.velocity.y == 0.0
  assert ticked.grounded == True
  assert events == [Landed]
}

pub fn tick_does_not_refire_landed_while_already_resting_test() {
  // The exact resting fixture tick_lands_on_a_platform leaves behind --
  // a player already grounded, standing still, integrated through one
  // more real (nonzero dt) tick. Confirms Landed doesn't refire just
  // because gravity nudges a resting player's velocity negative every
  // single tick (the bug this design was built to avoid -- see tick's
  // own doc comment).
  let platform = Rect(min: Vector2(5.0, 5.0), max: Vector2(35.0, 10.0))
  let resting_y = platform.max.y +. platformer.player_radius
  let player = player_at(Vector2(20.0, resting_y), vector2.zero)
  let model = playing_model(player, grounded: True, platforms: [platform])

  let #(ticked, events) = platformer.tick(model, 0.01, no_input)

  assert ticked.grounded == True
  assert events == []
}

pub fn tick_bonks_head_on_the_underside_of_a_platform_test() {
  let platform = Rect(min: Vector2(5.0, 20.0), max: Vector2(35.0, 25.0))
  let bonk_y = platform.min.y -. platformer.player_radius
  let player = player_at(Vector2(20.0, bonk_y +. 0.1), Vector2(0.0, 20.0))
  let model = playing_model(player, grounded: False, platforms: [platform])

  let #(ticked, events) = platformer.tick(model, 0.0, no_input)

  assert ticked.player.position.y == bonk_y
  assert ticked.player.velocity.y == 0.0
  assert ticked.grounded == False
  assert events == []
}

pub fn tick_stops_horizontally_against_a_platform_side_test() {
  let platform = Rect(min: Vector2(20.0, 5.0), max: Vector2(50.0, 35.0))
  let stop_x = platform.min.x -. platformer.player_radius
  let player = player_at(Vector2(stop_x +. 0.1, 20.0), Vector2(15.0, 0.0))
  let model = playing_model(player, grounded: False, platforms: [platform])

  let #(ticked, _events) = platformer.tick(model, 0.0, no_input)

  assert ticked.player.position.x == stop_x
  assert ticked.player.velocity.x == 0.0
}

pub fn tick_resolves_only_the_first_overlapping_platform_per_frame_test() {
  let overlapping_a = Rect(min: Vector2(5.0, 5.0), max: Vector2(35.0, 10.0))
  let overlapping_b = Rect(min: Vector2(0.0, 5.0), max: Vector2(40.0, 30.0))
  let resting_y = overlapping_a.max.y +. platformer.player_radius
  let player = player_at(Vector2(20.0, resting_y -. 0.1), Vector2(0.0, -20.0))
  let model =
    playing_model(player, grounded: False, platforms: [overlapping_a, overlapping_b])

  let #(ticked, _events) = platformer.tick(model, 0.0, no_input)

  // Resolved against overlapping_a (list order) only -- its own landing
  // math applies, not overlapping_b's.
  assert ticked.player.position.y == resting_y
}

pub fn tick_jumps_when_grounded_test() {
  let player = player_at(Vector2(50.0, 50.0), vector2.zero)
  let model = playing_model(player, grounded: True, platforms: [far_away_platform])

  let #(ticked, events) =
    platformer.tick(model, 0.0, Input(move_left: False, move_right: False, jump: True))

  assert ticked.player.velocity.y == platformer.jump_speed
  assert events == [Jumped]
}

pub fn tick_does_not_jump_when_not_grounded_test() {
  let player = player_at(Vector2(50.0, 50.0), Vector2(0.0, -5.0))
  let model = playing_model(player, grounded: False, platforms: [far_away_platform])

  let #(ticked, events) =
    platformer.tick(model, 0.0, Input(move_left: False, move_right: False, jump: True))

  assert ticked.player.velocity.y == -5.0
  assert events == []
}

pub fn tick_moves_the_player_left_when_held_test() {
  let dt = 0.01
  let player = player_at(Vector2(50.0, 50.0), vector2.zero)
  let model = playing_model(player, grounded: False, platforms: [far_away_platform])

  let #(ticked, _events) =
    platformer.tick(model, dt, Input(move_left: True, move_right: False, jump: False))

  assert ticked.player.velocity.x == float.negate(platformer.move_speed)
  assert ticked.player.position.x == 50.0 -. platformer.move_speed *. dt
}

pub fn tick_wins_when_reaching_the_goal_test() {
  let player = player_at(Vector2(89.0, 89.0), vector2.zero)
  let model = playing_model(player, grounded: False, platforms: [far_away_platform])

  let #(ticked, _events) = platformer.tick(model, 0.0, no_input)

  assert ticked.status == Won
}

pub fn tick_records_no_events_when_nothing_happens_test() {
  let player = player_at(Vector2(150.0, 150.0), vector2.zero)
  let model = playing_model(player, grounded: False, platforms: [far_away_platform])

  let #(_ticked, events) = platformer.tick(model, 0.01, no_input)

  assert events == []
}

pub fn tick_is_a_no_op_once_lost_test() {
  let player = player_at(Vector2(50.0, 50.0), Vector2(3.0, 4.0))
  let model =
    Model(
      player: player,
      bounds: box,
      platforms: [far_away_platform],
      goal: Rect(min: Vector2(85.0, 85.0), max: Vector2(93.0, 93.0)),
      grounded: False,
      status: Lost,
    )

  let #(ticked, events) =
    platformer.tick(model, 1.0, Input(move_left: True, move_right: False, jump: True))

  assert ticked == model
  assert events == []
}

pub fn tick_is_a_no_op_once_won_test() {
  let player = player_at(Vector2(50.0, 50.0), Vector2(3.0, 4.0))
  let model =
    Model(
      player: player,
      bounds: box,
      platforms: [far_away_platform],
      goal: Rect(min: Vector2(85.0, 85.0), max: Vector2(93.0, 93.0)),
      grounded: True,
      status: Won,
    )

  let #(ticked, events) = platformer.tick(model, 1.0, no_input)

  assert ticked == model
  assert events == []
}

pub fn new_constructs_a_playing_model_resting_on_the_first_platform_test() {
  let model = platformer.new(box)

  assert model.status == Playing
  assert model.grounded == True
  assert model.player.radius == platformer.player_radius
  assert model.player.velocity == vector2.zero

  let assert [start, ..] = model.platforms
  assert model.player.position.y == start.max.y +. platformer.player_radius
}
