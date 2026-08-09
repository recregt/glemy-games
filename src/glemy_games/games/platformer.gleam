//// A platformer -- glemy's third reference game (RM-034), chosen
//// specifically to produce a real second data point on two Core API
//// generalizations decision 0052 explicitly deferred: whether
//// `physics.update`'s restitution composition generalizes past
//// Tiers/Breakout's own tuning, and whether rectangle collision
//// deserves promotion into `glemy/physics`.
////
//// The circle-vs-Rect detection math this game's own platform/goal
//// collision needs (`physics/rect.overlaps`/`penetration_axis`) is
//// Core, promoted from `glemy/games/breakout` at this game's own
//// confirmed second need (decision 0058) -- but the *resolution* is
//// entirely this game's own, and deliberately different from both
//// existing games: Tiers damps a wall impact to ~10% restitution
//// (`physics/bounds.bounce`), Breakout reflects near-elastically
//// (`bounce_off_walls`), and landing/wall contact here stops the player
//// dead (zero restitution) -- a third, genuinely distinct policy,
//// confirming a third time that no single wall/landing behavior belongs
//// in Core. `tick` below composes `physics/entity.integrate` directly
//// and bypasses `physics.update` entirely, same reasoning as
//// `glemy/games/breakout.tick`.
////
//// Platforms and the goal are static and never destroyed (unlike
//// Breakout's bricks) -- no stable-`id`/DOM-reconciliation problem to
//// solve here at all.

import gleam/float
import gleam/list
import gleam/option.{type Option, None, Some}
import glemy/physics
import glemy/physics/bounds.{type Bounds}
import glemy/physics/collision_sweep
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/rect.{type Rect, Horizontal, Rect, Vertical}
import glemy/physics/vector2.{Vector2}

/// This game's outcome -- same sum-type-not-two-bools reasoning as
/// `glemy/games/breakout.GameStatus`.
pub type GameStatus {
  Playing
  Won
  Lost
}

/// This game's complete state: the player (the only real `physics`
/// `Entity` this game has), the play field, the platforms and goal the
/// player collides against, whether the player is currently resting on
/// a platform (computed at the end of the *previous* tick -- see
/// `tick`'s own doc comment for why this specific timing matters), and
/// the current outcome.
pub type Model {
  Model(
    player: Entity,
    bounds: Bounds,
    platforms: List(Rect),
    goal: Rect,
    grounded: Bool,
    status: GameStatus,
  )
}

/// Something `tick` decided happened this specific frame -- same
/// reasoning as `glemy/games/breakout.GameEvent`.
pub type GameEvent {
  /// The player jumped this tick.
  Jumped
  /// The player landed on top of a platform this tick, having been
  /// falling (not already resting) -- fires once per landing, not every
  /// frame the player continues standing still.
  Landed
  /// The player fell past `bounds.min.y` this tick -- `status` became
  /// `Lost`.
  Fell
}

/// Per-frame input: held-key horizontal movement plus a jump key --
/// same held-key convention as `glemy/games/breakout.Input`, extended
/// with `jump`.
pub type Input {
  Input(move_left: Bool, move_right: Bool, jump: Bool)
}

/// The player's fixed radius.
pub const player_radius = 2.5

/// World units per second the player moves horizontally while a
/// direction key is held -- instant, no acceleration/deceleration
/// curve (simplest correct MVP control scheme, same "tune later"
/// deferral as `glemy/games/breakout/paddle.speed`).
pub const move_speed = 35.0

/// The upward velocity a jump sets, applied once per jump. Tuning
/// deferred to hands-on play, matching this project's standing practice
/// for other feel constants.
pub const jump_speed = 70.0

/// Downward acceleration applied every tick -- same convention as
/// Tiers/Breakout: `bounds.max.y` is world "up", so gravity is
/// negative. Tuning deferred to hands-on play, same as `move_speed`/
/// `jump_speed`.
pub const gravity = Vector2(0.0, -180.0)

/// A fresh game: the player standing on the first platform, a small
/// staircase of platforms ascending toward a goal in the upper-right,
/// zero score concept (this game has none, unlike Breakout), `Playing`.
/// Level layout is a fixed, hand-placed shape -- Phase 3's own tuning
/// concern, not something to over-design here (same MVP-scope reasoning
/// as Breakout's own single-life, no-lives-counter simplicity).
pub fn new(bounds: Bounds) -> Model {
  let platforms = level_platforms(bounds)
  let assert [start, ..] = platforms
  let player =
    Entity(
      position: Vector2(
        { start.min.x +. start.max.x } /. 2.0,
        start.max.y +. player_radius,
      ),
      velocity: vector2.zero,
      radius: player_radius,
      kind: 0,
      resting_time: 0.0,
    )
  Model(
    player: player,
    bounds: bounds,
    platforms: platforms,
    goal: goal_rect(bounds),
    grounded: True,
    status: Playing,
  )
}

/// Each platform's own top sits 10.0 world-units above the previous
/// one -- comfortably under the ~13.6-unit peak height `jump_speed`/
/// `gravity` actually produce (`jump_speed² / (2 * |gravity.y|)`), with
/// margin for a real jump's horizontal drift reducing its effective
/// vertical reach slightly. An earlier draft used 15.0-unit steps,
/// which direct calculation (not assumed) showed exceeds that peak
/// height -- a real, literally-unwinnable level, caught and fixed
/// before any playtesting, not discovered by a failing probe.
fn level_platforms(bounds: Bounds) -> List(Rect) {
  let x0 = bounds.min.x
  let y0 = bounds.min.y
  [
    Rect(min: Vector2(x0 +. 5.0, y0 +. 5.0), max: Vector2(x0 +. 35.0, y0 +. 10.0)),
    Rect(min: Vector2(x0 +. 25.0, y0 +. 15.0), max: Vector2(x0 +. 50.0, y0 +. 20.0)),
    Rect(min: Vector2(x0 +. 45.0, y0 +. 25.0), max: Vector2(x0 +. 70.0, y0 +. 30.0)),
    Rect(min: Vector2(x0 +. 30.0, y0 +. 35.0), max: Vector2(x0 +. 55.0, y0 +. 40.0)),
    Rect(min: Vector2(x0 +. 50.0, y0 +. 45.0), max: Vector2(x0 +. 75.0, y0 +. 50.0)),
    Rect(min: Vector2(x0 +. 65.0, y0 +. 55.0), max: Vector2(x0 +. 90.0, y0 +. 60.0)),
  ]
}

fn goal_rect(bounds: Bounds) -> Rect {
  let x0 = bounds.min.x
  let y0 = bounds.min.y
  Rect(min: Vector2(x0 +. 78.0, y0 +. 65.0), max: Vector2(x0 +. 90.0, y0 +. 73.0))
}

/// The player's color, matching `render.ColoredEntity` -- a solid green,
/// distinct from Breakout's white ball and any tier color Tiers uses.
pub const player_color = #(0.2, 1.0, 0.3)

/// `model.player` paired with its color, ready to pass straight into
/// `glemy/render`'s `render_entities_to_canvas` -- same single-element-
/// list reasoning as `glemy/games/breakout.colored_ball`.
pub fn colored_player(model: Model) -> List(#(Entity, #(Float, Float, Float))) {
  [#(model.player, player_color)]
}

/// Composes one frame's worth of input with the player's motion: reads
/// jump against *last* tick's `grounded` state (before this tick's own
/// motion can overwrite it -- same "read before this frame's own
/// resolution changes it" care `glemy/games/breakout/paddle.reflect`'s
/// position correction already takes), sets horizontal velocity
/// directly from held keys, integrates under gravity, stops the player
/// dead at the world's side walls and ceiling (`stop_at_walls` --
/// deliberately not `physics/bounds.bounce`, wrong restitution policy
/// entirely, see this module's own doc comment), resolves at most one
/// overlapping platform per frame (same "resolve one interaction and
/// move on" simplification as `glemy/games/breakout/brick.resolve_first_hit`),
/// then updates `status` (touching the goal -> `Won`; falling past
/// `bounds.min.y` -> `Lost`, same convention as Breakout's own missed-
/// paddle trigger, no separate margin constant needed). Once `status`
/// isn't `Playing`, every subsequent `tick` call is a full no-op, same
/// convention as `glemy/games/breakout.tick`.
pub fn tick(model: Model, dt: Float, input: Input) -> #(Model, List(GameEvent)) {
  let dt = float.min(dt, physics.max_dt)
  case model.status {
    Playing -> {
      let jumped = input.jump && model.grounded
      let vx = case input.move_left, input.move_right {
        True, False -> float.negate(move_speed)
        False, True -> move_speed
        _, _ -> 0.0
      }
      let vy = case jumped {
        True -> jump_speed
        False -> model.player.velocity.y
      }
      let moved = Entity(..model.player, velocity: Vector2(vx, vy))

      let integrated = entity.integrate(moved, gravity, dt)
      let stopped = stop_at_walls(integrated, model.bounds)
      let #(resolved, grounded) = resolve_platforms(stopped, model.platforms)
      // A grounded-state *transition* (False -> True this tick), not
      // "was velocity.y negative the instant before resolving" --
      // gravity re-introduces a tiny negative vy every single tick a
      // resting player is integrated through, even the hundredth tick
      // standing still, so a velocity-based check would fire `Landed`
      // every tick instead of once per real landing. Caught by direct
      // test, not assumed.
      let landed = grounded && !model.grounded

      // Wrapped through resolve_all_collisions anyway, same reasoning as
      // glemy/games/breakout.tick: a real, if trivial, confirmation this
      // degrades gracefully with a single entity and nothing to pair
      // against -- now a third real caller of that guarantee.
      let #(swept, _) =
        collision_sweep.resolve_all_collisions([resolved], fn(_a, _b) {
          collision_sweep.Bounce
        })
      let assert [final_player] = swept

      let won = rect.overlaps(final_player, model.goal)
      let fell = final_player.position.y <. model.bounds.min.y

      let status = case won, fell {
        True, _ -> Won
        _, True -> Lost
        _, _ -> Playing
      }

      let events =
        list.flatten([
          case jumped {
            True -> [Jumped]
            False -> []
          },
          case landed {
            True -> [Landed]
            False -> []
          },
          case status == Lost {
            True -> [Fell]
            False -> []
          },
        ])

      #(
        Model(..model, player: final_player, grounded: grounded, status: status),
        events,
      )
    }
    _ -> #(model, [])
  }
}

/// Stops `player` dead (zero restitution) at the world's left/right
/// edges, and at the top edge (a soft ceiling, so nothing can fly off
/// the visible field) -- deliberately not `physics/bounds.bounce`, and
/// not a bounce at all: this game's own wall policy, see this module's
/// own doc comment. The bottom edge is left untouched entirely, same
/// convention as `glemy/games/breakout.bounce_off_walls`'s own
/// bottom-is-a-lose-trigger reasoning -- `tick` checks
/// `position.y <. bounds.min.y` directly instead. Built on
/// `physics/bounds.resolve_axis`/`resolve_high_only` (decision 0062):
/// this game supplies only the velocity transform (zero out, or
/// preserve an already-negative velocity at the ceiling), the
/// clamp-and-branch shape itself is Core.
fn stop_at_walls(player: Entity, bounds: Bounds) -> Entity {
  let #(x, vx) =
    bounds.resolve_axis(
      player.position.x,
      player.velocity.x,
      bounds.min.x +. player.radius,
      bounds.max.x -. player.radius,
      fn(_) { 0.0 },
      fn(_) { 0.0 },
    )
  let #(y, vy) =
    bounds.resolve_high_only(
      player.position.y,
      player.velocity.y,
      bounds.max.y -. player.radius,
      fn(v) { float.min(v, 0.0) },
    )
  Entity(..player, position: Vector2(x, y), velocity: Vector2(vx, vy))
}

/// Finds the first platform `player` overlaps (list order) and resolves
/// that one hit; every other platform is left untouched, to be checked
/// again next frame -- same "resolve one interaction and move on"
/// simplification `glemy/games/breakout/brick.resolve_first_hit` already
/// uses. Returns the resolved player and whether it's now resting on
/// top of a platform (`grounded`) -- `tick` itself derives the `Landed`
/// event from this as a state *transition* (see `tick`'s own doc
/// comment for why velocity alone is the wrong signal for that).
fn resolve_platforms(player: Entity, platforms: List(Rect)) -> #(Entity, Bool) {
  case find_first_overlap(player, platforms) {
    None -> #(player, False)
    Some(platform) -> resolve_platform_hit(player, platform)
  }
}

fn find_first_overlap(player: Entity, platforms: List(Rect)) -> Option(Rect) {
  case platforms {
    [] -> None
    [first, ..rest] ->
      case rect.overlaps(player, first) {
        True -> Some(first)
        False -> find_first_overlap(player, rest)
      }
  }
}

fn resolve_platform_hit(player: Entity, platform: Rect) -> #(Entity, Bool) {
  case rect.penetration_axis(player, platform) {
    Vertical -> {
      let platform_center_y = { platform.min.y +. platform.max.y } /. 2.0
      case player.position.y >. platform_center_y {
        True -> {
          // Landed on top -- snap to rest on the platform's surface,
          // zero the vertical velocity (not reflected: this game's own
          // zero-restitution landing policy, see this module's own doc
          // comment), set grounded.
          let resting =
            Entity(
              ..player,
              position: Vector2(player.position.x, platform.max.y +. player.radius),
              velocity: Vector2(player.velocity.x, 0.0),
            )
          #(resting, True)
        }
        False -> {
          // Bonked head on the underside -- stop upward velocity, no
          // grounded flag (still airborne).
          let bonked =
            Entity(
              ..player,
              position: Vector2(player.position.x, platform.min.y -. player.radius),
              velocity: Vector2(player.velocity.x, float.min(player.velocity.y, 0.0)),
            )
          #(bonked, False)
        }
      }
    }
    Horizontal -> {
      let platform_center_x = { platform.min.x +. platform.max.x } /. 2.0
      let x = case player.position.x <. platform_center_x {
        True -> platform.min.x -. player.radius
        False -> platform.max.x +. player.radius
      }
      let pushed =
        Entity(..player, position: Vector2(x, player.position.y), velocity: Vector2(0.0, player.velocity.y))
      #(pushed, False)
    }
  }
}
