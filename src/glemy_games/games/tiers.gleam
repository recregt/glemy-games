//// A Suika-style merge puzzler -- glemy's reference game, and the
//// proving ground the engine's genre-agnostic core (`glemy/physics`) is
//// tested against. Everything in this module is specific to *this*
//// game: what an entity's `kind` means (a tier), what happens when two
//// entities meet (same tier and mergeable → merge, otherwise → the
//// core's default bounce), the drop mechanic, the danger-line lose
//// condition, and scoring. A different game built on `glemy/physics` would
//// have its own module shaped like this one, not extend this one (see
//// `docs/technical-architecture.md`'s Core API section, decision 0047).
////
//// Composed entirely from `glemy/physics`'s core primitives
//// (`physics.Model`/`physics.update`/`physics.spawn_entity`/
//// `physics.entity_count`/`physics.settle_all`, `physics/bounds.clamp_x`,
//// `physics/collision.overlap` -- decision 0050), the small Core timer
//// utilities (`glemy/cooldown`, `glemy/stopwatch` -- decision 0049), and
//// this game's own rules (`glemy/games/tiers/rules`) -- nothing here
//// reaches into `glemy/physics`'s internals or vice versa.

import gleam/float
import gleam/list
import gleam/option
import glemy/cooldown
import glemy_games/games/tiers/rules
import glemy/physics.{type Model as PhysicsModel}
import glemy/physics/bounds.{type Bounds}
import glemy/physics/collision
import glemy/physics/collision_sweep
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/vector2.{Vector2}
import glemy/stopwatch

/// This game's complete state: the underlying physics world
/// (`glemy/physics.Model` -- entities, bounds, gravity) plus everything only
/// *this* game tracks -- the running score, the drop mechanic's own
/// state (`current_tier`, what the *next* drop will be; `next_tier`,
/// what the drop *after that* will be, so a UI can show it in advance;
/// `preview_x`, where `current_tier` would land; `cooldown_remaining`,
/// seconds left before another drop is allowed, advanced each tick via
/// `glemy/cooldown`), and the lose condition's state (`danger_timer`,
/// seconds an entity has continuously sat above the danger line,
/// advanced each tick via `glemy/stopwatch`; `game_over`). Both timer
/// fields stay plain `Float`, not a wrapped timer type -- matching
/// `glemy/physics/entity.gleam`'s own `resting_time` field, this
/// project's established precedent for "a timer is a Float governed by
/// a pure function, not necessarily its own type" (decision 0049).
pub type Model {
  Model(
    physics: PhysicsModel,
    score: Int,
    current_tier: Int,
    next_tier: Int,
    preview_x: Float,
    cooldown_remaining: Float,
    danger_timer: Float,
    game_over: Bool,
  )
}

/// Something `tick` decided happened this specific frame, purely for a
/// caller to react to (playing a sound, triggering a visual flash) --
/// this module has no concept of audio or rendering effects, only of
/// *what happened*; making noise or flashing pixels about it is
/// unavoidably `@target(javascript)`-only FFI, in `glemy/game_tiers`.
pub type GameEvent {
  /// A new entity was actually spawned this tick (`can_drop` was
  /// `True` -- request made, cooldown clear, room under `max_entities`).
  Dropped
  /// At least one same-tier pair merged this tick (`update`'s score
  /// went up). Doesn't distinguish *how many* merges or at *which*
  /// tier(s) -- a single event is enough to trigger a reaction; finer
  /// distinctions (e.g. pitch scaling with tier) are a real, separate
  /// follow-up if wanted, not bundled in speculatively here.
  Merged
}

/// Per-frame input from outside the simulation (e.g. `glemy/io`, polled
/// by the game runner) — kept separate from `Model` since it doesn't
/// persist between frames, unlike simulation state. `cursor_x` is
/// already converted to world-space (see `glemy/physics/bounds.
/// x_from_canvas_pixel`); `next_tier_random` is a `[0.0, 1.0)` float
/// used only when a drop actually happens this frame, to pick what
/// `Model.next_tier` advances to (`rules.random_droppable`) -- passed
/// in rather than generated inside this module so `tick` stays pure and
/// deterministic-given-input, fully testable without any randomness or
/// FFI of its own.
pub type Input {
  Input(cursor_x: Float, drop_requested: Bool, next_tier_random: Float)
}

/// How far below `bounds.max.y` a dropped entity spawns -- fixed, so
/// every drop falls the same distance regardless of where the player's
/// cursor happens to be vertically (mice only steer `cursor_x`).
const spawn_margin_from_top = 15.0

/// Seconds a player must wait after a drop before another is allowed.
/// Tuning is deferred to hands-on play (`docs/development-plan.jsonl`,
/// RM-020); this is a reasonable, clearly-not-instant starting value.
const drop_cooldown = 0.5

/// How far below `bounds.max.y` the danger line sits -- deliberately
/// closer to the top than `spawn_margin_from_top`, so a freshly dropped
/// entity (which spawns *below* the danger line) doesn't immediately
/// count as "above" it; only an actual stack building up that high
/// does.
const danger_line_margin_from_top = 5.0

/// How many continuous seconds an entity may sit above the danger line
/// before the game ends. A plain continuous-time threshold -- not
/// gated on "the piece has finished settling" the way the reference
/// game does (which pauses the timer while a freshly-dropped piece is
/// still actively falling) -- a deliberate, intentional simplification,
/// not an oversight. Tuning deferred to hands-on play
/// (`docs/development-plan.jsonl`, RM-020), matching `drop_cooldown`.
const danger_timer_threshold = 3.0

/// The most entities this game's drop mechanic will ever add.
/// `physics.update`'s collision sweep is O(n²) -- measured directly
/// (headless-real-browser, `tools/browser_check.ts` used as the
/// harness) rather than assumed: holding the spawn input down
/// continuously grows the entity count into the hundreds within
/// seconds and demonstrably degrades simulation tick rate roughly 3x
/// (see decision 0014 in `docs/decisions.jsonl` for the full
/// measurement). This bounds the worst case cheaply rather than
/// building broad-phase collision culling for a demo scene whose actual
/// entity-count needs aren't yet driven by any real game design — see
/// `docs/development-plan.jsonl`, RM-012, which gates broad-phase
/// specifically on O(n²) collision actually being the bottleneck:
/// capped at this value, it no longer is.
pub const max_entities = 150

/// Composes one frame's worth of external input with the physics step:
/// updates the drop preview position, drops a new entity of
/// `current_tier` if requested and allowed (cooldown expired, room
/// under `max_entities`), then runs `physics.update` — so a freshly dropped
/// entity is integrated/bounced/collided in the same frame it appears,
/// not left one frame behind — then checks the danger line, possibly
/// ending the game. Once `model.game_over` is `True`, every subsequent
/// `tick` call is a full no-op: the simulation freezes at the exact
/// moment of loss, matching this project's reload-to-restart decision
/// (no in-place reset exists, so nothing would ever un-freeze it).
///
/// Returns this frame's `GameEvent`s alongside the new `Model`, always
/// freshly computed from this one call -- not, e.g., a stale
/// same-frame event from the exact tick that ended the game reading as
/// "just happened" on every subsequent frozen frame.
pub fn tick(model: Model, dt: Float, input: Input) -> #(Model, List(GameEvent)) {
  let dt = float.min(dt, physics.max_dt)
  case model.game_over {
    True -> #(model, [])
    False -> {
      let cooldown_remaining = cooldown.tick(model.cooldown_remaining, dt)
      let preview_x =
        bounds.clamp_x(
          input.cursor_x,
          rules.radius(model.current_tier),
          model.physics.bounds,
        )
      let at_capacity = physics.entity_count(model.physics) >= max_entities
      let can_drop =
        input.drop_requested
        && cooldown.is_ready(cooldown_remaining)
        && !at_capacity

      let #(physics_after_drop, current_tier, next_tier, cooldown_remaining) = case can_drop {
        True -> {
          let spawn_position =
            Vector2(preview_x, spawn_y(model.physics.bounds))
          let dropped_entity =
            Entity(
              position: spawn_position,
              velocity: vector2.zero,
              radius: rules.radius(model.current_tier),
              kind: model.current_tier,
              resting_time: 0.0,
            )
          #(
            physics.spawn_entity(model.physics, dropped_entity),
            // The queue advances by one: current_tier becomes the tier
            // the player already knew was coming (the old next_tier),
            // and a fresh next_tier is rolled -- never skipping
            // straight to a brand-new, previously-unseen tier the same
            // frame it drops.
            model.next_tier,
            rules.random_droppable(input.next_tier_random, rules.droppable_tiers),
            drop_cooldown,
          )
        }
        False -> #(
          model.physics,
          model.current_tier,
          model.next_tier,
          cooldown_remaining,
        )
      }

      let #(updated_physics, score_events) =
        physics.update(physics_after_drop, dt, bounds.bounce, interact)
      // Damping/rest-snapping (physics.settle_all) is deliberately
      // applied here, in tick, rather than inside physics.update --
      // physics.update stays the pure, undamped integrate/bounce/
      // collision composition (matching its own doc comment and its
      // dedicated test coverage), while settling is a per-real-frame
      // concern alongside the cooldown/danger-timer bookkeeping tick
      // already owns.
      let updated_physics = physics.settle_all(updated_physics, dt)

      let any_entity_above_danger_line =
        list.any(updated_physics.entities, fn(e) {
          e.position.y >. danger_line_y(updated_physics.bounds)
        })
      let danger_timer =
        stopwatch.tick(model.danger_timer, dt, any_entity_above_danger_line)

      let events =
        list.append(
          case can_drop {
            True -> [Dropped]
            False -> []
          },
          case score_events {
            [] -> []
            _ -> [Merged]
          },
        )
      let score_gained = list.fold(score_events, 0, fn(total, gained) { total + gained })

      #(
        Model(
          physics: updated_physics,
          score: model.score + score_gained,
          current_tier:,
          next_tier:,
          preview_x:,
          cooldown_remaining:,
          danger_timer:,
          game_over: danger_timer >. danger_timer_threshold,
        ),
        events,
      )
    }
  }
}

/// Decides what should happen between two entities `physics.update`'s
/// collision sweep finds overlapping: same tier, overlapping, and not
/// already the highest tier → merge (`collision_sweep.Consume`,
/// carrying this merge's score as its `event`); otherwise → the core's
/// default bounce. This is the one place this game's actual rule
/// ("same-tier things merge") lives -- `glemy/physics`/`collision_sweep`
/// never see it.
fn interact(a: Entity, b: Entity) -> collision_sweep.PairInteraction(Int) {
  case
    collision.overlap(a, b) >. 0.0
    && a.kind == b.kind
    && option.is_some(rules.next(a.kind))
  {
    True -> collision_sweep.Consume(rules.merge(a, b), rules.score_for(a.kind))
    False -> collision_sweep.Bounce
  }
}

/// The world-space y a dropped entity spawns at -- see `spawn_margin_from_top`.
fn spawn_y(bounds: Bounds) -> Float {
  bounds.max.y -. spawn_margin_from_top
}

/// A synthetic, stationary `Entity` at `model`'s current drop preview
/// position (`preview_x`, `spawn_y`) and `current_tier`'s radius --
/// exactly what would spawn if a drop were requested this frame, purely
/// for a caller to render as a preview alongside the real entities.
/// Never added to the physics model itself or touched by `tick`'s
/// physics passes.
pub fn preview_entity(model: Model) -> Entity {
  Entity(
    position: Vector2(model.preview_x, spawn_y(model.physics.bounds)),
    velocity: vector2.zero,
    radius: rules.radius(model.current_tier),
    kind: model.current_tier,
    resting_time: 0.0,
  )
}

/// The world-space y above which an entity counts as "in danger" -- see
/// `danger_line_margin_from_top`. `pub`: `glemy/game_tiers`'s `main` also
/// needs this, to position the danger line's own visual indicator at
/// the same y a real merge/game-over decision uses -- one source of
/// truth, not a second hand-copied margin value in the presentation
/// layer.
pub fn danger_line_y(bounds: Bounds) -> Float {
  bounds.max.y -. danger_line_margin_from_top
}

/// Pairs each entity with its RGB color (via `rules.color`), ready to
/// pass straight into `glemy/render`'s `render_entities_to_bytes`/
/// `render_entities_to_canvas` (`render.ColoredEntity`) -- rendering has
/// no concept of what a color should be derived from, that's entirely
/// this game's decision, so this returns entity and color already
/// paired rather than two separate lists a caller would need to zip (or
/// could mis-zip) itself.
pub fn colored_entities(
  entities: List(Entity),
) -> List(#(Entity, #(Float, Float, Float))) {
  list.map(entities, fn(e) { #(e, rules.color(e.kind)) })
}
