import gleam/list
import glemy_games/games/tiers.{type Model, Input, Model}
import glemy_games/games/tiers/rules
import glemy/physics
import glemy/physics/bounds.{Bounds}
import glemy/physics/collision_sweep.{Bounce}
import glemy/physics/entity.{type Entity, Entity}
import glemy/physics/vector2.{type Vector2, Vector2}

const box = Bounds(min: Vector2(0.0, 0.0), max: Vector2(100.0, 100.0))

/// A single entity has no pair to collide with, so `interact`'s specific
/// behavior never actually matters for the test below -- this stands in
/// only to give `physics.update` a value of the right shape.
fn always_bounce(_a: Entity, _b: Entity) -> collision_sweep.PairInteraction(Nil) {
  Bounce
}

fn new_model(
  entities entities: List(Entity),
  gravity gravity: Vector2,
) -> Model {
  Model(
    danger_timer: 0.0,
    game_over: False,
    current_tier: 0,
    next_tier: 0,
    preview_x: 50.0,
    cooldown_remaining: 0.0,
    score: 0,
    physics: physics.Model(entities: entities, bounds: box, gravity: gravity),
  )
}

pub fn tick_with_no_drop_requested_just_runs_the_physics_step_test() {
  let falling =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 50.0),
      velocity: vector2.zero,
      radius: 1.0,
    )
  let model = new_model([falling], Vector2(0.0, -9.8))

  // dt 0.01, not 1.0: comfortably below physics.max_dt (~0.0333, decision
  // 0037) so `tick`'s internal clamp doesn't change what dt actually
  // gets integrated with -- this test is about tick == update + settle
  // composition, not about the clamp.
  let #(ticked, _events) =
    tiers.tick(
      model,
      0.01,
      Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
    )
  let #(updated_physics, _score_events) =
    physics.update(model.physics, 0.01, bounds.bounce, always_bounce)

  // `tick` applies `entity.settle` (damping/rest-snapping) on top of
  // whatever `physics.update` alone produces -- see tiers.gleam's `tick`.
  // Same dt as the `tick` call above, since `settle` now needs it too.
  assert ticked.physics.entities
    == list.map(updated_physics.entities, fn(e) { entity.settle(e, 0.01) })
}

pub fn tick_updates_preview_x_from_cursor_x_test() {
  let model = new_model([], vector2.zero)

  let #(ticked, _events) =
    tiers.tick(
      model,
      0.0,
      Input(cursor_x: 60.0, drop_requested: False, next_tier_random: 0.0),
    )

  assert ticked.preview_x == 60.0
}

pub fn tick_clamps_preview_x_to_stay_inside_bounds_test() {
  // current_tier 0 -> radius 4.0, so the valid preview range within
  // `box` (0.0..100.0) is [4.0, 96.0].
  let model = new_model([], vector2.zero)

  let #(far_left, _events) =
    tiers.tick(
      model,
      0.0,
      Input(cursor_x: -50.0, drop_requested: False, next_tier_random: 0.0),
    )
  let #(far_right, _events) =
    tiers.tick(
      model,
      0.0,
      Input(cursor_x: 500.0, drop_requested: False, next_tier_random: 0.0),
    )

  assert far_left.preview_x == 4.0
  assert far_right.preview_x == 96.0
}

pub fn tick_with_a_drop_integrates_the_new_entity_the_same_frame_test() {
  // If the drop happened *after* this frame's integration (rather than
  // before), the new entity would still show zero velocity and its
  // original spawn position -- instead it should already reflect one
  // frame of gravity, proving `tick` drops first, then updates.
  let model = new_model([], Vector2(0.0, -10.0))

  // dt is physics.max_dt itself (the largest a single `tick` call will ever
  // actually integrate with, decision 0037), not some arbitrary larger
  // value -- computing the expected numbers via the same formula
  // `entity.integrate`/`entity.settle` use internally, rather than
  // hand-typed products, so this test isn't silently invalidated again
  // if `max_dt` (or gravity, below) is ever retuned.
  let dt = physics.max_dt
  let #(ticked, _events) =
    tiers.tick(
      model,
      dt,
      Input(cursor_x: 50.0, drop_requested: True, next_tier_random: 0.0),
    )

  let assert [only] = ticked.physics.entities
  // One frame of gravity, then damped by entity.settle
  // (velocity_damping) -- `tick` settles every entity, every frame.
  assert only.velocity == Vector2(0.0, -10.0 *. dt *. entity.velocity_damping)
  // Spawn y is bounds.max.y (100.0) minus the fixed spawn margin
  // (15.0) = 85.0, then one frame of gravity integration (semi-implicit
  // Euler: velocity updates first, then position uses the *new*
  // velocity) -- position isn't touched by settling.
  assert only.position == Vector2(50.0, 85.0 +. { -10.0 *. dt } *. dt)
  assert only.radius == rules.radius(0)
  assert only.kind == 0
}

pub fn tick_drop_advances_the_two_ahead_tier_queue_test() {
  // The dropped entity carries the model's *old* current_tier (0).
  // current_tier then advances to the *old* next_tier (1) -- the tier
  // the player already had visibility into before this drop, not a
  // brand-new surprise the same frame it drops. next_tier itself is
  // freshly rolled: next_tier_random 0.99 -> random_droppable(0.99,
  // [0, 1, 2]) picks index truncate(0.99 * 3) = 2 -> tier 2 (already
  // pinned directly by rules_test.gleam; this confirms `tick` actually
  // wires it through).
  let model =
    Model(
      danger_timer: 0.0,
      game_over: False,
      current_tier: 0,
      next_tier: 1,
      preview_x: 50.0,
      cooldown_remaining: 0.0,
      score: 0,
      physics: physics.Model(entities: [], bounds: box, gravity: vector2.zero),
    )

  let #(ticked, _events) =
    tiers.tick(
      model,
      0.0,
      Input(cursor_x: 50.0, drop_requested: True, next_tier_random: 0.99),
    )

  let assert [dropped] = ticked.physics.entities
  assert dropped.kind == 0
  assert ticked.current_tier == 1
  assert ticked.next_tier == 2
}

pub fn tick_drop_resets_the_cooldown_and_blocks_an_immediate_second_drop_test() {
  let model = new_model([], vector2.zero)
  let drop_input =
    Input(cursor_x: 50.0, drop_requested: True, next_tier_random: 0.0)

  let #(after_first, _events) = tiers.tick(model, 0.0, drop_input)
  let #(after_second, _events) = tiers.tick(after_first, 0.0, drop_input)

  assert list.length(after_first.physics.entities) == 1
  // Still just the one entity -- the cooldown the first drop set is
  // still active (0.0 elapsed between the two ticks).
  assert list.length(after_second.physics.entities) == 1
}

pub fn tick_allows_a_drop_again_once_the_cooldown_has_fully_elapsed_test() {
  let model =
    Model(
      danger_timer: 0.0,
      game_over: False,
      current_tier: 0,
      // Distinct from current_tier by construction, guaranteeing the
      // first drop's dropped tier (0) and the second drop's dropped
      // tier (this model's next_tier, 1) differ, regardless of either
      // drop_input's next_tier_random value -- that's what actually
      // matters for this test (see below), not the queue-advancement
      // mechanism itself.
      next_tier: 1,
      preview_x: 50.0,
      cooldown_remaining: 0.0,
      score: 0,
      physics: physics.Model(entities: [], bounds: box, gravity: vector2.zero),
    )
  // The two drops -- landing at the exact same preview_x/spawn height,
  // since cursor_x doesn't change between the two ticks -- are
  // different tiers (0, then 1) and can't merge with each other.
  // Without that, two same-tier entities dropped onto the exact same
  // spot would legitimately merge back down to 1 in the very next
  // `tick`'s physics pass, which is correct game behavior but would
  // defeat the point of this test (proving the cooldown itself allows
  // a second drop).
  let first_drop_input =
    Input(cursor_x: 50.0, drop_requested: True, next_tier_random: 0.0)
  let second_drop_input =
    Input(cursor_x: 50.0, drop_requested: True, next_tier_random: 0.0)

  let #(after_first, _events) = tiers.tick(model, 0.0, first_drop_input)
  // 16 real, `physics.max_dt`-sized ticks (16 * ~0.0333s =~ 0.533s) elapse
  // before the next drop attempt -- comfortably past the full cooldown
  // duration (0.5s), and matches how the real per-frame loop actually
  // accumulates time (many small ticks, decision 0037), not one
  // artificially large single dt a single `tick` call would now clamp
  // away anyway.
  let waited = run_ticks(after_first, physics.max_dt, 16)
  let #(after_second, _events) = tiers.tick(waited, 0.0, second_drop_input)

  assert list.length(after_first.physics.entities) == 1
  assert list.length(after_second.physics.entities) == 2
}

pub fn tick_cooldown_remaining_counts_down_when_idle_test() {
  let model =
    Model(
      danger_timer: 0.0,
      game_over: False,
      current_tier: 0,
      next_tier: 0,
      preview_x: 50.0,
      cooldown_remaining: 0.5,
      score: 0,
      physics: physics.Model(entities: [], bounds: box, gravity: vector2.zero),
    )

  // dt is physics.max_dt itself, not some larger arbitrary value that would
  // now get silently clamped away (decision 0037).
  let dt = physics.max_dt
  let #(ticked, _events) =
    tiers.tick(
      model,
      dt,
      Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
    )

  assert ticked.cooldown_remaining == 0.5 -. dt
}

pub fn tick_cooldown_remaining_is_floored_at_zero_test() {
  let model =
    Model(
      danger_timer: 0.0,
      game_over: False,
      current_tier: 0,
      next_tier: 0,
      preview_x: 50.0,
      // Smaller than physics.max_dt (decision 0037) -- so a single tick's
      // clamped dt is still guaranteed to exceed this and floor it to
      // zero, without needing multiple ticks just to prove flooring.
      cooldown_remaining: 0.01,
      score: 0,
      physics: physics.Model(entities: [], bounds: box, gravity: vector2.zero),
    )

  let #(ticked, _events) =
    tiers.tick(
      model,
      1.0,
      Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
    )

  assert ticked.cooldown_remaining == 0.0
}

pub fn tick_does_not_drop_past_max_entities_test() {
  // The O(n^2) collision sweep is what makes an unbounded entity count
  // a real problem (measured directly, not assumed -- see decision
  // 0014): at capacity, a drop attempt must be silently dropped rather
  // than growing the list further.
  // Dead center of `box`, comfortably far from any edge -- a single
  // gravity step mustn't overshoot a wall and get bounce-reflected,
  // which would make the velocity assertion below fail for reasons
  // unrelated to what this test is actually about. Tier 5 (unmergeable)
  // so a whole stack of overlapping fillers doesn't collapse via merging
  // -- this test is only about the drop cap, not merge behavior.
  let filler =
    Entity(
      resting_time: 0.0,
      kind: 5,
      position: Vector2(50.0, 50.0),
      velocity: Vector2(0.0, 0.0),
      radius: 1.0,
    )
  let at_capacity = list.repeat(filler, tiers.max_entities)
  let model = new_model(at_capacity, Vector2(0.0, -10.0))

  // dt is physics.max_dt itself, not some larger arbitrary value that would
  // now get silently clamped away (decision 0037).
  let dt = physics.max_dt
  let #(ticked, _events) =
    tiers.tick(
      model,
      dt,
      Input(cursor_x: 50.0, drop_requested: True, next_tier_random: 0.0),
    )

  assert list.length(ticked.physics.entities) == tiers.max_entities
  // The cap only blocks *dropping* -- everything else about `tick` still
  // runs normally on the existing entities (here: gravity still moved
  // them, then entity.settle damped that velocity).
  assert list.all(ticked.physics.entities, fn(e) {
    e.velocity == Vector2(0.0, -10.0 *. dt *. entity.velocity_damping)
  })
}

pub fn tick_still_drops_one_below_the_cap_test() {
  // Tier 5 (unmergeable), same reasoning as the cap test above.
  let filler =
    Entity(
      resting_time: 0.0,
      kind: 5,
      position: Vector2(1.0, 1.0),
      velocity: Vector2(0.0, 0.0),
      radius: 1.0,
    )
  let almost_at_capacity = list.repeat(filler, tiers.max_entities - 1)
  let model = new_model(almost_at_capacity, vector2.zero)

  let #(ticked, _events) =
    tiers.tick(
      model,
      0.0,
      Input(cursor_x: 50.0, drop_requested: True, next_tier_random: 0.0),
    )

  assert list.length(ticked.physics.entities) == tiers.max_entities
}

pub fn tick_danger_timer_accumulates_while_an_entity_is_above_the_line_test() {
  // `box`'s danger line sits at y = 95.0 (bounds.max.y - 5.0); this
  // entity, stationary and above it, stays above it after `tick`'s
  // physics pass (zero gravity, well clear of the top edge, so no
  // bounce either).
  let looming =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 96.0),
      velocity: vector2.zero,
      radius: 1.0,
    )
  let model = new_model([looming], vector2.zero)

  // dt is physics.max_dt itself, not some larger arbitrary value that would
  // now get silently clamped away (decision 0037).
  let dt = physics.max_dt
  let #(ticked, _events) =
    tiers.tick(
      model,
      dt,
      Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
    )

  assert ticked.danger_timer == dt
  assert ticked.game_over == False
}

pub fn tick_danger_timer_resets_when_nothing_is_above_the_line_test() {
  let safe =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 50.0),
      velocity: vector2.zero,
      radius: 1.0,
    )
  let model =
    Model(
      // Already accumulated from prior frames -- proves this is a
      // reset, not just "starts at zero and stays there".
      danger_timer: 2.0,
      game_over: False,
      current_tier: 0,
      next_tier: 0,
      preview_x: 50.0,
      cooldown_remaining: 0.0,
      score: 0,
      physics: physics.Model(entities: [safe], bounds: box, gravity: vector2.zero),
    )

  let #(ticked, _events) =
    tiers.tick(
      model,
      1.0,
      Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
    )

  assert ticked.danger_timer == 0.0
}

pub fn tick_sets_game_over_once_the_danger_timer_exceeds_the_threshold_test() {
  let looming =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 96.0),
      velocity: vector2.zero,
      radius: 1.0,
    )
  // Starting just under the 3.0s threshold, so a single physics.max_dt-sized
  // tick (decision 0037 -- the largest a real tick will ever actually
  // integrate with) is guaranteed to push it comfortably past 3.0,
  // without needing a larger dt that would now get silently clamped.
  let dt = physics.max_dt
  let model =
    Model(
      danger_timer: 2.99,
      game_over: False,
      current_tier: 0,
      next_tier: 0,
      preview_x: 50.0,
      cooldown_remaining: 0.0,
      score: 0,
      physics: physics.Model(entities: [looming], bounds: box, gravity: vector2.zero),
    )

  let #(ticked, _events) =
    tiers.tick(
      model,
      dt,
      Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
    )

  assert ticked.danger_timer == 2.99 +. dt
  assert ticked.game_over == True
}

pub fn tick_game_over_is_not_set_exactly_at_the_threshold_test() {
  // The threshold check is strict (`>`, not `>=`) -- landing exactly on
  // 3.0s isn't game over yet, only strictly exceeding it is. Documents
  // this on purpose rather than leaving the boundary implicit.
  let looming =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 96.0),
      velocity: vector2.zero,
      radius: 1.0,
    )
  // danger_timer starts exactly `dt` below the threshold, so one tick
  // lands exactly on it -- dt is physics.max_dt itself (decision 0037), not
  // a larger value that would now get silently clamped away.
  let dt = physics.max_dt
  let model =
    Model(
      danger_timer: 3.0 -. dt,
      game_over: False,
      current_tier: 0,
      next_tier: 0,
      preview_x: 50.0,
      cooldown_remaining: 0.0,
      score: 0,
      physics: physics.Model(entities: [looming], bounds: box, gravity: vector2.zero),
    )

  let #(ticked, _events) =
    tiers.tick(
      model,
      dt,
      Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
    )

  assert ticked.danger_timer == 3.0
  assert ticked.game_over == False
}

pub fn tick_is_a_no_op_once_game_over_is_true_test() {
  let frozen =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 96.0),
      velocity: Vector2(3.0, 4.0),
      radius: 1.0,
    )
  let model =
    Model(
      danger_timer: 5.0,
      game_over: True,
      current_tier: 1,
      next_tier: 1,
      preview_x: 42.0,
      cooldown_remaining: 0.2,
      score: 99,
      physics: physics.Model(
        entities: [frozen],
        bounds: box,
        gravity: Vector2(0.0, -9.8),
      ),
    )

  // A large dt and a drop request that would otherwise obviously change
  // things (new entity, moved entity, decremented cooldown, reset
  // danger timer) -- none of it should matter once game_over is True.
  let #(ticked, _events) =
    tiers.tick(
      model,
      10.0,
      Input(cursor_x: 10.0, drop_requested: True, next_tier_random: 0.99),
    )

  assert ticked == model
}

pub fn tick_records_no_game_events_when_nothing_happens_test() {
  let model =
    Model(
      danger_timer: 0.0,
      game_over: False,
      current_tier: 0,
      next_tier: 1,
      preview_x: 50.0,
      cooldown_remaining: 0.0,
      score: 0,
      physics: physics.Model(entities: [], bounds: box, gravity: vector2.zero),
    )

  let #(_ticked, events) =
    tiers.tick(
      model,
      1.0 /. 60.0,
      Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
    )

  assert events == []
}

pub fn tick_records_a_dropped_event_when_a_drop_happens_test() {
  let model =
    Model(
      danger_timer: 0.0,
      game_over: False,
      current_tier: 0,
      next_tier: 1,
      preview_x: 50.0,
      cooldown_remaining: 0.0,
      score: 0,
      physics: physics.Model(entities: [], bounds: box, gravity: vector2.zero),
    )

  let #(_ticked, events) =
    tiers.tick(
      model,
      0.0,
      Input(cursor_x: 50.0, drop_requested: True, next_tier_random: 0.0),
    )

  assert events == [tiers.Dropped]
}

pub fn tick_records_no_dropped_event_when_the_cooldown_blocks_it_test() {
  let model =
    Model(
      danger_timer: 0.0,
      game_over: False,
      current_tier: 0,
      next_tier: 1,
      preview_x: 50.0,
      // Still on cooldown -- can_drop is False regardless of drop_requested.
      cooldown_remaining: 0.5,
      score: 0,
      physics: physics.Model(entities: [], bounds: box, gravity: vector2.zero),
    )

  let #(_ticked, events) =
    tiers.tick(
      model,
      0.0,
      Input(cursor_x: 50.0, drop_requested: True, next_tier_random: 0.0),
    )

  assert events == []
}

pub fn tick_records_a_merged_event_when_a_merge_happens_test() {
  // Two same-tier, already-overlapping entities -- the physics pass
  // merges them and raises score, which is exactly what `tick` derives
  // the Merged event from.
  let a =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 50.0),
      velocity: vector2.zero,
      radius: rules.radius(0),
    )
  let b =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(52.0, 50.0),
      velocity: vector2.zero,
      radius: rules.radius(0),
    )
  let model =
    Model(
      danger_timer: 0.0,
      game_over: False,
      current_tier: 0,
      next_tier: 1,
      preview_x: 50.0,
      cooldown_remaining: 0.0,
      score: 0,
      physics: physics.Model(entities: [a, b], bounds: box, gravity: vector2.zero),
    )

  let #(_ticked, events) =
    tiers.tick(
      model,
      1.0 /. 60.0,
      Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
    )

  assert events == [tiers.Merged]
}

pub fn tick_records_both_events_when_a_drop_lands_directly_on_a_merge_test() {
  // A drop that spawns directly into an already-overlapping, same-tier
  // pair merges in the very same tick -- both events fire, in the
  // order tick constructs them (Dropped before Merged), not just one
  // or the other.
  let a =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(49.0, 85.0),
      velocity: vector2.zero,
      radius: rules.radius(0),
    )
  let model =
    Model(
      danger_timer: 0.0,
      game_over: False,
      current_tier: 0,
      next_tier: 1,
      preview_x: 50.0,
      cooldown_remaining: 0.0,
      score: 0,
      physics: physics.Model(entities: [a], bounds: box, gravity: vector2.zero),
    )

  let #(_ticked, events) =
    tiers.tick(
      model,
      0.0,
      Input(cursor_x: 50.0, drop_requested: True, next_tier_random: 0.0),
    )

  assert events == [tiers.Dropped, tiers.Merged]
}

pub fn tick_returns_no_game_events_once_game_over_is_already_true_test() {
  // Regression test: the tick that actually ends the game could itself
  // return a Dropped/Merged event -- once frozen (game_over already
  // True going in), tick must not keep echoing an event forever on
  // every subsequent no-op frame. Structurally guaranteed now (`tick`
  // always returns freshly, never carries anything from `model`
  // forward -- see physics.gleam's own `update` doc comment), but kept as an
  // explicit regression test since this was a real bug before that
  // shape existed.
  let model =
    Model(
      danger_timer: 5.0,
      game_over: True,
      current_tier: 0,
      next_tier: 1,
      preview_x: 50.0,
      cooldown_remaining: 0.0,
      score: 10,
      physics: physics.Model(entities: [], bounds: box, gravity: vector2.zero),
    )

  let #(_ticked, events) =
    tiers.tick(
      model,
      1.0 /. 60.0,
      Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
    )

  assert events == []
}

fn run_ticks(model: Model, dt: Float, remaining: Int) -> Model {
  case remaining {
    0 -> model
    _ -> {
      let #(next, _events) =
        tiers.tick(
          model,
          dt,
          Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
        )
      run_ticks(next, dt, remaining - 1)
    }
  }
}

pub fn stacked_entities_of_different_tiers_eventually_come_to_rest_test() {
  // Regression test for decisions 0027/0028: a heavier entity dropped
  // onto a lighter, already-resting one used to settle into a permanent
  // bounce -- either a stable resonance sitting just above whatever
  // hard velocity threshold was in use, or (the smooth-ramp-alone
  // attempt) a nonzero velocity frozen in place by gravity exactly
  // balancing the ramp's damping every single frame. Both were only
  // caught by actually running this exact scenario for real, not by
  // reasoning about the formulas -- see those decisions for the full
  // investigation. 300 ticks at a real 1/60s frame time is 5 simulated
  // seconds, comfortably past both `entity.sleep_duration` and any
  // settling transient.
  let resting =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 4.0),
      velocity: vector2.zero,
      radius: rules.radius(0),
    )
  let falling =
    Entity(
      resting_time: 0.0,
      kind: 1,
      position: Vector2(50.0, 40.0),
      velocity: vector2.zero,
      radius: rules.radius(1),
    )
  let model = new_model([resting, falling], Vector2(0.0, -98.0))

  let dt = 1.0 /. 60.0
  let settled = run_ticks(model, dt, 300)

  let assert [settled_bottom, settled_top] = settled.physics.entities
  assert settled_bottom.velocity == vector2.zero
  assert settled_top.velocity == vector2.zero

  // Not just momentarily zero -- still zero (not reawakened by a fresh
  // bounce) 30 frames later, which a resonant or frozen-nonzero state
  // could never satisfy. Position is compared loosely, not exactly:
  // each idle frame still integrates gravity in before settle clamps
  // velocity back to zero, leaving harmless sub-pixel float drift
  // (~1e-8) rather than a bit-identical position -- irrelevant to the
  // actual invariant under test, which is that the entities stay put
  // and quiet, not resonating or creeping.
  let still_settled = run_ticks(settled, dt, 30)
  let assert [still_bottom, still_top] = still_settled.physics.entities
  assert still_bottom.velocity == vector2.zero
  assert still_top.velocity == vector2.zero
  assert vector2.loosely_equals(still_top.position, settled_top.position, 0.001)
  assert vector2.loosely_equals(
    still_bottom.position,
    settled_bottom.position,
    0.001,
  )
}

pub fn tick_clamps_an_unreasonably_large_dt_to_avoid_tunneling_test() {
  // Regression test for a real, confirmed risk (decision 0037): entity-
  // entity collision here is discrete (`collision.overlap` only ever
  // compares each frame's *end* positions, never sweeps the path
  // between them), so an unclamped, unreasonably large `dt` -- a real
  // scenario `glemy/game_tiers`'s loop can produce from actual wall-clock
  // time after a GC pause or a backgrounded tab regaining focus -- can
  // let a fast-falling entity's integrated position land cleanly past
  // another entity it should have collided with. Reproduced directly
  // (before the fix) via this exact setup with `tick`'s dt clamp
  // removed: the falling entity ended up *below* target with a large
  // gap and neither entity ever registered as having collided.
  //
  // `target` sits in open space (not resting on the floor) specifically
  // so a genuinely tunneled faller would end up measurably *below* it
  // with empty space in between, not merely co-located with it via the
  // floor's own position clamp (which would otherwise mask the result
  // either way).
  let target =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 50.0),
      velocity: vector2.zero,
      radius: rules.radius(0),
    )
  let falling =
    Entity(
      resting_time: 0.0,
      kind: 0,
      position: Vector2(50.0, 95.0),
      velocity: Vector2(0.0, -150.0),
      radius: rules.radius(0),
    )
  let model = new_model([target, falling], Vector2(0.0, -250.0))
  // A single, deliberately extreme 1-second hitch: at the falling
  // entity's own starting speed alone (ignoring gravity's own
  // contribution), an unclamped tick would close the entire 45-unit gap
  // more than three times over in one step.
  let #(ticked, _events) =
    tiers.tick(
      model,
      1.0,
      Input(cursor_x: 50.0, drop_requested: False, next_tier_random: 0.0),
    )

  let assert [ticked_target, ticked_falling] = ticked.physics.entities
  // Still two separate entities (not merged/overlapping yet -- a single
  // physics.max_dt-sized step doesn't close the whole 45-unit gap), and
  // still in the same relative order (falling still strictly above
  // target) -- the two signatures a genuine tunnel-through would break.
  assert ticked_falling.position.y >. ticked_target.position.y
}
